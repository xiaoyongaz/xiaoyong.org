# Project Setup Recap — xiaoyong.org

A comprehensive walkthrough of setting up a personal website on AWS, from initial
planning through a live, auto-deploying site. This document captures the full
interactive process including decisions, execution, issues, and lessons learned.

**Date:** April 4-5, 2026
**Result:** https://xiaoyong.org — live, HTTPS, auto-deploys on git push

---

## 1. Project Overview

### What we built

A static personal website for notes, blogs, and knowledge sharing, hosted entirely
on AWS with automated deployment from GitHub.

### Final architecture

```
[Write Markdown] → [git push] → [GitHub Actions] → [S3 Bucket] → [CloudFront CDN] → [xiaoyong.org]
                                   builds Hugo        stores       serves globally
                                   syncs to S3         files       with HTTPS
                                   invalidates cache
```

### Key components

| Component | Choice | Why |
|---|---|---|
| Static site generator | Hugo + PaperMod theme | Fastest SSG, all features built-in |
| Hosting | S3 + CloudFront | ~$0.50/month, no servers to manage |
| SSL/TLS | ACM (free certificate) | Auto-renewing, zero cost |
| DNS | Route 53 (existing hosted zone) | Already registered here |
| CI/CD | GitHub Actions | Free for public repos, tight Git integration |
| Comments | giscus (GitHub Discussions) | Free, no backend needed, GitHub-native |
| Content authoring | Markdown + Git | Developer-friendly, version controlled |

---

## 2. Initial Planning

### Requirements gathering

Before writing any code, we clarified four key decisions through interactive questions:

| Question | Answer | Impact on architecture |
|---|---|---|
| Technical comfort level? | Advanced developer | Full control setup (no managed platforms like Amplify) |
| Content authoring method? | Markdown + Git | Hugo static site, GitHub-based workflow |
| Budget? | Near-zero ($0-2/month) | S3 + CloudFront (cheapest possible) |
| Must-have features? | All: search, tags, GitHub integration, dark mode, code blocks, comments | PaperMod theme (has all built-in) + giscus |

### Architecture decision

**Hugo + S3 + CloudFront** was chosen over alternatives:

- **Why not Amplify?** Adds abstraction an advanced user doesn't need. S3+CloudFront
  gives full control at lower cost.
- **Why not EC2/Lightsail?** A server is overkill for static content. More expensive,
  more maintenance, more attack surface.
- **Why Hugo over Next.js/Astro?** Fastest build times (~40ms), PaperMod theme has
  every requested feature out of the box, no JavaScript framework overhead.
- **Why PaperMod theme?** Built-in search (Fuse.js), tags, dark/light mode toggle,
  syntax highlighting (Chroma), reading time, table of contents — zero custom code needed.

---

## 3. Step-by-Step Execution

### Step 1: Hugo project setup

**What we did:**
- Installed Hugo via Homebrew (`brew install hugo` — v0.160.0)
- Created new site: `hugo new site xiaoyong.org`
- Initialized Git repo, renamed branch to `main`
- Added PaperMod theme as Git submodule

**Time:** ~2 minutes

**Notes:** Straightforward, no issues. The submodule approach for themes means the
theme can be updated independently with `git pull`.

---

### Step 2: Site configuration

**What we did:**
- Created `hugo.yaml` with full configuration:
  - Search (Fuse.js), tags, categories, dark/light mode toggle
  - Syntax highlighting (Chroma, dracula style)
  - Menu: Home, Blog, Notes, Tags, Search, About
  - Social icons (GitHub, RSS)
  - Edit post links pointing to GitHub
  - Giscus comments (initially commented out, configured later)
- Created content structure:
  - `content/posts/` — blog posts with hello-world starter
  - `content/notes/` — quick notes with TIL starter
  - `content/about.md` — about page
  - `content/search.md` — search page
- Created custom layouts:
  - `layouts/partials/comments.html` — giscus integration
  - `layouts/shortcodes/github-repo.html` — GitHub repo card embed
  - `layouts/shortcodes/gist.html` — GitHub gist embed

**Issue encountered:** Hugo template parse error on shortcode comments containing `*/`.
Fixed by simplifying the comment text. (Minor, fixed in seconds.)

**Verification:** `hugo --minify` — built 28 pages in 64ms, clean output.

**Time:** ~5 minutes

---

### Step 3: AWS CLI setup

**What we did:**
- Discovered AWS CLI was already installed but configured for a **work account**
  (Amazon/Bedrock role on account 890117190757)
- Needed a separate profile for the personal account (385055690025)
- User created an IAM admin user via the AWS Console (with console access + access keys)
- Configured AWS CLI: `aws configure --profile xiaoyong-personal`
  - Region: us-east-1 (required for ACM + CloudFront)
  - Output: json

**Key advice given:**
- Don't use root account for day-to-day operations — create an IAM admin user
- Enable console access on the IAM user to replace root login
- Bookmark the IAM sign-in URL: `https://<account-id>.signin.aws.amazon.com/console`

**Verification:** `aws sts get-caller-identity --profile xiaoyong-personal` confirmed
account 385055690025, user `admin`.

**Time:** ~5 minutes (mostly user doing console steps)

---

### Step 4: AWS infrastructure via CloudFormation

**What we did:**
- Created `infra/cloudformation.yaml` defining all AWS resources:
  - S3 bucket (private, CloudFront OAC access only)
  - ACM certificate (xiaoyong.org + *.xiaoyong.org, DNS validation)
  - CloudFront Origin Access Control
  - CloudFront cache policy (Brotli + gzip, ignore cookies/query strings)
  - CloudFront distribution (HTTP/2+3, HTTPS redirect, PriceClass_100)
  - CloudFront URL rewrite function (appends index.html to directory paths)
  - Route 53 A + AAAA records for root and www (alias to CloudFront)
  - S3 bucket policy (allows CloudFront OAC only)
- Created `infra/deploy-infra.sh` — one-command deployment script
- Updated script to use `--profile xiaoyong-personal`

**Issues encountered:** Three significant issues (detailed in Section 4 below):
1. CloudFormation naming failure (dots in resource names)
2. Registrar nameserver mismatch (ACM validation stuck)
3. Pre-existing DNS A records (CloudFormation hung silently)

**Time:** ~45 minutes (most time spent diagnosing and fixing the three issues)

---

### Step 5: GitHub repo creation and initial push

**What we did:**
- Installed GitHub CLI (`brew install gh`)
- User authenticated via `gh auth login` (browser-based OAuth)
- Created repo: `gh repo create xiaoyongaz/xiaoyong.org --public`
- Created `.gitignore` (public/, resources/_gen/, .hugo_build.lock, .DS_Store)
- Initial commit with all files (19 files, 641 insertions)
- Pushed to `origin/main`

**Note:** GitHub Actions triggered on push but failed (expected — AWS secrets not yet configured).

**Time:** ~3 minutes

---

### Step 6: IAM for CI/CD and GitHub secrets

**What we did:**
- Ran `./infra/setup-iam.sh` to create:
  - IAM user: `github-deploy-xiaoyong-org`
  - IAM policy: `xiaoyong-org-deploy` (S3 read/write + CloudFront invalidation)
  - Access keys for the user
- Set 4 GitHub repo secrets via `gh secret set`:
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`
  - `S3_BUCKET_NAME` = `xiaoyong-org-site`
  - `CLOUDFRONT_DISTRIBUTION_ID` = `E227RHMXZMUUN2`

**Note:** The first 3 secrets were set while CloudFormation was still deploying. The
CloudFront distribution ID was added once the stack completed.

**Time:** ~2 minutes

---

### Step 7: First deploy and site verification

**What we did:**
- Built site locally: `hugo --minify`
- Manually synced to S3: `aws s3 sync public/ s3://xiaoyong-org-site --delete`
  (38 files, 184 KiB)
- Invalidated CloudFront cache: `aws cloudfront create-invalidation --paths "/*"`
- Verified:
  - `curl -I https://xiaoyong.org` — HTTP/2 200, served from CloudFront SEA edge
  - `curl -I https://www.xiaoyong.org` — HTTP/2 200
  - `curl -I http://xiaoyong.org` — 301 redirect to HTTPS
- Subsequent pushes via GitHub Actions also verified working

**Time:** ~2 minutes

---

### Step 8: Giscus comments setup

**What we did:**
- Enabled GitHub Discussions: `gh repo edit --enable-discussions`
- Queried repo ID and discussion category IDs via GraphQL API
- Updated `hugo.yaml` with giscus configuration:
  - repo: `xiaoyongaz/xiaoyong.org`
  - repoId: `R_kgDOR6IHwQ`
  - category: `General`
  - categoryId: `DIC_kwDOR6IHwc4C6FgI`
- Added `comments: true` to params (required by PaperMod to render the comments partial)
- Fixed GitHub username from `xiaoyong` to `xiaoyongaz` across all files

**Issue encountered:** Giscus showed "not installed on this repository" error.
Root cause: The giscus GitHub App must be separately installed on the repo at
https://github.com/apps/giscus — enabling Discussions alone is not enough.

**Time:** ~5 minutes

---

## 4. Issues Encountered

### Issue 1: CloudFormation resource naming (dots in domain)

| | |
|---|---|
| **When** | First CloudFormation deploy attempt |
| **Symptom** | Stack creation failed immediately. Two resources rejected: `URLRewriteFunction` and `CloudFrontCachePolicy` |
| **Error** | `Value 'xiaoyong.org-url-rewrite' failed to satisfy constraint: Member must satisfy regular expression pattern: [a-zA-Z0-9-_]{1,64}` |
| **Root cause** | CloudFront function names and cache policy names don't allow dots (`.`). Template used `${DomainName}-url-rewrite` which expanded to `xiaoyong.org-url-rewrite` |
| **How we found it** | `aws cloudformation describe-stack-events` with `ResourceStatus=='CREATE_FAILED'` filter showed the exact error messages |
| **Fix** | Replaced all `${DomainName}-*` patterns with hardcoded `xiaoyong-org-*` names (dots → dashes) |
| **Recovery** | Deleted the failed stack, redeployed with fixed template |
| **Time impact** | ~5 minutes |

---

### Issue 2: Registrar nameserver mismatch (ACM stuck)

| | |
|---|---|
| **When** | After fixing Issue 1, during second CloudFormation deploy |
| **Symptom** | ACM certificate stuck on `PENDING_VALIDATION` for 15+ minutes. Stack hung on `Certificate CREATE_IN_PROGRESS` |
| **Root cause** | Domain was registered via Amazon Registrar, but the Route 53 hosted zone had been recreated at some point. New zone got new nameservers, but the registrar still pointed to the old (non-existent) nameservers. ACM's DNS validation couldn't reach the CNAME record |
| **How we found it** | Multi-step diagnosis: |
| | 1. `dig NS xiaoyong.org +short` → empty (no NS records resolving!) |
| | 2. `aws route53 get-hosted-zone` → showed expected NS: ns-49, ns-875, ns-1587, ns-1218 |
| | 3. `aws route53domains get-domain-detail` → showed registrar NS: ns-389, ns-616, ns-1987, ns-1027 — **mismatch!** |
| **Fix** | `aws route53domains update-domain-nameservers` to set registrar NS to match hosted zone |
| **Verification** | Confirmed propagation from Google DNS (8.8.8.8), Cloudflare DNS (1.1.1.1), and directly from Route 53 authoritative NS. Also verified ACM CNAME resolved from all resolvers |
| **Additional checks** | Ruled out other blockers: no CAA records restricting cert issuance, no duplicate hosted zones, single hosted zone with correct CNAME |
| **Time impact** | ~20 minutes (diagnosis + NS propagation + ACM polling delay) |

---

### Issue 3: Pre-existing DNS A records (CloudFormation hung)

| | |
|---|---|
| **When** | After ACM cert issued, CloudFront distribution created |
| **Symptom** | CloudFormation stuck on `CREATE_IN_PROGRESS` — all resources complete except `DNSRecordRoot` and `DNSRecordWWW`. No error, just hung indefinitely |
| **Root cause** | The hosted zone already had A records for `xiaoyong.org` and `www.xiaoyong.org` from a previous setup attempt, pointing to an old S3 website endpoint (`s3-website-us-west-1.amazonaws.com`). CloudFormation couldn't create new A records because records with the same name/type already existed outside its management |
| **How we found it** | `aws route53 list-resource-record-sets` filtered for A/AAAA records revealed old alias records pointing to S3 us-west-1 — clearly from a previous, different setup |
| **Fix** | Manually deleted the old A records via `aws route53 change-resource-record-sets` with `Action: DELETE`. CloudFormation completed within 30 seconds after |
| **Time impact** | ~10 minutes |

---

### Issue 4: PaperMod comments param requirement

| | |
|---|---|
| **When** | Setting up giscus comments |
| **Symptom** | `grep "giscus" public/posts/hello-world/index.html` returned 0 matches — giscus script not in HTML output despite config being set |
| **Root cause** | PaperMod's `single.html` template wraps the comments partial in `{{- if (.Param "comments") }}`. The `comments: true` param must be set globally or per-post |
| **How we found it** | Searched PaperMod's templates: `grep -r "comments" themes/PaperMod/layouts/` revealed the conditional |
| **Fix** | Added `comments: true` under `params:` in `hugo.yaml` |
| **Time impact** | ~2 minutes |

---

### Issue 5: Giscus app not installed

| | |
|---|---|
| **When** | Testing comments on the live site |
| **Symptom** | Error message at bottom of post: "giscus is not installed on this repository" |
| **Root cause** | Enabling GitHub Discussions on a repo is necessary but not sufficient. The giscus GitHub App must also be installed on the repo separately |
| **Fix** | Install giscus app at https://github.com/apps/giscus, grant access to the repo |
| **Time impact** | ~1 minute |

---

## 5. Lessons Learned

### Planning phase

1. **Ask the right upfront questions.** Four targeted questions (experience level,
   authoring preference, budget, features) eliminated entire categories of architecture
   decisions in minutes. For future projects: identify the decisions that have the
   highest branching factor and ask about those first.

2. **Match complexity to the user.** Knowing the user is an advanced developer meant
   we could skip managed platforms (Amplify) and go with raw S3 + CloudFront. For a
   beginner, the opposite choice would have been correct.

3. **Plan for the domain setup, not just the app.** The majority of our time was spent
   on DNS/certificate issues, not on the Hugo site itself. Future plans should include
   a "DNS readiness checklist" before starting infrastructure deployment.

### AWS / CloudFormation

4. **Validate resource naming constraints before deploying.** CloudFront resources
   reject dots in names. Always use `[a-zA-Z0-9-_]` safe names. Don't interpolate
   domain names directly into resource names — sanitize them first (dots → dashes).

5. **CloudFormation fails silently on DNS record conflicts.** If a Route 53 record
   already exists (created outside the stack), CloudFormation will hang on
   `CREATE_IN_PROGRESS` indefinitely without reporting an error. Always audit existing
   DNS records before deploying: `aws route53 list-resource-record-sets`.

6. **Preview changes with changesets.** Use `--no-execute-changeset` to see what
   CloudFormation will do before it does it. This prevents surprises.

7. **ACM certificates must be in us-east-1 for CloudFront.** This is a hard requirement
   that's easy to miss. All CloudFormation resources can be in us-east-1 together.

### DNS / Domain

8. **Always verify the NS delegation chain first.** When DNS-dependent services
   (like ACM) are stuck, check the full chain:
   - Registrar NS → must match → Hosted zone NS
   - `dig NS domain` → must return the hosted zone's nameservers
   - Validation records → must resolve from public DNS

9. **Hosted zone recreation breaks NS delegation.** Each new hosted zone gets new
   nameservers. If you ever delete and recreate a hosted zone, you must update the
   registrar's NS records. This is the #1 cause of "DNS was working, now it's not."

10. **Check from multiple resolvers.** DNS propagation isn't instant. Verify from
    Google (8.8.8.8), Cloudflare (1.1.1.1), and the authoritative NS directly to
    confirm propagation is complete.

11. **CAA records can silently block certificate issuance.** Always check
    `dig CAA domain` — if a CAA record exists that doesn't include `amazon.com` or
    `amazontrust.com`, ACM cannot issue a certificate.

### CI/CD

12. **Set up secrets before the first push.** Our first few GitHub Actions runs
    failed because AWS secrets weren't configured yet. In future projects, set up
    secrets before pushing the workflow file.

13. **Use scoped IAM policies.** The `github-deploy` user can only write to one
    S3 bucket and create CloudFront invalidations. No admin access, no danger of
    accidental infrastructure changes from CI/CD.

### General workflow

14. **Do infrastructure in parallel with content.** While CloudFormation was deploying
    (slow), we created the GitHub repo, set up IAM, and configured secrets. Always
    identify the long-running step and parallelize around it.

15. **Build verification checkpoints into each step.** After every change:
    - Hugo: `hugo --minify` — does it build?
    - AWS: `describe-stacks` / `describe-stack-events` — what's the status?
    - Site: `curl -I https://domain` — is it serving?
    This caught issues early rather than at the end.

16. **Document as you go.** We created `DNS_AND_ACM_EXPLAINED.md` and
    `WORKFLOW_GUIDE.md` during the process. Writing docs while the context is fresh
    produces much better documentation than trying to recall details later.

17. **Third-party integrations have their own setup steps.** Giscus required three
    separate actions: enable Discussions, configure hugo.yaml, AND install the GitHub
    App. Always check the full integration checklist, not just the code changes.

---

## 6. Final State

### What's running

| Resource | Details |
|---|---|
| Site URL | https://xiaoyong.org |
| GitHub repo | https://github.com/xiaoyongaz/xiaoyong.org |
| AWS account | 385055690025 (CLI profile: `xiaoyong-personal`) |
| S3 bucket | `xiaoyong-org-site` (us-east-1) |
| CloudFront distribution | `E227RHMXZMUUN2` (d180vuf8zzogtd.cloudfront.net) |
| ACM certificate | `ff1c9d45-64be-4825-8e63-3e661b170992` (us-east-1, ISSUED) |
| Route 53 hosted zone | `Z00521042ARS1I4TUAL7I` |
| CI/CD IAM user | `github-deploy-xiaoyong-org` |
| Hugo version | v0.160.0+extended |
| Theme | PaperMod (Git submodule) |

### Monthly cost

| Service | Cost |
|---|---|
| Route 53 hosted zone | $0.50 |
| S3 storage + requests | ~$0.01 |
| CloudFront | Free tier (1TB/month) |
| ACM certificate | Free |
| GitHub Actions | Free (public repo) |
| **Total** | **~$0.51/month** |

### Day-to-day workflow

```
Write markdown → hugo server -D (preview) → git push (auto-deploys in ~20s)
```

### Features live

- Full-text search (client-side, Fuse.js)
- Tags and categories with browsing/filtering
- Dark/light mode (auto-detects OS preference, manual toggle)
- Syntax highlighting (server-side rendered, zero JS)
- Comments on posts (giscus / GitHub Discussions)
- GitHub repo card and gist embed shortcodes
- RSS feed
- Reading time estimate
- "Suggest Changes" link to GitHub on every post
- HTTP → HTTPS redirect
- www and non-www both work

---

## 7. Timeline Summary

| Time | Activity | Status |
|---|---|---|
| T+0min | Requirements gathering (4 questions) | Clean |
| T+2min | Hugo install + site scaffold | Clean |
| T+7min | Site configuration + content + shortcodes | Minor fix (template comment syntax) |
| T+12min | AWS CLI profile setup | Clean (user did console steps) |
| T+15min | CloudFormation template created | Clean |
| T+17min | First deploy attempt | **Failed** (Issue 1: dots in names) |
| T+22min | Second deploy attempt | Started, hung on ACM |
| T+30min | Diagnosed NS mismatch | **Fixed** (Issue 2: updated registrar NS) |
| T+45min | ACM validated, CloudFront created | Hung on DNS records |
| T+50min | Diagnosed pre-existing A records | **Fixed** (Issue 3: deleted old records) |
| T+51min | Stack CREATE_COMPLETE | All infrastructure up |
| T+53min | GitHub secrets configured, first S3 sync | Site live at https://xiaoyong.org |
| T+55min | Verified CI/CD pipeline | GitHub Actions deploy successful |
| T+60min | Giscus comments configured | Minor fix (comments param + app install) |
| T+65min | Documentation created | DNS_AND_ACM_EXPLAINED.md, WORKFLOW_GUIDE.md |

**Total active time:** ~65 minutes
**Longest blocker:** DNS/ACM validation (~25 minutes, mostly waiting for propagation)
