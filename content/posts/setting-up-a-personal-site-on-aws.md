---
title: "What Took Me Days Now Took an Hour: Setting Up a Personal Site on AWS"
date: 2026-04-05
draft: false
tags: ["aws", "hugo", "cloudfront", "route53", "devops"]
categories: ["blog"]
summary: "I tried to set up a static site on AWS years ago and gave up after days of debugging. This time, with AI pair-programming, the whole thing was live in about an hour. Here's the full story."
ShowToc: true
---

A couple of years ago, I tried to set up a personal website on AWS. I had a domain
registered through Route 53, an S3 bucket, and a rough idea of what I wanted. I spent
**days** piecing it together — bouncing between Stack Overflow answers, AWS documentation,
and Google searches. I'd fix one thing and break another. CloudFront wouldn't serve my
pages. The SSL certificate wouldn't validate. DNS records pointed to the wrong place.
Eventually, I moved on to other things and the half-finished setup sat there collecting
dust.

Fast forward to April 2026. I decided to try again, but this time I pair-programmed
the entire thing with Claude. **The site was live in about an hour.**

This post walks through exactly what we built, what went wrong (plenty did), and what
I learned — both about AWS and about the difference between debugging alone versus
debugging with an AI that can run commands and reason about the output in real time.

## What I wanted

Nothing fancy:

- A place to write notes and blog posts in **Markdown**
- **Search**, **tags**, **dark mode**, and **syntax highlighting**
- Hosted on **my own domain** (xiaoyong.org) with **HTTPS**
- **Auto-deploys** when I push to GitHub
- **Near-zero cost** — this is a personal site, not a startup

## What we built

```
Write Markdown → git push → GitHub Actions → S3 → CloudFront → xiaoyong.org
```

| Component | Choice | Monthly cost |
|---|---|---|
| Static site generator | Hugo + PaperMod theme | Free |
| Storage | S3 | ~$0.01 |
| CDN + HTTPS | CloudFront + ACM | Free tier |
| DNS | Route 53 | $0.50 |
| CI/CD | GitHub Actions | Free |
| Comments | giscus (GitHub Discussions) | Free |
| **Total** | | **~$0.51/month** |

The entire site builds in 40ms. Deploys take about 20 seconds end-to-end.

## The setup, step by step

### Hugo + PaperMod: 5 minutes

Hugo is absurdly fast. Install it, create a site, add a theme:

```bash
brew install hugo
hugo new site xiaoyong.org
cd xiaoyong.org
git init
git submodule add --depth=1 https://github.com/adityatelange/hugo-PaperMod.git themes/PaperMod
```

PaperMod gave me everything I wanted out of the box — search (Fuse.js), dark/light
toggle, syntax highlighting, tags, table of contents, reading time. I configured it
all in a single `hugo.yaml` and created a few starter posts. `hugo server -D` and I
had a working local site.

This part was the easiest. The hard part, as it was years ago, was AWS.

### AWS infrastructure: where things got interesting

I created a CloudFormation template to define everything declaratively:

- **S3 bucket** — stores the Hugo output, no public access
- **CloudFront distribution** — CDN with HTTPS, HTTP→HTTPS redirect
- **ACM certificate** — free SSL for xiaoyong.org and *.xiaoyong.org
- **Origin Access Control** — only CloudFront can read from S3
- **Route 53 records** — A and AAAA alias records pointing to CloudFront
- **CloudFront Function** — rewrites `/posts/hello/` to `/posts/hello/index.html`

One `aws cloudformation deploy` command should bring it all up. In theory.

## Everything that went wrong

### Problem 1: Dots break CloudFront resource names

The very first deploy failed instantly. CloudFront function names and cache policy
names only allow `[a-zA-Z0-9-_]`. My template used `${DomainName}-url-rewrite` which
expanded to `xiaoyong.org-url-rewrite` — the dots killed it.

**Fix:** Use sanitized names (`xiaoyong-org-url-rewrite` instead of `xiaoyong.org-url-rewrite`).

**Lesson:** Never interpolate a domain name directly into a CloudFront resource name.
Replace dots with dashes.

### Problem 2: The nameserver mismatch that blocked everything

After fixing the naming issue, the second deploy started fine — S3 bucket created,
CloudFront OAC created — but then it just... hung. The ACM certificate was stuck on
`PENDING_VALIDATION` for 20+ minutes.

This is where the debugging got interesting. The diagnosis went like this:

```bash
# Is the validation CNAME in Route 53?
aws route53 list-resource-record-sets --hosted-zone-id Z005... \
  --query "ResourceRecordSets[?Type=='CNAME']"
# Yes — the record exists.

# Does it resolve publicly?
dig CNAME _0756a5fa...xiaoyong.org +short
# Nothing. Empty response.

# Wait — do the nameservers even work?
dig NS xiaoyong.org +short
# Nothing. Empty response. Oh no.
```

The CNAME was in Route 53, but the internet couldn't see it because the internet
didn't know to ask Route 53. The domain's **registrar** was pointing to a completely
different set of nameservers.

Here's what happened: at some point in the past (probably during my first failed
attempt), the Route 53 hosted zone had been deleted and recreated. Every new hosted
zone gets a fresh set of 4 nameservers. But the registrar still pointed to the old
ones — which no longer existed.

```
Registrar NS (stale):         Hosted Zone NS (actual):
ns-389.awsdns-48.com          ns-49.awsdns-06.com      ← different!
ns-616.awsdns-13.net          ns-875.awsdns-45.net      ← different!
ns-1987.awsdns-56.co.uk       ns-1587.awsdns-06.co.uk   ← different!
ns-1027.awsdns-00.org         ns-1218.awsdns-24.org     ← different!
```

The `.org` TLD servers were sending DNS queries to nameservers that didn't exist.
ACM was querying for its validation CNAME and getting nothing back.

**This was almost certainly why my original setup attempt failed years ago.** I probably
recreated the hosted zone at some point and never realized the nameservers changed. Every
DNS-dependent step after that was doomed.

**Fix:**

```bash
aws route53domains update-domain-nameservers --domain-name xiaoyong.org \
  --nameservers Name=ns-49.awsdns-06.com Name=ns-875.awsdns-45.net \
               Name=ns-1587.awsdns-06.co.uk Name=ns-1218.awsdns-24.org
```

One command. We verified propagation from Google DNS, Cloudflare DNS, and the
authoritative nameservers directly. Within a few minutes, the ACM certificate
flipped to `ISSUED`.

### Problem 3: Ghost DNS records from the past

Even after the certificate validated and CloudFront deployed, the stack hung again.
This time, `DNSRecordRoot` and `DNSRecordWWW` were stuck on `CREATE_IN_PROGRESS`
with no error.

The cause: my hosted zone had **leftover A records** from the original failed setup,
pointing to `s3-website-us-west-1.amazonaws.com`. CloudFormation tried to create new
A records pointing to CloudFront, but records with the same name and type already
existed. CloudFormation doesn't overwrite records it didn't create — it just hangs
silently.

```bash
# Found the ghosts
aws route53 list-resource-record-sets --hosted-zone-id Z005... \
  --query "ResourceRecordSets[?Type=='A']"

# xiaoyong.org → s3-website-us-west-1.amazonaws.com  ← the old, broken setup!
```

**Fix:** Delete the old records. CloudFormation completed in 30 seconds.

### Problem 4: Giscus needs three things, not one

Setting up giscus comments required three separate steps, and the docs don't make
this obvious:

1. Enable GitHub Discussions on the repo
2. Configure giscus in `hugo.yaml` with the correct repo ID and category ID
3. **Install the giscus GitHub App** on the repo (https://github.com/apps/giscus)

I had done 1 and 2 but not 3. The error message ("giscus is not installed on this
repository") was at least clear about what was missing.

## What was different this time

The technical problems I hit this time were **the same kinds of problems** I hit years
ago — DNS misconfigurations, CloudFormation quirks, resource naming constraints, stale
state from previous attempts. The difference wasn't the difficulty of the problems.
The difference was how fast they got diagnosed.

**Years ago:** I'd see "PENDING_VALIDATION" on the ACM certificate, Google it, find
a Stack Overflow answer saying "check your DNS," try a few things, not know which
specific thing was wrong, try something else, accidentally break something, Google that,
and eventually lose the thread of what I was even debugging.

**This time:** When ACM was stuck, the debugging was systematic:

1. Is the CNAME in Route 53? Yes.
2. Does it resolve publicly? No.
3. Do the nameservers resolve? No.
4. What are the registrar's nameservers? Different from the hosted zone.
5. Fix: update registrar nameservers.
6. Verify from multiple resolvers.
7. Done.

Each step took seconds to execute and the next step was informed by the previous
result. No context-switching to browser tabs. No guessing. No accidentally following
advice for a different version of AWS or a different problem.

The total time from "let's do this" to "site is live" was about an hour, and most
of that was waiting for DNS propagation and CloudFront deployment — things no amount
of debugging can speed up.

## The lessons I wish I'd had years ago

1. **Check the NS delegation chain first, always.** If `dig NS yourdomain.com` doesn't
   return your hosted zone's nameservers, nothing DNS-dependent will work. This one
   check would have saved me days.

2. **Recreating a hosted zone changes the nameservers.** This is the most common way
   people break their DNS. The new zone gets new NS records. The registrar still has
   the old ones. Everything looks fine in Route 53, but the internet can't reach it.

3. **CloudFormation hangs silently on DNS record conflicts.** If a record already
   exists outside the stack, CloudFormation won't error — it just waits forever. Audit
   existing records before deploying.

4. **Don't put dots in CloudFront resource names.** The API rejects them. Sanitize
   domain names (dots → dashes) before using them in resource names.

5. **Preview CloudFormation changes.** Use `--no-execute-changeset` to see what will
   happen before it happens.

6. **ACM certs for CloudFront must be in us-east-1.** Doesn't matter where your
   bucket is. This is a hard requirement.

7. **Parallelize around the slow parts.** While CloudFormation was deploying (~15 min),
   we set up the GitHub repo, IAM user, and CI/CD secrets. Don't sit and watch
   progress bars.

## The final setup

The site is live at [xiaoyong.org](https://xiaoyong.org). The workflow is:

```bash
# Write something
hugo new content posts/my-post.md
vim content/posts/my-post.md

# Preview locally
hugo server -D

# Deploy (automatic)
git add . && git commit -m "New post" && git push
```

GitHub Actions builds Hugo, syncs to S3, and invalidates the CloudFront cache. The
whole deploy takes about 20 seconds. The site costs $0.51 per month.

The source code, CloudFormation template, and all the documentation we wrote during
setup are in the [GitHub repo](https://github.com/xiaoyongaz/xiaoyong.org).

Sometimes the best upgrade isn't a new tool — it's having a better debugging partner.
