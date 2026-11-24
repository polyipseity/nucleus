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

    def test_prompts_window_and_more_line(self):
        for i in range(12):
            self.write_queue(f"{100 + i}-p{i}.json", f"p{i}", 100 + i)
        with mock.patch.object(self.mod, "_nucleus_user_root", return_value=self.root):
            out = self.mod._handle_command("prompts")
        self.assertIn("10. queued · p2", out)
        self.assertNotIn("11. queued ·", out)
        self.assertIn("(+2 more)", out)
        self.assertIn("Sent history unavailable", out)

    def test_prompts_filter_ranks_fuzzy_and_selects_full_list(self):
        self.write_queue("100-a.json", "run git reset", 100)
        self.write_queue("200-b.json", "gamma prompt", 200)
        self.write_queue("300-c.json", "queued gpt text", 300)
        with mock.patch.object(self.mod, "_nucleus_user_root", return_value=self.root):
            out = self.mod._handle_command("prompts filter gpt")
        self.assertIn("1. queued · queued gpt text", out)
        self.assertNotIn("run git reset", out)

    def test_shared_fuzzy_fixture_cases(self):
        fixture_path = Path(__file__).resolve().parents[6] / "tests" / "fixtures" / "prompt-picker-fuzzy.json"
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        for case in fixture["cases"]:
            prompts = [{"text": item} for item in case["items"]]
            ranked = self.mod.filter_prompt_choices(prompts, case["query"])
            self.assertEqual([item["text"] for item in ranked], case["expected"])


if __name__ == "__main__":
    unittest.main()
