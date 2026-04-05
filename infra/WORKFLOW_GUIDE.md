# Workflow Guide — xiaoyong.org

This document covers the day-to-day workflow for making changes to the site,
from writing content to modifying infrastructure.

---

## 1. Content Changes (Posts, Notes, Pages)

### Creating a new blog post

```bash
# Create a new post file
hugo new content posts/my-new-post.md
```

This creates `content/posts/my-new-post.md` with front matter from the archetype.
Edit the file with your content:

```markdown
---
title: "My New Post"
date: 2026-04-05
draft: false
tags: ["aws", "hugo"]
categories: ["blog"]
summary: "A short description shown in list views and search results."
---

Your markdown content here.

## Code blocks with syntax highlighting

```python
def hello():
    print("Hello!")
```

## Embed a GitHub repo card

{{</* github-repo "xiaoyongaz/xiaoyong.org" */>}}

## Embed a GitHub gist

{{</* gist "xiaoyongaz" "abc123" */>}}
```

### Front matter reference

| Field | Required | Description |
|---|---|---|
| `title` | Yes | Post title |
| `date` | Yes | Publication date (YYYY-MM-DD) |
| `draft` | Yes | Set to `false` to publish, `true` to hide |
| `tags` | No | List of tags (appear in tag cloud and search) |
| `categories` | No | List of categories |
| `summary` | No | Short description for list pages and search |
| `ShowToc` | No | Override table of contents (default: true) |
| `ShowReadingTime` | No | Override reading time display (default: true) |
| `comments` | No | Override comments on this post (default: true) |
| `weight` | No | Sort order within a section (lower = first) |

### Creating a new note (TIL / quick note)

Same process, different section:

```bash
hugo new content notes/my-note.md
```

Notes and posts are identical in structure — the separation is purely organizational.

### Editing existing content

Just edit the markdown file directly. No special commands needed.

```bash
# Edit with your preferred editor
vim content/posts/my-new-post.md
code content/posts/my-new-post.md
```

### Adding images

Place images in `static/images/` and reference them in markdown:

```bash
mkdir -p static/images
cp ~/screenshot.png static/images/
```

```markdown
![Alt text](/images/screenshot.png)
```

---

## 2. Build and Preview Locally

### Start the dev server

```bash
hugo server -D
```

- Opens at **http://localhost:1313**
- `-D` includes draft posts (posts with `draft: true`)
- **Live reload**: changes to content or config auto-refresh the browser
- Press `Ctrl+C` to stop

### Build for production (without serving)

```bash
hugo --minify
```

- Output goes to `public/` directory
- `--minify` compresses HTML/CSS/JS
- Check `public/` to verify the output looks right

### Common local checks

```bash
# Verify site builds without errors
hugo --minify 2>&1

# Check how many pages were generated
hugo --minify 2>&1 | grep "Pages"

# Verify a specific page exists in output
ls public/posts/my-new-post/index.html

# Check that search index includes your new content
grep "my-new-post" public/index.json

# Verify giscus comment script is present on a post
grep "giscus" public/posts/my-new-post/index.html
```

---

## 3. Push to GitHub and Deploy

### Standard content deployment

```bash
# Check what changed
git status
git diff

# Stage your changes
git add content/posts/my-new-post.md
# Or for multiple files:
git add content/

# Commit
git commit -m "Add post: my new post title"

# Push — triggers automatic deployment
git push
```

GitHub Actions will:
1. Build the site with `hugo --minify`
2. Sync files to S3
3. Invalidate the CloudFront cache

### Monitor the deployment

```bash
# Check if the workflow is running / succeeded
gh run list --repo xiaoyongaz/xiaoyong.org --limit 1

# Watch a run in real-time
gh run watch --repo xiaoyongaz/xiaoyong.org

# View logs if a run failed
gh run view --repo xiaoyongaz/xiaoyong.org --log-failed
```

### Validate the live site

```bash
# Verify the site is serving (may need to wait ~30s for CloudFront cache)
curl -I https://xiaoyong.org

# Check a specific page
curl -s https://xiaoyong.org/posts/my-new-post/ | head -20

# Verify HTTP → HTTPS redirect
curl -I http://xiaoyong.org

# Verify www works
curl -I https://www.xiaoyong.org

# Check SSL certificate
echo | openssl s_client -servername xiaoyong.org -connect xiaoyong.org:443 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

If the content seems stale after deployment, the CloudFront cache may not have
fully invalidated yet. You can force it:

```bash
AWS_PROFILE=xiaoyong-personal aws cloudfront create-invalidation \
  --distribution-id E227RHMXZMUUN2 --paths "/*"
```

---

## 4. Infrastructure Changes

Infrastructure changes affect the AWS resources (S3, CloudFront, ACM, Route 53)
and require more care than content changes.

### What counts as an infrastructure change?

- Modifying `infra/cloudformation.yaml` (AWS resources)
- Modifying `.github/workflows/deploy.yaml` (CI/CD pipeline)
- Modifying `infra/github-deploy-policy.json` (IAM permissions)
- Changing `hugo.yaml` settings that affect build output structure

### Making CloudFormation changes

**Step 1: Edit the template**

```bash
vim infra/cloudformation.yaml
```

**Step 2: Validate the template**

```bash
AWS_PROFILE=xiaoyong-personal aws cloudformation validate-template \
  --template-body file://infra/cloudformation.yaml \
  --region us-east-1
```

**Step 3: Preview changes (changeset)**

Before applying, always preview what CloudFormation will do:

```bash
AWS_PROFILE=xiaoyong-personal aws cloudformation deploy \
  --template-file infra/cloudformation.yaml \
  --stack-name xiaoyong-org-site \
  --region us-east-1 \
  --parameter-overrides \
    DomainName=xiaoyong.org \
    HostedZoneId=Z00521042ARS1I4TUAL7I \
  --no-execute-changeset
```

This creates a changeset without executing it. Review it in the AWS Console or:

```bash
# List changesets
AWS_PROFILE=xiaoyong-personal aws cloudformation list-change-sets \
  --stack-name xiaoyong-org-site --region us-east-1

# Describe a specific changeset
AWS_PROFILE=xiaoyong-personal aws cloudformation describe-change-set \
  --stack-name xiaoyong-org-site \
  --change-set-name <changeset-name> \
  --region us-east-1
```

**Step 4: Apply changes**

```bash
AWS_PROFILE=xiaoyong-personal ./infra/deploy-infra.sh
```

**Step 5: Verify**

```bash
# Check stack status
AWS_PROFILE=xiaoyong-personal aws cloudformation describe-stacks \
  --stack-name xiaoyong-org-site --region us-east-1 \
  --query "Stacks[0].StackStatus" --output text

# Check stack outputs
AWS_PROFILE=xiaoyong-personal aws cloudformation describe-stacks \
  --stack-name xiaoyong-org-site --region us-east-1 \
  --query "Stacks[0].Outputs" --output table

# Verify the site still works
curl -I https://xiaoyong.org
```

### Dangerous infrastructure operations

These actions can cause **downtime**. Always verify in a non-peak time:

| Operation | Risk | Mitigation |
|---|---|---|
| Changing CloudFront aliases | Site unreachable if misconfigured | Verify cert covers new aliases first |
| Changing S3 bucket name | All content must be re-uploaded | Sync content before switching |
| Deleting/recreating hosted zone | DNS breaks, ACM cert invalidated | Almost never needed |
| Changing ACM certificate | CloudFront needs new cert ARN | New cert must be ISSUED before switching |
| Modifying CloudFront cache behavior | May serve stale or wrong content | Test with a single path first |

### Modifying the CI/CD pipeline

Changes to `.github/workflows/deploy.yaml` take effect on the **next push to main**.
Test workflow changes on a branch first:

```bash
# Create a test branch
git checkout -b test-workflow

# Edit the workflow
vim .github/workflows/deploy.yaml

# Push the branch (this won't trigger deploy since it's not main)
git push -u origin test-workflow

# Manually trigger the workflow on the test branch (if workflow_dispatch is enabled)
gh workflow run deploy.yaml --ref test-workflow

# Watch the run
gh run watch --repo xiaoyongaz/xiaoyong.org

# If it works, merge to main
git checkout main
git merge test-workflow
git push

# Clean up
git branch -d test-workflow
git push origin --delete test-workflow
```

### Updating IAM permissions

If the deploy workflow needs new AWS permissions (e.g., you add a Lambda function):

```bash
# 1. Edit the policy
vim infra/github-deploy-policy.json

# 2. Get the current policy ARN
AWS_PROFILE=xiaoyong-personal aws iam list-policies \
  --query "Policies[?PolicyName=='xiaoyong-org-deploy'].Arn" --output text

# 3. Create a new version of the policy
AWS_PROFILE=xiaoyong-personal aws iam create-policy-version \
  --policy-arn <POLICY_ARN> \
  --policy-document file://infra/github-deploy-policy.json \
  --set-as-default

# 4. Verify
AWS_PROFILE=xiaoyong-personal aws iam get-policy-version \
  --policy-arn <POLICY_ARN> \
  --version-id $(aws iam get-policy --policy-arn <POLICY_ARN> \
    --query "Policy.DefaultVersionId" --output text --profile xiaoyong-personal) \
  --profile xiaoyong-personal
```

---

## 5. Hugo Configuration Changes

Changes to `hugo.yaml` affect the entire site. Common modifications:

### Adding a new menu item

```yaml
menu:
  main:
    - identifier: projects
      name: Projects
      url: /projects/
      weight: 4  # Adjust weight to control ordering
```

Then create `content/projects/_index.md`.

### Adding a new content section

1. Create the directory and index:
   ```bash
   mkdir content/projects
   ```
2. Create `content/projects/_index.md`:
   ```markdown
   ---
   title: "Projects"
   description: "Things I'm building"
   ---
   ```
3. Add a menu entry in `hugo.yaml` (see above)
4. Add individual pages: `content/projects/my-project.md`

### Changing the theme / appearance

PaperMod settings live under `params:` in `hugo.yaml`. Useful toggles:

```yaml
params:
  defaultTheme: auto    # auto | light | dark
  ShowReadingTime: true  # Show "X min read"
  ShowShareButtons: true # Social share buttons
  ShowPostNavLinks: true # Previous/Next post navigation
  ShowBreadCrumbs: true  # Breadcrumb navigation
  ShowCodeCopyButtons: true # Copy button on code blocks
  showtoc: true          # Table of contents
```

### Updating the PaperMod theme

```bash
cd themes/PaperMod
git pull origin master
cd ../..

# Test locally
hugo server

# If everything looks good, commit the submodule update
git add themes/PaperMod
git commit -m "Update PaperMod theme"
git push
```

---

## 6. Quick Reference — Common Tasks

| Task | Command |
|---|---|
| New blog post | `hugo new content posts/my-post.md` |
| New note | `hugo new content notes/my-note.md` |
| Local preview | `hugo server -D` |
| Build for production | `hugo --minify` |
| Deploy | `git add . && git commit -m "message" && git push` |
| Check deploy status | `gh run list --repo xiaoyongaz/xiaoyong.org --limit 1` |
| Force cache refresh | `AWS_PROFILE=xiaoyong-personal aws cloudfront create-invalidation --distribution-id E227RHMXZMUUN2 --paths "/*"` |
| Validate CloudFormation | `AWS_PROFILE=xiaoyong-personal aws cloudformation validate-template --template-body file://infra/cloudformation.yaml --region us-east-1` |
| Deploy infra changes | `AWS_PROFILE=xiaoyong-personal ./infra/deploy-infra.sh` |
| Check infra status | `AWS_PROFILE=xiaoyong-personal aws cloudformation describe-stacks --stack-name xiaoyong-org-site --region us-east-1 --query "Stacks[0].StackStatus" --output text` |
| Update PaperMod theme | `cd themes/PaperMod && git pull origin master && cd ../..` |
| Watch deploy logs | `gh run watch --repo xiaoyongaz/xiaoyong.org` |

---

## 7. File Structure Reference

```
xiaoyong.org/
├── .github/workflows/
│   └── deploy.yaml              # CI/CD pipeline (build + deploy to AWS)
├── content/
│   ├── posts/                   # Blog posts (longer-form writing)
│   │   ├── _index.md            # Section index page
│   │   └── hello-world.md       # Individual post
│   ├── notes/                   # Quick notes / TILs
│   │   ├── _index.md            # Section index page
│   │   └── first-note.md        # Individual note
│   ├── about.md                 # About page
│   └── search.md                # Search page (PaperMod built-in)
├── infra/
│   ├── cloudformation.yaml      # AWS infrastructure definition
│   ├── deploy-infra.sh          # Script to deploy/update CloudFormation stack
│   ├── github-deploy-policy.json # IAM policy for CI/CD user
│   ├── setup-iam.sh             # Script to create CI/CD IAM user
│   ├── DNS_AND_ACM_EXPLAINED.md # Architecture and troubleshooting docs
│   └── WORKFLOW_GUIDE.md        # This file
├── layouts/
│   ├── partials/
│   │   └── comments.html        # Giscus comments partial
│   └── shortcodes/
│       ├── github-repo.html     # {{</* github-repo "owner/repo" */>}}
│       └── gist.html            # {{</* gist "user" "id" */>}}
├── static/                      # Static assets (images, files) — served as-is
├── themes/PaperMod/             # Theme (Git submodule — don't edit directly)
├── hugo.yaml                    # Site configuration
└── .gitignore                   # Ignores public/, resources/, .hugo_build.lock
```

### What goes where

| I want to... | Put it in... |
|---|---|
| Write a blog post | `content/posts/my-post.md` |
| Write a quick note | `content/notes/my-note.md` |
| Add a standalone page | `content/my-page.md` |
| Add a new content section | `content/new-section/_index.md` |
| Add images/downloads | `static/images/` or `static/files/` |
| Add a custom shortcode | `layouts/shortcodes/my-shortcode.html` |
| Override a theme template | `layouts/_default/` or `layouts/partials/` |
| Change AWS resources | `infra/cloudformation.yaml` |
| Change deploy pipeline | `.github/workflows/deploy.yaml` |
| Change site settings | `hugo.yaml` |
