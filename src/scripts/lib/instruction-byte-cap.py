from pathlib import Path
import sys

LIMIT = 100_000

def main() -> int:
    if len(sys.argv) != 2:
        print("usage: instruction-byte-cap.py <repo-root>")
        return 1
    root = Path(sys.argv[1])
    agents = root / "AGENTS.md"
    instruction_dir = root / ".agents" / "instructions"
    paths = [agents, *sorted(instruction_dir.glob("*.md"))]
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        print("instruction byte cap: missing files: " + ", ".join(missing))
        return 1
    total = sum(len(path.read_bytes()) for path in paths)
    if total > LIMIT:
        print(f"instruction byte cap: {total} bytes exceeds {LIMIT} bytes")
        return 1
    print(f"instruction byte cap: {total}/{LIMIT} bytes")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
