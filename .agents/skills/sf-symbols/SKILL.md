---
description: "Use when looking up or verifying SF Symbol names for macOS Automator workflow icons. Covers the hard lookup rule, authoritative sources, and how to grep the bundled symbol list."
name: "sf-symbols"
---

# SF Symbol names for Automator workflow icons

## Hard rule: always look up from an authoritative source — never rely on third-party lists alone

Every SF Symbol name used in `NSIconName` (Info.plist) or `systemImageName` (document.wflow) must be verified against the macOS private framework — not just community-maintained lists. Third-party lists (e.g. `sam4096/apple-sf-symbols-list`) are often incomplete and can falsely label valid symbols as missing. The authoritative source is the macOS SFSymbols framework that ships with every macOS.

## Authoritative sources

| Source | Location | Best for |
|--------|----------|----------|
| **SF Symbols app** | Free download from Apple Developer | Visual browsing, search, copy name |
| **macOS private framework** | `/System/Library/PrivateFrameworks/SFSymbols.framework/` | Authoritative; source for the local list |
| **Local extracted list** | `symbols.txt` (extracted from macOS framework, in this skill directory) | Quick `grep`-based lookup |

The HIG page on developer.apple.com is a design guide, not a catalog — it does not list symbol names. There is no web-based catalog.

`symbols.txt` is extracted from the `CoreGlyphs` and `CoreGlyphsPrivate` bundles inside the macOS SFSymbols framework. It is not downloaded from a third-party source.

## How to look up a symbol name

### Quickest: grep the local list

```bash
grep -i 'keyword' .agents/skills/sf-symbols/symbols.txt
```

### Visual: SF Symbols app

1. Download and open the SF Symbols app from Apple Developer.
2. Search or browse categories.
3. Select a symbol — its name appears at the bottom.
4. Right-click → "Copy Name".

### Regenerate the local list from framework (when macOS updates SF Symbols)

```bash
plutil -p /System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphs.bundle/Contents/Resources/name_availability.plist | grep '=>' | sed 's/^[[:space:]]*"//;s/"[[:space:]]*=>.*//' > symbols_raw_a.txt
plutil -p /System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphsPrivate.bundle/Contents/Resources/name_availability.plist | python3 -c "
import sys, re
data = sys.stdin.read()
for m in re.finditer(r'\"([a-zA-Z0-9._]+)\"', data.split('{',1)[1] if '{' in data else data):
    name = m.group(1)
    if not name.startswith('_') and not (len(name) == 32 and re.match(r'^[0-9A-F]+$', name)):
        print(name)
" > symbols_raw_b.txt
cat symbols_raw_a.txt symbols_raw_b.txt | sort -u > symbols.txt
rm symbols_raw_a.txt symbols_raw_b.txt
```

## Policy reference

The icon convention policy for this project's Automator workflows is documented
in `src/hosts/MacBook/services/automator-workflows.nix` (header comment section
"SF Symbol icon policy").

## macOS version floor

Symbols from SF Symbols 3 require macOS 12 Monterey+. Always check the SF Symbols version in which a symbol was introduced and verify against the host's minimum macOS version.
