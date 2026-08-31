import importlib.machinery
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BROKER = ROOT / "bin" / "codex-computer-use-mcp"
FAKE_CODEX = ROOT / "tests" / "fake_codex.py"


def load_broker():
    loader = importlib.machinery.SourceFileLoader("codex_computer_use_mcp", str(BROKER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class BrokerUnitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.broker = load_broker()

    def make_plugin_root(self, root):
        skill = root / "skills" / "computer-use" / "SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("---\nname: computer-use\n---\n", encoding="utf-8")
        return root

    def test_discovers_highest_numeric_plugin_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            base = home / ".codex/plugins/cache/openai-bundled/computer-use"
            self.make_plugin_root(base / "1.0.9")
            expected = self.make_plugin_root(base / "1.0.100")
            actual = self.broker.discover_plugin_root(home=home, env={})
            self.assertEqual(actual, expected)

    def test_legacy_wrapper_layout_still_discovered(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "override"
            wrapper = root / "scripts" / "computer-use-client.mjs"
            wrapper.parent.mkdir(parents=True)
            wrapper.write_text("export function setupComputerUseRuntime() {}\n",
                               encoding="utf-8")
            actual = self.broker.discover_plugin_root(
                home=Path(tmp) / "home",
                env={"CODEX_COMPUTER_USE_PLUGIN_ROOT": str(root)},
            )
            self.assertEqual(actual, root)

    def test_environment_override_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_plugin_root(Path(tmp) / "override")
            actual = self.broker.discover_plugin_root(
                home=Path(tmp) / "home",
                env={"CODEX_COMPUTER_USE_PLUGIN_ROOT": str(root)},
            )
            self.assertEqual(actual, root)

    def test_codex_injection_preserves_existing_instructions(self):
        original = {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {
                "name": "codex",
                "arguments": {
                    "prompt": "Use Calculator",
                    "developer-instructions": "Keep the user's files unchanged.",
                },
            },
        }
        result = self.broker.inject_client_message(original)
        instructions = result["params"]["arguments"]["developer-instructions"]
        self.assertIn("Keep the user's files unchanged.", instructions)
        self.assertIn('await import("@oai/sky")', instructions)
        self.assertIn("globalThis.sky", instructions)
        self.assertIn("unconditionally", instructions.lower())
        self.assertEqual(original["params"]["arguments"]["developer-instructions"],
                         "Keep the user's files unchanged.")

    def test_codex_reply_gets_recovery_reminder(self):
        original = {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {
                "name": "codex-reply",
                "arguments": {"threadId": "thread", "prompt": "Continue"},
            },
        }
        result = self.broker.inject_client_message(original)
        prompt = result["params"]["arguments"]["prompt"]
        self.assertIn('await import("@oai/sky")', prompt)
        self.assertTrue(prompt.endswith("Continue"))

    def test_unrelated_message_is_unchanged(self):
        original = {"jsonrpc": "2.0", "id": 8, "method": "resources/list", "params": {}}
        self.assertEqual(self.broker.inject_client_message(original), original)

    def test_sky_clients_under_only_matches_our_subtree(self):
        marker = self.broker.SKY_CLIENT_MARKER
        # our broker(100) -> codex mcp-server(200) -> codex worker(300) -> sky(400)
        # an unrelated Codex session(500 -> 600 -> sky 700) must be left alone.
        # a Sky *Service*(800) shares the "SkyComputerUse" prefix but is not a client.
        snapshot = {
            100: (1, "codex-computer-use-mcp"),
            200: (100, "codex mcp-server"),
            300: (200, "codex worker"),
            400: (300, f"/x/{marker} mcp"),
            500: (1, "codex mcp-server"),
            600: (500, "codex worker"),
            700: (600, f"/x/{marker} mcp"),
            800: (1, "/x/SkyComputerUseService.app/Contents/MacOS/SkyComputerUseService"),
        }
        self.assertTrue(self.broker._is_descendant_of(400, 200, snapshot))
        self.assertFalse(self.broker._is_descendant_of(700, 200, snapshot))
        self.assertEqual(self.broker._sky_clients_under(200, snapshot), {400})

    def test_is_descendant_handles_cycles_and_roots(self):
        snapshot = {10: (20, "a"), 20: (10, "b")}  # cycle
        self.assertFalse(self.broker._is_descendant_of(10, 999, snapshot))
        # reaches root (ppid 1) without hitting ancestor 999 -> not a descendant
        self.assertFalse(self.broker._is_descendant_of(42, 999, {42: (1, "orphan")}))

    def test_reap_terminates_only_attributed_sky_clients(self):
        import subprocess as sp
        marker = "/x/" + self.broker.SKY_CLIENT_MARKER
        proc = sp.Popen(["python3", "-c", "import time;time.sleep(60)", marker])
        try:
            time.sleep(0.5)
            snapshot = self.broker._process_snapshot()
            self.assertIn(proc.pid,
                          self.broker._sky_clients_under(os.getpid(), snapshot))
            self.assertNotIn(proc.pid,
                             self.broker._sky_clients_under(999999, snapshot))
            self.broker._reap_sky_clients({proc.pid})
            rc = proc.wait(timeout=5)  # reaps the zombie; signal exit is negative
            self.assertIsNotNone(rc)
            self.assertLess(rc, 0)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()

    def test_tools_list_describes_computer_use(self):
        message = {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {"tools": [
                {"name": "codex", "description": "Run Codex"},
                {"name": "codex-reply", "description": "Reply"},
            ]},
        }
        result = self.broker.rewrite_tools_list_response(message, {2})
        self.assertIn("Computer Use", result["result"]["tools"][0]["description"])
        self.assertIn("Computer Use", result["result"]["tools"][1]["description"])

    def test_config_merge_is_idempotent_and_preserves_other_servers(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            claude = home / ".claude.json"
            cursor = home / ".cursor/mcp.json"
            settings = home / "Library/Application Support/Cursor/User/settings.json"
            claude.write_text(json.dumps({"mcpServers": {"other": {"command": "other"}}}),
                              encoding="utf-8")
            cursor.parent.mkdir(parents=True)
            cursor.write_text(json.dumps({"mcpServers": {"other": {"command": "other"}}}),
                             encoding="utf-8")
            settings.parent.mkdir(parents=True)
            settings.write_text(json.dumps({"theme": "dark", "mcp": {"servers": {
                "other": {"command": "other"}
            }}}), encoding="utf-8")

            command = "/tmp/bin/codex-computer-use-mcp"
            changed = self.broker.configure_clients(command, home=home)
            first_contents = [path.read_text(encoding="utf-8")
                              for path in (claude, cursor, settings)]
            changed_again = self.broker.configure_clients(command, home=home)
            second_contents = [path.read_text(encoding="utf-8")
                               for path in (claude, cursor, settings)]

            self.assertEqual(changed, 3)
            self.assertEqual(changed_again, 0)
            self.assertEqual(first_contents, second_contents)
            for path in (claude, cursor):
                data = json.loads(path.read_text(encoding="utf-8"))
                self.assertEqual(data["mcpServers"]["other"]["command"], "other")
                self.assertEqual(data["mcpServers"]["codex-computer-use"]["command"], command)
            gui = json.loads(settings.read_text(encoding="utf-8"))
            self.assertEqual(gui["theme"], "dark")
            self.assertEqual(gui["mcp"]["servers"]["other"]["command"], "other")
            self.assertEqual(gui["mcp"]["servers"]["codex-computer-use"]["command"], command)

    def test_unconfigure_removes_only_matching_managed_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            claude = home / ".claude.json"
            claude.write_text(json.dumps({"mcpServers": {
                "codex-computer-use": {"command": "/custom/broker"},
                "other": {"command": "other"},
            }}), encoding="utf-8")
            self.broker.unconfigure_clients("/installed/broker", home=home)
            data = json.loads(claude.read_text(encoding="utf-8"))
            self.assertEqual(data["mcpServers"]["codex-computer-use"]["command"],
                             "/custom/broker")


class BrokerProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        skill = self.home / "plugin/skills/computer-use/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("---\nname: computer-use\n---\n", encoding="utf-8")
        self.marker = self.home / "child-closed"
        env = os.environ.copy()
        env.update({
            "CODEX_COMPUTER_USE_PLUGIN_ROOT": str(skill.parents[2]),
            "CODEX_COMPUTER_USE_CODEX": str(FAKE_CODEX),
            "FAKE_CODEX_EOF_MARKER": str(self.marker),
        })
        self.process = subprocess.Popen(
            [str(BROKER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )

    def tearDown(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        self.temp.cleanup()

    def send(self, message):
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def _drain_stderr(self):
        fd = self.process.stderr.fileno()
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        try:
            return self.process.stderr.read() or "(no stderr output)"
        except (BlockingIOError, OSError):
            return "(no stderr output)"

    def receive(self, timeout=5):
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        # Read stderr only on failure, and non-blocking: `stderr.read()` on a
        # live child blocks until it exits, so evaluating it eagerly as the
        # assert message would deadlock every receive().
        if not ready:
            self.fail(self._drain_stderr())
        return json.loads(self.process.stdout.readline())

    def test_elicitation_round_trip_and_injection(self):
        self.send({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {"elicitation": {"form": {}}},
                "clientInfo": {"name": "test", "version": "0"},
            },
        })
        self.assertEqual(self.receive()["id"], 1)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        self.send({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "codex", "arguments": {"prompt": "Calculate"}},
        })
        elicitation = self.receive()
        self.assertEqual(elicitation["method"], "elicitation/create")
        self.send({
            "jsonrpc": "2.0", "id": elicitation["id"],
            "result": {"action": "accept", "content": {}},
        })
        result = self.receive()
        echoed = json.loads(result["result"]["content"][0]["text"])
        self.assertIn('await import("@oai/sky")',
                      echoed["arguments"]["developer-instructions"])
        self.assertEqual(echoed["elicitation"]["result"]["action"], "accept")

    def test_child_is_reaped_after_client_eof(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)
        deadline = time.time() + 2
        while not self.marker.exists() and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(self.marker.exists())
        self.assertEqual(self.process.returncode, 0)


if __name__ == "__main__":
    unittest.main()
