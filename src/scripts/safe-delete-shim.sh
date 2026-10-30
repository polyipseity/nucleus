#!/bin/sh
# shellcheck shell=sh
# Generic deletion shim for non-interactive shells: delegates to safe-rm
# (kaelzhang) which moves files to the OS Trash instead of deleting.
# check-suppress:embedded-content: trivial static wrapper under 10 lines
exec safe-rm "$@"
