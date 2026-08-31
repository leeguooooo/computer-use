#!/usr/bin/env python3
import json
import os
import sys


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        send({
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": "fake-codex", "version": "0"},
            },
        })
    elif method == "tools/list":
        send({
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "tools": [
                    {"name": "codex", "description": "Run Codex", "inputSchema": {}},
                    {"name": "codex-reply", "description": "Reply to Codex", "inputSchema": {}},
                ]
            },
        })
    elif method == "tools/call":
        arguments = message["params"]["arguments"]
        send({
            "jsonrpc": "2.0",
            "id": 900,
            "method": "elicitation/create",
            "params": {
                "mode": "form",
                "message": "Allow Computer Use to use Calculator?",
                "requestedSchema": {"type": "object", "properties": {}},
            },
        })
        response = json.loads(sys.stdin.readline())
        send({
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "content": [{
                    "type": "text",
                    "text": json.dumps({
                        "arguments": arguments,
                        "elicitation": response,
                    }),
                }]
            },
        })

marker = os.environ.get("FAKE_CODEX_EOF_MARKER")
if marker:
    with open(marker, "w", encoding="utf-8") as handle:
        handle.write("closed\n")
