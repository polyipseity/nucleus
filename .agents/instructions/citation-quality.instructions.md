---
description: "Use when adding external citations/source references to code, documentation, or configuration files. Enforces URL quality, developer vs. user documentation preference, and deprecation hygiene."
name: "Citation Quality Standards"
applyTo: "src/**/*.nix, src/**/*.ps1, src/hosts/windows/**/*.yml, scripts/**, src/scripts/**, src/hosts/**/MANUAL.md, README.md, AGENTS.md, .agents/**/*.md"
---

## Citation quality standards

When citing external sources (APIs, documentation, vendor settings, support articles), maintain URL and content correctness to prevent drift and ensure maintainability.

### Source preference (priority order)

For claims about behavior, APIs, or configuration settings:

1. **Developer/API documentation first**
   - Apple: `developer.apple.com/documentation/*`
   - Microsoft: `learn.microsoft.com/en-us/windows/*` or `learn.microsoft.com/en-us/dotnet/*`
   - Official language/framework reference
   - IETF RFCs for standards

2. **User-oriented help only when developer docs don't exist**
   - Apple: `support.apple.com/en-us/guide/*` (add explicit locale prefix)
   - Microsoft: KB articles
   - Vendor release notes or blogs
   - If you must use a support page where a developer doc exists, add a `# WHY:` comment explaining why the support page is the only available source

3. **Avoid**
   - Mirrors, archived copies, or third-party rewrites (use canonical source)
   - Forum posts, Reddit, Stack Overflow (document internal consensus via comments, not external link)
   - Expired links or pages under redirect chains

### URL standardization

**Apple support URLs must include explicit US English locale:**

- ✅ `https://support.apple.com/en-us/guide/mac-help/...`
- ✅ `https://support.apple.com/en-us/HT123456`
- ❌ `https://support.apple.com/guide/mac-help/...` (no locale prefix; redirects based on browser locale)
- ❌ `https://support.apple.com/HT123456` (no locale prefix)

**Preferred URL form:**

- Use canonical, stable URLs without query parameters (e.g., `?search=...`)
- Avoid short URLs or redirects if a canonical form exists
- Include article/page ID (HT numbers, doc IDs) when possible for long-term stability

### Topic and content verification

Before committing, verify:

1. **Article/page ID matches the claim**
   - Example: If documenting `.DS_Store` behavior, the cited Apple article must be about `.DS_Store`, not "Activation Lock" (HT102541 ≠ .DS_Store)
   - Browse the page or search the page text to confirm content matches your use case

2. **Developer vs. user scope**
   - Developer APIs should document behavior the way an SDK would
   - End-user settings/UI should match Apple's own UI documentation or end-user release notes
   - Mismatch? Add a comment explaining why the chosen source is most authoritative for your context

### Deprecation hygiene

When citing APIs or settings:

1. **Do not cite deprecated APIs as current behavior**
   - Carbon framework (macOS) → replace with modern equivalent (InputMethodKit, AppKit, SwiftUI)
   - CoreGraphics (legacy) → consider modern Cocoa APIs
   - When in doubt, check Apple's official deprecation notices

2. **If a deprecated API must be documented** (for historical context):
   - Mark it as deprecated in the comment
   - Cite the deprecation notice
   - Cite the modern replacement API in the same block
   - Example:
     ```nix
     # Old approach (deprecated): use Carbon Text Services Manager
     # Modern approach: use InputMethodKit
     # Source: https://developer.apple.com/documentation/inputmethodkit
     ```

### Citation style in code/config

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

### Reviewer checklist for PR review

When reviewing changes with external citations:

- [ ] All non-trivial behavior claims have nearby citations
- [ ] API/framework claims use `developer.<vendor>.com` when available
- [ ] Any `support.apple.com/en-us/` links include `/en-us/` (no locale-less URLs)
- [ ] Cited article/page actually covers the setting/claim being documented
- [ ] No deprecated APIs cited as current behavior (or marked+explained if unavoidable)
- [ ] If a user-help page is cited over developer docs, there's a WHY comment
- [ ] All links are canonical (no query params, no obvious redirect stubs)
- [ ] Citations stay adjacent to the claim they validate

### When in doubt

- Use `developer.<vendor>.com` over user-help pages
- Add a comment explaining the choice if non-obvious
- Verify the link actually covers your use case before commit
- Include the article ID or page number for long-term reference
