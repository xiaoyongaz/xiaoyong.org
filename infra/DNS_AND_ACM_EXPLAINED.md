# How Domain Registration, Route 53, and ACM Work Together

This document explains the full chain from domain registration to serving HTTPS traffic
for `xiaoyong.org`, including what happens behind the scenes and how to diagnose issues.

---

## 1. Domain Registration (Amazon Registrar)

### What is a Domain Registrar?

A **domain registrar** is a company authorized by ICANN to sell domain names. When you
register `xiaoyong.org`, the registrar:

1. Reserves the name in the `.org` TLD (Top Level Domain) registry
2. Sets **nameserver (NS) records** at the registry level — these tell the entire internet
   "to find DNS records for xiaoyong.org, ask these nameservers"

In our case, the registrar is **Amazon Registrar, Inc.** (part of Route 53 Domains).

### The Nameserver Chain

When someone types `xiaoyong.org` in a browser, DNS resolution follows this chain:

```
Browser → Recursive Resolver (e.g., 8.8.8.8)
  → Root DNS servers ("who handles .org?")
    → .org TLD servers ("who handles xiaoyong.org?")
      → Nameservers registered for xiaoyong.org
        → Returns the IP address (A record)
```

The critical link is step 4: the `.org` TLD servers return whichever nameservers the
**registrar** has on file. If these don't match your hosted zone, DNS is broken.

### What went wrong in our setup

```
Registrar NS (old):              Hosted Zone NS (current):
ns-389.awsdns-48.com             ns-49.awsdns-06.com
ns-616.awsdns-13.net             ns-875.awsdns-45.net
ns-1987.awsdns-56.co.uk          ns-1587.awsdns-06.co.uk
ns-1027.awsdns-00.org            ns-1218.awsdns-24.org
```

This mismatch happens when you **delete and recreate a hosted zone**. Each new hosted zone
gets a fresh set of 4 nameservers, but the registrar still points to the old ones. The fix
is to update the registrar's NS records to match the new hosted zone.

---

## 2. Route 53 Hosted Zone

### What is a Hosted Zone?

A **hosted zone** is a container for DNS records for a domain. It's essentially a DNS
database that Route 53's nameservers serve to the internet.

**Hosted Zone ID**: `Z00521042ARS1I4TUAL7I`

When you create a hosted zone for `xiaoyong.org`, Route 53 automatically creates:

- **NS record** — lists the 4 authoritative nameservers for this zone
- **SOA record** — Start of Authority, contains zone metadata (serial number, refresh
  intervals, admin contact)

You then add your own records:

| Record Type | Name | Value | Purpose |
|---|---|---|---|
| A (Alias) | xiaoyong.org | CloudFront distribution | Routes root domain to CDN |
| A (Alias) | www.xiaoyong.org | CloudFront distribution | Routes www to CDN |
| AAAA (Alias) | xiaoyong.org | CloudFront distribution | IPv6 support |
| AAAA (Alias) | www.xiaoyong.org | CloudFront distribution | IPv6 support |
| CNAME | _0756a5fa...xiaoyong.org | _59e1028b...acm-validations.aws | ACM certificate validation |

### Alias Records vs Regular Records

Route 53 **alias records** are special — they let you point a domain's apex (root, e.g.,
`xiaoyong.org` without `www`) to an AWS resource like CloudFront. Regular DNS doesn't
allow CNAME at the zone apex (RFC restriction), but alias records work around this by
resolving at the Route 53 level before returning the response.

### Hosted Zone vs Registrar — The Key Distinction

| | Registrar | Hosted Zone |
|---|---|---|
| What it does | Tells the internet WHERE to look | Provides the actual DNS answers |
| Contains | Nameserver list only | All DNS records (A, CNAME, MX, etc.) |
| Managed at | Route 53 Domains / domain registrar | Route 53 Hosted Zones |
| Changed via | `update-domain-nameservers` | `change-resource-record-sets` |

**Both must be in sync** — the registrar points to nameservers, and those nameservers
must be the ones serving your hosted zone.

---

## 3. ACM (AWS Certificate Manager)

### What ACM Does

ACM issues free SSL/TLS certificates for your domains. These certificates enable HTTPS
(the padlock in the browser). For CloudFront, the certificate **must be in us-east-1**.

### DNS Validation — How It Works

When you request a certificate for `xiaoyong.org` and `*.xiaoyong.org`, ACM needs to
verify you own the domain. With DNS validation:

1. **ACM generates a challenge**: a unique CNAME record you must add to your DNS

   ```
   Name:  _0756a5fa03640dd5d4ac7926a58e8719.xiaoyong.org
   Value: _59e1028b9da152e3cf9ce3bd04c754f7.htgdxnmnnj.acm-validations.aws
   ```

2. **You add the CNAME to Route 53** (CloudFormation does this automatically when you
   specify `DomainValidationOptions` with `HostedZoneId`)

3. **ACM periodically queries DNS** for this CNAME. When it resolves correctly, ACM
   marks the certificate as `ISSUED`

4. **The CNAME stays forever** — ACM uses it for automatic annual renewal too

### Why Validation Was Stuck

For ACM to validate, the full DNS chain must work:

```
ACM queries: _0756a5fa...xiaoyong.org
  → .org TLD: "ask these nameservers for xiaoyong.org"
    → Nameservers (must be Route 53's): "here's the CNAME record"
      → ACM verifies the value matches → ISSUED
```

If the registrar's nameservers don't match the hosted zone (our bug), the TLD sends
the query to the **wrong** nameservers, which don't have the validation CNAME, so ACM
never sees it.

### Certificate Details

```
ARN:      arn:aws:acm:us-east-1:385055690025:certificate/ff1c9d45-64be-4825-8e63-3e661b170992
Domain:   xiaoyong.org
SANs:     *.xiaoyong.org (wildcard — covers all subdomains)
Region:   us-east-1 (required for CloudFront)
Method:   DNS validation
```

Note: Both `xiaoyong.org` and `*.xiaoyong.org` use the **same** CNAME validation record.
This is by design — ACM deduplicates when the base domain is the same.

---

## 4. CloudFront Distribution, S3 Bucket Policy, and DNS Records

These three resources depend on each other and on the ACM certificate. Here's how
they relate and what each does.

### CloudFront Distribution

CloudFront is AWS's Content Delivery Network (CDN). It caches your static site at
**edge locations** worldwide so visitors get fast responses regardless of location.

**Key configuration in our setup:**

| Setting | Value | Why |
|---|---|---|
| Origin | S3 bucket `xiaoyong-org-site` (regional endpoint) | Where CloudFront fetches content from |
| Origin Access Control (OAC) | `xiaoyong-org-oac` | Authenticates CloudFront → S3 requests (replaces legacy OAI) |
| Aliases (CNAMEs) | `xiaoyong.org`, `www.xiaoyong.org` | Tells CloudFront to accept requests for these domains |
| SSL Certificate | ACM cert (us-east-1) | Enables HTTPS for the aliases above |
| Default Root Object | `index.html` | When someone visits `/`, serve `/index.html` |
| Viewer Protocol Policy | `redirect-to-https` | HTTP requests get 301 redirected to HTTPS |
| Price Class | `PriceClass_100` | Use only US/Canada/Europe edge locations (cheapest) |
| HTTP Version | `http2and3` | Modern protocols for better performance |
| Cache Policy | Custom (`xiaoyong-org-cache-policy`) | Brotli + gzip compression, ignore cookies/query strings |

**Why it depends on ACM certificate:** CloudFront cannot serve HTTPS for custom domains
without a valid certificate. The cert must be `ISSUED` before CloudFront will accept it.

**Creation time:** CloudFront distributions take 3-8 minutes to deploy because AWS must
propagate the configuration to all edge locations globally.

### CloudFront URL Rewrite Function

Hugo generates pages as `posts/hello-world/index.html`, but users visit
`/posts/hello-world/`. CloudFront needs to map directory paths to `index.html` files.

Our CloudFront Function (runs at edge, sub-millisecond):

```javascript
function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (uri.endsWith('/')) {
    request.uri += 'index.html';       // /posts/ → /posts/index.html
  } else if (!uri.includes('.')) {
    request.uri += '/index.html';      // /posts → /posts/index.html
  }
  return request;
}
```

This runs on **viewer-request** — it modifies the request before CloudFront checks
its cache or fetches from S3.

### S3 Bucket Policy (depends on CloudFront)

The S3 bucket has **all public access blocked**. Only CloudFront can read from it,
via Origin Access Control (OAC). The bucket policy looks like:

```json
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::xiaoyong-org-site/*",
    "Condition": {
      "StringEquals": {
        "AWS:SourceArn": "arn:aws:cloudfront::385055690025:distribution/<DIST-ID>"
      }
    }
  }]
}
```

**Why it depends on CloudFront:** The policy references the CloudFront distribution ARN
in its condition. The distribution must exist first so its ARN is known.

**Why OAC instead of public S3?**
- **Security**: No one can bypass CloudFront and hit S3 directly
- **Cost**: All traffic goes through CloudFront (free tier), not S3 transfer pricing
- **Control**: CloudFront handles caching, HTTPS, and access in one place

### DNS Records (depend on CloudFront)

Four DNS records point your domain to the CloudFront distribution:

| Record | Type | Target | Purpose |
|---|---|---|---|
| `xiaoyong.org` | A (Alias) | `d1234.cloudfront.net` | IPv4 root domain |
| `www.xiaoyong.org` | A (Alias) | `d1234.cloudfront.net` | IPv4 www subdomain |
| `xiaoyong.org` | AAAA (Alias) | `d1234.cloudfront.net` | IPv6 root domain |
| `www.xiaoyong.org` | AAAA (Alias) | `d1234.cloudfront.net` | IPv6 www subdomain |

**Why they depend on CloudFront:** The alias target is the CloudFront distribution's
domain name, which doesn't exist until the distribution is created.

**Why Alias and not CNAME?**
- CNAME records **cannot** be used at the zone apex (`xiaoyong.org` without a subdomain)
  — this is an RFC restriction
- Route 53 Alias records solve this by resolving internally at the DNS level
- Alias records to CloudFront are also **free** (no per-query charge)

**The special CloudFront Hosted Zone ID:** All alias records targeting CloudFront use
`Z2FDTNDATAQYW2` as the hosted zone ID. This is a **constant** — it's AWS's global
hosted zone for all CloudFront distributions, not your hosted zone.

### CloudFormation Dependency Chain

```
Certificate (ACM)  ─────────────────────┐
CloudFrontOAC  ─────────────────────────┤
CloudFrontCachePolicy  ─────────────────┤
URLRewriteFunction  ────────────────────┤
SiteBucket  ────────────────────────────┤
                                        ▼
                              CloudFrontDistribution
                                        │
                              ┌─────────┼──────────────────┐
                              ▼         ▼                  ▼
                       SiteBucketPolicy  DNSRecordRoot     DNSRecordWWW
                                         DNSRecordRootIPv6 DNSRecordWWWIPv6
                                                           │
                                                           ▼
                                                    Stack COMPLETE
```

Everything feeds into CloudFrontDistribution. Once it's created, the bucket policy
and DNS records can be created in parallel, and then the stack completes.

---

## 5. How a Browser Request Gets Your Content — Step by Step

When a user types `https://xiaoyong.org/posts/hello-world/` in their browser,
here is every step that happens:

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│  STEP 1: DNS RESOLUTION                                                         │
│                                                                                  │
│  Browser: "I need the IP address for xiaoyong.org"                              │
│                                                                                  │
│  ┌──────────┐    ┌───────────────────┐    ┌──────────────────┐                  │
│  │  Browser  │───▶│ Recursive Resolver│───▶│ Root DNS (.org)  │                  │
│  └──────────┘    │  (e.g., 8.8.8.8)  │    └──────┬───────────┘                  │
│                  │                    │           │                               │
│                  │                    │◀──────────┘                               │
│                  │                    │  "Ask ns-49.awsdns-06.com"               │
│                  │                    │                                           │
│                  │                    │───▶┌──────────────────────────┐           │
│                  │                    │    │ Route 53 Nameserver      │           │
│                  │                    │◀───│ (Hosted Zone records)    │           │
│                  │                    │    └──────────────────────────┘           │
│                  │                    │  "xiaoyong.org = 13.224.x.x"            │
│                  └────────┬───────────┘  (CloudFront edge IP)                   │
│                           │                                                      │
│                           ▼                                                      │
│                  Browser now knows: xiaoyong.org = 13.224.x.x                   │
└──────────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  STEP 2: TLS HANDSHAKE (HTTPS)                                                  │
│                                                                                  │
│  Browser connects to 13.224.x.x:443 (nearest CloudFront edge location)         │
│                                                                                  │
│  ┌──────────┐         TLS ClientHello          ┌─────────────────────┐          │
│  │  Browser  │────────────────────────────────▶│  CloudFront Edge    │          │
│  │          │   SNI: "xiaoyong.org"            │  (e.g., SFO53-C1)  │          │
│  │          │◀────────────────────────────────│                     │          │
│  │          │  TLS ServerHello + Certificate   │  Presents ACM cert  │          │
│  │          │         (ACM issued)             │  for xiaoyong.org   │          │
│  └──────────┘                                   └─────────────────────┘          │
│                                                                                  │
│  Browser verifies:                                                               │
│  ✓ Certificate is valid for xiaoyong.org                                        │
│  ✓ Certificate is not expired                                                    │
│  ✓ Certificate chain leads to trusted CA (Amazon Trust Services)                │
│  ✓ Connection is now encrypted (TLS 1.2+)                                       │
│  → Padlock appears in browser                                                    │
└──────────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  STEP 3: HTTP REQUEST                                                            │
│                                                                                  │
│  Browser sends (over encrypted TLS connection):                                 │
│                                                                                  │
│    GET /posts/hello-world/ HTTP/2                                                │
│    Host: xiaoyong.org                                                            │
│    Accept: text/html                                                             │
│    Accept-Encoding: gzip, br                                                     │
└──────────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  STEP 4: CLOUDFRONT URL REWRITE FUNCTION (viewer-request)                       │
│                                                                                  │
│  The CloudFront Function runs BEFORE cache lookup:                              │
│                                                                                  │
│    Input URI:  /posts/hello-world/                                               │
│    Rule:       URI ends with "/" → append "index.html"                           │
│    Output URI: /posts/hello-world/index.html                                     │
│                                                                                  │
│  This happens at the edge in < 1ms                                              │
└──────────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  STEP 5: CLOUDFRONT CACHE CHECK                                                  │
│                                                                                  │
│  CloudFront checks its edge cache for /posts/hello-world/index.html             │
│                                                                                  │
│  ┌─────────────────────────────────────────┐                                    │
│  │            CACHE HIT?                    │                                    │
│  │                                          │                                    │
│  │  YES → Skip to Step 7 (return cached     │                                    │
│  │         response, header: X-Cache: Hit)  │                                    │
│  │                                          │                                    │
│  │  NO  → Continue to Step 6 (origin fetch) │                                    │
│  │         (header: X-Cache: Miss)          │                                    │
│  └─────────────────────────────────────────┘                                    │
└──────────────────────────────────────────────────────────────────────────────────┘
                            │ (cache miss)
                            ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  STEP 6: ORIGIN FETCH (CloudFront → S3)                                         │
│                                                                                  │
│  CloudFront sends a request to the S3 bucket origin:                            │
│                                                                                  │
│  ┌─────────────────┐                      ┌──────────────────────────┐          │
│  │  CloudFront Edge │─────────────────────▶│  S3 Bucket               │          │
│  │                  │  GET /posts/hello-   │  (xiaoyong-org-site)     │          │
│  │                  │  world/index.html    │                          │          │
│  │                  │                      │  OAC Authentication:     │          │
│  │                  │  Signed with SigV4   │  ✓ Request signed by     │          │
│  │                  │  (OAC credentials)   │    cloudfront.amazonaws  │          │
│  │                  │                      │    .com                  │          │
│  │                  │◀─────────────────────│  ✓ Distribution ARN      │          │
│  │                  │  200 OK + HTML body  │    matches bucket policy │          │
│  └─────────────────┘                      └──────────────────────────┘          │
│                                                                                  │
│  S3 returns the Hugo-generated HTML file.                                       │
│  CloudFront caches it at the edge per the cache policy (default TTL: 24hr).     │
└──────────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  STEP 7: RESPONSE TO BROWSER                                                    │
│                                                                                  │
│  CloudFront sends the response back (compressed if supported):                  │
│                                                                                  │
│    HTTP/2 200 OK                                                                 │
│    Content-Type: text/html                                                       │
│    Content-Encoding: br  (Brotli compressed)                                    │
│    X-Cache: Miss from cloudfront  (or "Hit" on subsequent requests)             │
│    Via: 1.1 abc123.cloudfront.net (CloudFront)                                  │
│    Cache-Control: public, max-age=3600                                           │
│                                                                                  │
│    <!DOCTYPE html>                                                               │
│    <html>                                                                        │
│      ... your Hugo-generated blog post ...                                       │
│    </html>                                                                       │
└──────────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│  STEP 8: BROWSER RENDERS PAGE                                                    │
│                                                                                  │
│  Browser decompresses Brotli, parses HTML, then fetches sub-resources:          │
│                                                                                  │
│    /assets/css/stylesheet.min.css  ─── (same CloudFront flow, likely cached)    │
│    /assets/js/search.min.js        ─── (same CloudFront flow, likely cached)    │
│                                                                                  │
│  Each sub-resource follows Steps 1-7 (DNS is cached locally, TLS reuses         │
│  the existing connection via HTTP/2 multiplexing).                               │
│                                                                                  │
│  User sees: rendered blog post with syntax highlighting, dark mode toggle,      │
│  navigation, and search — all served from the nearest CloudFront edge.          │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### What makes subsequent requests faster

| Layer | First Visit | Subsequent Visits |
|---|---|---|
| DNS | Full resolution (~50-100ms) | Cached by OS/browser (~0ms) |
| TLS | Full handshake (~50ms) | Session resumption (~10ms) |
| CloudFront | Cache miss → S3 fetch | Cache hit → instant edge response |
| Browser | Downloads all assets | Local cache (immutable assets) |
| Compression | Brotli decompression | Already cached decompressed |

---

## 6. How It All Connects — Infrastructure Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        DOMAIN REGISTRATION                             │
│                                                                        │
│  Amazon Registrar holds: xiaoyong.org → NS records                     │
│  Points to Route 53 nameservers:                                       │
│    ns-49.awsdns-06.com                                                 │
│    ns-875.awsdns-45.net                                                │
│    ns-1587.awsdns-06.co.uk                                             │
│    ns-1218.awsdns-24.org                                               │
└──────────────────────┬──────────────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     ROUTE 53 HOSTED ZONE                               │
│                     (Z00521042ARS1I4TUAL7I)                            │
│                                                                        │
│  Records served by the nameservers above:                              │
│                                                                        │
│  xiaoyong.org          → A (Alias) → CloudFront d1234.cloudfront.net   │
│  www.xiaoyong.org      → A (Alias) → CloudFront d1234.cloudfront.net   │
│  _0756a5fa...          → CNAME     → ACM validation token              │
└──────────────────────┬──────────────────────────────────────────────────┘
                       │
              ┌────────┴────────┐
              ▼                 ▼
┌──────────────────────┐  ┌──────────────────────────────────────────────┐
│     ACM CERTIFICATE  │  │           CLOUDFRONT DISTRIBUTION            │
│                      │  │                                              │
│ Validates domain     │  │  Origin: S3 bucket (xiaoyong-org-site)       │
│ ownership via the    │  │  SSL: ACM certificate                        │
│ CNAME record         │──│  Aliases: xiaoyong.org, www.xiaoyong.org     │
│                      │  │  Behavior: HTTPS redirect, compress, cache   │
│ Status: ISSUED       │  │                                              │
└──────────────────────┘  └──────────────────┬───────────────────────────┘
                                             │
                                             ▼
                          ┌──────────────────────────────────────────────┐
                          │              S3 BUCKET                       │
                          │         (xiaoyong-org-site)                  │
                          │                                              │
                          │  Contains: Hugo-generated static files       │
                          │  Access: CloudFront OAC only (no public)     │
                          └──────────────────────────────────────────────┘
```

### Request Flow (user visits https://xiaoyong.org)

1. Browser asks recursive resolver for `xiaoyong.org`
2. Resolver walks the DNS chain → Route 53 returns CloudFront's IP
3. Browser connects to CloudFront via HTTPS
4. CloudFront presents the ACM certificate (browser sees the padlock)
5. CloudFront checks its cache; on miss, fetches from S3 via OAC
6. Response returned to browser

---

## 7. Diagnostic Commands Reference

### DNS Diagnostics

```bash
# Check which nameservers the internet sees for your domain
# These must match your Route 53 hosted zone NS records
dig NS xiaoyong.org +short

# Check what nameservers Route 53 assigned to your hosted zone
aws route53 get-hosted-zone --id Z00521042ARS1I4TUAL7I \
  --query "DelegationSet.NameServers" --output json \
  --profile xiaoyong-personal

# Check what nameservers the registrar has on file
# These must match the hosted zone NS records above
aws route53domains get-domain-detail --domain-name xiaoyong.org \
  --region us-east-1 \
  --query "Nameservers[].Name" --output json \
  --profile xiaoyong-personal

# Fix mismatched nameservers (update registrar to match hosted zone)
aws route53domains update-domain-nameservers --domain-name xiaoyong.org \
  --region us-east-1 \
  --nameservers Name=ns-49.awsdns-06.com Name=ns-875.awsdns-45.net \
               Name=ns-1587.awsdns-06.co.uk Name=ns-1218.awsdns-24.org \
  --profile xiaoyong-personal

# List all DNS records in the hosted zone
aws route53 list-resource-record-sets \
  --hosted-zone-id Z00521042ARS1I4TUAL7I \
  --profile xiaoyong-personal

# Verify a specific record resolves (e.g., ACM validation CNAME)
dig CNAME _0756a5fa03640dd5d4ac7926a58e8719.xiaoyong.org +short

# Check A record resolution (after CloudFront is set up)
dig A xiaoyong.org +short

# Full DNS trace for debugging
dig xiaoyong.org +trace
```

### ACM Certificate Diagnostics

```bash
# List all certificates for your domain
aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[?DomainName=='xiaoyong.org']" \
  --output json \
  --profile xiaoyong-personal

# Get detailed certificate status including validation details
aws acm describe-certificate \
  --certificate-arn "arn:aws:acm:us-east-1:385055690025:certificate/ff1c9d45-64be-4825-8e63-3e661b170992" \
  --region us-east-1 \
  --query "Certificate.{Status:Status,Validations:DomainValidationOptions}" \
  --output json \
  --profile xiaoyong-personal

# Possible Status values:
#   PENDING_VALIDATION - waiting for DNS validation
#   ISSUED             - validated and ready to use
#   FAILED             - validation timed out (72 hours) or errored
#   EXPIRED            - certificate not renewed
```

### CloudFormation Diagnostics

```bash
# Check overall stack status
aws cloudformation describe-stacks --stack-name xiaoyong-org-site \
  --region us-east-1 \
  --query "Stacks[0].StackStatus" --output text \
  --profile xiaoyong-personal

# See which resources failed and why
aws cloudformation describe-stack-events --stack-name xiaoyong-org-site \
  --region us-east-1 \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
  --output table \
  --profile xiaoyong-personal

# See which resources are done vs still in progress
aws cloudformation describe-stack-events --stack-name xiaoyong-org-site \
  --region us-east-1 \
  --query "StackEvents[?ResourceStatus=='CREATE_COMPLETE'].LogicalResourceId" \
  --output table \
  --profile xiaoyong-personal

# Get stack outputs (bucket name, CloudFront distribution ID, etc.)
aws cloudformation describe-stacks --stack-name xiaoyong-org-site \
  --region us-east-1 \
  --query "Stacks[0].Outputs" --output table \
  --profile xiaoyong-personal
```

### End-to-End Verification (after deployment)

```bash
# Verify HTTPS works and check response headers
curl -I https://xiaoyong.org

# Expected headers:
#   HTTP/2 200
#   content-type: text/html
#   server: AmazonS3
#   x-cache: Hit from cloudfront (or Miss on first request)
#   via: ... cloudfront ...

# Verify HTTP redirects to HTTPS
curl -I http://xiaoyong.org
# Expected: 301 redirect to https://xiaoyong.org

# Verify www works
curl -I https://www.xiaoyong.org

# Check SSL certificate details
echo | openssl s_client -servername xiaoyong.org -connect xiaoyong.org:443 2>/dev/null | openssl x509 -noout -subject -dates
```

---

## 8. Common Issues and Fixes

| Symptom | Cause | Fix |
|---|---|---|
| `dig NS xiaoyong.org` returns nothing or wrong NS | Registrar nameservers don't match hosted zone | `update-domain-nameservers` |
| ACM stuck on PENDING_VALIDATION | DNS not resolving validation CNAME | Fix NS records, then verify CNAME resolves with `dig` |
| ACM status is FAILED | Validation timed out (72 hours) | Request a new certificate, ensure DNS is correct first |
| CloudFront returns 403 | S3 bucket policy doesn't allow OAC, or object doesn't exist | Check bucket policy, verify `hugo --minify` output was uploaded |
| CloudFront returns 404 on subpaths | URL rewrite function not attached or not rewriting `/path/` → `/path/index.html` | Check CloudFront function association |
| Site loads but no HTTPS padlock | Mixed content (HTTP resources on HTTPS page) | Ensure all asset URLs use relative paths or HTTPS |
| `www.xiaoyong.org` doesn't work | Missing DNS record or missing CloudFront alternate domain | Add both A/AAAA records and both aliases on CloudFront |
