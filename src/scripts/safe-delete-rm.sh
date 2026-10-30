#!/bin/sh
# shellcheck shell=sh
# rm wrapper for non-interactive shells: delegates to safe-rm (kaelzhang)
# which moves files to the OS Trash instead of deleting permanently.
# check-suppress:embedded-content: trivial static wrapper under 10 lines
exec safe-rm "$@"
