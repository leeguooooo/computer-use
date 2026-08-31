import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"
BROKER = ROOT / "bin" / "codex-computer-use-mcp"


class InstallerTests(unittest.TestCase):
    def test_local_install_and_uninstall_are_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            env = os.environ.copy()
            env.update({
                "HOME": str(home),
                "COMPUTER_USE_MCP_SOURCE": str(BROKER),
                "PATH": os.environ["PATH"],
            })
            first = subprocess.run(
                [str(INSTALLER)],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            target = home / ".local/bin/codex-computer-use-mcp"
            self.assertTrue(target.is_file())
            self.assertTrue(os.access(target, os.X_OK))

            second = subprocess.run(
                [str(INSTALLER)],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(second.returncode, 0, second.stderr)
            config = json.loads((home / ".claude.json").read_text(encoding="utf-8"))
            self.assertEqual(config["mcpServers"]["codex-computer-use"]["command"],
                             str(target))

            removed = subprocess.run(
                [str(INSTALLER), "--uninstall"],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(removed.returncode, 0, removed.stderr)
            self.assertFalse(target.exists())
            config = json.loads((home / ".claude.json").read_text(encoding="utf-8"))
            self.assertNotIn("codex-computer-use", config.get("mcpServers", {}))


if __name__ == "__main__":
    unittest.main()
