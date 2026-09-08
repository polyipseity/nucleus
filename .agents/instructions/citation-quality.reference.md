---
description: "Reference: citation quality rules — source preference, URL standardization, deprecation hygiene, and citation style in code/config. Read on demand when citing external sources in code comments or documentation."
name: "Citation Quality Reference"
---

# Citation quality reference

When citing external sources (APIs, documentation, vendor settings, support articles), keep URLs and content correct to prevent drift.

## Source preference (priority order)

For claims about behavior, APIs, or configuration settings:

1. **Developer/API documentation first**
   - Apple: `developer.apple.com/documentation/*`
   - Microsoft: `learn.microsoft.com/en-us/windows/*` or `learn.microsoft.com/en-us/dotnet/*`
   - Official language/framework reference
   - IETF RFCs for standards

2. **User-oriented help only when developer docs don't exist**
   - Apple: `support.apple.com/en-us/guide/*` (explicit locale prefix)
   - Microsoft: KB articles
   - Vendor release notes or blogs
   - If you must use a support page where a developer doc exists, add a `# WHY:` comment explaining why.

3. **Avoid**
   - Mirrors, archived copies, or third-party rewrites (use canonical source)
   - Forum posts, Reddit, Stack Overflow (document internal consensus via comments, not external links)
   - Expired links or redirect chains

## URL standardization

**Apple support URLs must include explicit US English locale:**

- ✅ `https://support.apple.com/en-us/guide/mac-help/...`
- ✅ `https://support.apple.com/en-us/HT123456`
- ❌ `https://support.apple.com/guide/mac-help/...` (no locale prefix; redirects based on browser locale)
- ❌ `https://support.apple.com/HT123456` (no locale prefix)

Use canonical, stable URLs without query parameters. Avoid short URLs or redirects when a canonical form exists. Include article/page IDs (HT numbers, doc IDs) for long-term stability.

## Deprecation hygiene

1. **Do not cite deprecated APIs as current behavior.** Carbon framework (macOS) → replace with InputMethodKit, AppKit, SwiftUI. CoreGraphics (legacy) → consider modern Cocoa APIs. When in doubt, check Apple's official deprecation notices.
2. **If a deprecated API must be documented** (historical context): mark it as deprecated, cite the deprecation notice, and cite the modern replacement in the same block:

   ```nix
   # Old approach (deprecated): use Carbon Text Services Manager
   # Modern approach: use InputMethodKit
   # Source: https://developer.apple.com/documentation/inputmethodkit
   ```

## Citation style in code/config

Keep citations adjacent to the claim they support:

```nix
# Good: Source immediately follows the setting claim
# Prevent .DS_Store files on network and removable volumes.
# Source: https://support.apple.com/en-us/HT208209
"com.apple.desktopservices" = {
  DSDontWriteNetworkStores = true;
};

# Less good: Source buried far from the code
"com.apple.desktopservices" = {
  DSDontWriteNetworkStores = true; # See https://...
};

# Avoid: No source at all, or source in wrong place
# Source: https://...
# Many lines later...
"com.apple.foo" = { ... };
```

For multi-line settings, put the source at the top of the comment block:

```nix
# Software Update: check, download, and install automatically.
# Source: https://support.apple.com/en-us/guide/deployment/manage-software-updates-depafd2fad80/web
"com.apple.SoftwareUpdate" = {
  AutomaticCheckEnabled = true;
  AutomaticDownload = true;
  CriticalUpdateInstall = true;
};
```
