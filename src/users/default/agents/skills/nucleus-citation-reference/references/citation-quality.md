---
description: "Reference: citation quality rules: source preference, URL standardization, deprecation hygiene, and citation style in code/config. Read on demand when citing external sources in code comments or documentation."
name: "Citation Quality Reference"
---

# Citation quality reference

## Source preference

1. Developer and API docs: `developer.apple.com/documentation/*`, `learn.microsoft.com/en-us/*`, official references, IETF RFCs.
2. User help only when no developer doc exists: `support.apple.com/en-us/guide/*`, KB articles, vendor blogs. When a dev doc does exist, cite it and add a `# WHY:` for the choice.
3. Never cite mirrors, archived copies, third-party rewrites, forums, Reddit, Stack Overflow, or expired and redirected links.

## URL standardization

Apple support URLs include `en-us`, so `https://support.apple.com/en-us/HT123456` and never `https://support.apple.com/HT123456`. Keep URLs canonical, without query params, and with the article id so the link stays resolvable.

## Deprecation hygiene

Never cite a deprecated API as current. In historical context, mark it deprecated and cite both the notice and the replacement:

```nix
# Old approach (deprecated): Carbon Text Services Manager.
# Modern approach: InputMethodKit.
# Source: https://developer.apple.com/documentation/inputmethodkit
```

## Citation style

The citation sits next to the claim it supports, or at the top of the comment block when the claim spans several lines:

```nix
# Prevent .DS_Store files on network and removable volumes.
# Source: https://support.apple.com/en-us/HT208209
"com.apple.desktopservices" = {
  DSDontWriteNetworkStores = true;
};
```
