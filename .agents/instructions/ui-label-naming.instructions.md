---
description: "Use when adding UI labels, menu items, context menu entries, or visible text across all hosts. Mandates sentence case (only first word capitalized) for all user-facing UI labels, following Microsoft and macOS human interface guidelines."
name: "UI Label Naming Convention"
applyTo: "src/**"
---

All user-facing UI labels — right-click context menu entries, dock/folder/script labels, button text, and any other visible text — must use sentence case (capitalize only the first word and proper nouns).

This applies across all hosts: macOS `.app` bundles (`NSMenuItem`), NixOS file manager entries (Nautilus scripts, Dolphin `Name=`), and Windows Registry context menu entries (`valueData`).

Exception: system-internal identifiers like `CFBundleIdentifier`, filenames on disk that differ from display names, and AppleScript source code may use whatever case the platform requires.
