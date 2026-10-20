import importlib.util
from pathlib import Path
import json
import shlex
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("hooks", Path(__file__).parents[1] / "scripts/configure_codex_hooks.py")
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)


class ConfigureTests(unittest.TestCase):
    def test_merge_reinstall_and_remove_preserve_existing_hooks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hooks.json"
            original = {"description": "existing", "hooks": {
                "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "original"}]}],
                "PreCompact": [{"hooks": [{"type": "command", "command": "compact"}]}],
                "PostCompact": [],
            }}
            path.write_text(json.dumps(original))
            binary = Path(directory) / "space ' quote $ dollar" / "codex-hook"
            hooks.configure(path, binary)
            updated = json.loads(path.read_text())
            self.assertEqual(updated["hooks"]["Stop"][0], original["hooks"]["Stop"][0])
            command = updated["hooks"]["Stop"][-1]["hooks"][0]["command"]
            self.assertEqual(shlex.split(command, comments=True), ["exec", str(binary), "--codex-hook"])
            hooks.configure(path, binary)
            self.assertEqual(updated, json.loads(path.read_text()))
            self.assertEqual(len(list(path.parent.glob("*.traffic-light-backup-*"))), 1)
            hooks.configure(path)
            self.assertEqual(original, json.loads(path.read_text()))

    def test_remove_missing_config_does_not_create_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hooks.json"
            hooks.configure(path)
            self.assertFalse(path.exists())

    def test_invalid_config_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hooks.json"
            path.write_text("broken")
            with self.assertRaises(json.JSONDecodeError):
                hooks.configure(path, Path("/example/codex-hook"))
            self.assertEqual(path.read_text(), "broken")


if __name__ == "__main__":
    unittest.main()
