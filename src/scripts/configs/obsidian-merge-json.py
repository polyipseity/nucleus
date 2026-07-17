import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
managed = json.loads(sys.argv[2])

if config_path.exists():
    raw = config_path.read_text(encoding="utf-8")
    existing = json.loads(raw) if raw.strip() else {}
else:
    existing = {}

if not isinstance(existing, dict):
    print(f"obsidian: expected top-level JSON object in {config_path}", file=sys.stderr)
    sys.exit(1)

existing.update(managed)
config_path.write_text(json.dumps(existing, separators=(",", ":")), encoding="utf-8")
