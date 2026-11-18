import importlib.util
import json
import os
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


def load_module():
    path = Path(__file__).with_name("__init__.py")
    spec = importlib.util.spec_from_file_location("harness_bridge_prompts", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


class HarnessBridgePromptsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "nucleus"
        self.commands = self.root / "state" / "harness-bridge" / "commands" / "hermes"
        self.commands.mkdir(parents=True)
        self.mod = load_module()

    def tearDown(self):
        self.tmp.cleanup()

    def write_queue(self, name, text, created_at):
        (self.commands / name).write_text(
            json.dumps({"id": name, "harness": "hermes", "text": text, "created_at": created_at}),
            encoding="utf-8",
        )

    def test_prompts_lists_queued_reverse_chronological(self):
        self.write_queue("100-a.json", "older", 100)
        self.write_queue("200-b.json", "newer", 200)
        with mock.patch.object(self.mod, "_nucleus_user_root", return_value=self.root):
            out = self.mod._handle_command("prompts")
        self.assertIn("1.", out)
        self.assertIn("2.", out)
        self.assertLess(out.index("newer"), out.index("older"))
        self.assertIn("Sent history unavailable", out)

    def test_prompts_index_copies_selected_prompt(self):
        self.write_queue("100-a.json", "older", 100)
        self.write_queue("200-b.json", "newer", 200)
        capture = Path(self.tmp.name) / "captured.txt"
        stub = Path(self.tmp.name) / "harness-clipboard"
        stub.write_text(f"#!/bin/sh\ncat > '{capture}'\n", encoding="utf-8")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        env = {**os.environ, "NUCLEUS_HARNESS_CLIPBOARD": str(stub)}
        with mock.patch.object(self.mod, "_nucleus_user_root", return_value=self.root), mock.patch.dict(
            os.environ, env, clear=False
        ):
            out = self.mod._handle_command("prompts 1")
        self.assertIn("Copied", out)
        self.assertEqual(capture.read_text(encoding="utf-8"), "newer")
        self.assertTrue((self.commands / "200-b.json").exists())

    def test_prompts_out_of_range_reports_range(self):
        self.write_queue("100-a.json", "only", 100)
        with mock.patch.object(self.mod, "_nucleus_user_root", return_value=self.root):
            out = self.mod._handle_command("prompts 9")
        self.assertIn("1 to 1", out)
        self.assertNotIn("Copied", out)


if __name__ == "__main__":
    unittest.main()
