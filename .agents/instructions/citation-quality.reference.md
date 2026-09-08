---
description: "Reference: citation quality rules — source preference, URL standardization, deprecation hygiene, and citation style in code/config. Read on demand when citing external sources in code comments or documentation."
name: "Citation Quality Reference"
---

# Citation quality reference

Keep URLs and content correct to prevent drift when citing external sources.

## Source preference (priority order)

1. **Developer/API docs**: `developer.apple.com/documentation/*`, `learn.microsoft.com/en-us/*`, official references, IETF RFCs.
2. **User help** (only when developer docs absent): `support.apple.com/en-us/guide/*`, KB articles, vendor blogs. Support page where dev doc exists → add `# WHY:`.
3. **Avoid**: mirrors, archived copies, third-party rewrites, forums, Reddit, SO, expired/redirect links.

## URL standardization

Apple support URLs must include `en-us`:

- ✅ `https://support.apple.com/en-us/guide/mac-help/...`
- ❌ `https://support.apple.com/guide/mac-help/...` (redirects by locale)

Canonical URLs without query params. Include article IDs for stability.

## Deprecation hygiene

Never cite deprecated APIs as current. Deprecated in historical context → mark deprecated, cite notice, cite replacement:

```nix
# Old approach (deprecated): use Carbon Text Services Manager
# Modern approach: use InputMethodKit
# Source: https://developer.apple.com/documentation/inputmethodkit
```

## Citation style

Citations adjacent to the claim:

```nix
# Prevent .DS_Store files on network and removable volumes.
# Source: https://support.apple.com/en-us/HT208209
"com.apple.desktopservices" = {
  DSDontWriteNetworkStores = true;
};
```

Multi-line: source at top of comment block:

```nix
# Software Update: check, download, and install automatically.
# Source: https://support.apple.com/en-us/guide/deployment/manage-software-updates-depafd2fad80/web
"com.apple.SoftwareUpdate" = {
  AutomaticCheckEnabled = true;
  AutomaticDownload = true;
  CriticalUpdateInstall = true;
};
```
