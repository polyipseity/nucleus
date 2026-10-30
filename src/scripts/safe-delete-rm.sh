#!/bin/sh
# shellcheck shell=sh
# PATH binary defense for rm. Delegates to safe-rm (OS Trash).
set -eu

exec safe-rm "$@"
