---
title: "TIL: Hugo builds are fast"
date: 2026-04-04
draft: false
tags: ["hugo", "til"]
categories: ["notes"]
summary: "Hugo builds an entire static site in milliseconds."
---

Hugo is incredibly fast. A full site build with hundreds of pages takes less than a second. This makes the write-preview-deploy loop nearly instant.

```bash
hugo --minify
# Start                           0 ms
# Built in                       42 ms
```
