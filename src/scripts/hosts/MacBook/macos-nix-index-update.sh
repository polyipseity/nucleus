# nix-index database rebuild.  Uses freshness check to skip rebuild when the
# DB was updated within the past 6 days.
set -eu

db_file="$HOME/.cache/nix-index/files"

# Skip rebuild when the DB file exists and was modified within the last
# 6 days.  find -mtime +6 matches files with modification time strictly
# greater than 6x24 h ago; empty output means the file is still fresh.
if [ -f "$db_file" ] && [ -z "$(find "$db_file" -mtime +6)" ]; then
  exit 0
fi

exec __NIX_INDEX_BIN__
