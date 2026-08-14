#!/usr/bin/env bash
# Logging-format policy fixture: shell file with every prohibited construct.
# The escapes below are written with a doubled backslash so this fixture
# itself does not emit real ANSI at runtime.
printf '%s\n' '\033[31mred\033[0m'
printf '%s\n' '\e[32mgreen\e[0m'
printf '%s\n' '\x1b[33myellow\x1b[0m'
tput setaf 1
echo -e 'echo dash-e is banned'
