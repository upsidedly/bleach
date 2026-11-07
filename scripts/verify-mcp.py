#!/usr/bin/env python3
"""Exercise the packaged MCP stdio protocol against disposable homes only."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import selectors
import subprocess
import tempfile


class Client:
    def __init__(self, binary, root, flags=()):
        self.process = subprocess.Popen([str(binary), "mcp", "--root", str(root), *flags], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.serial = 0
        self.buffer = b""
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        result = self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "bleach-fixture-verifier", "version": "1"}})
        assert result["serverInfo"]["name"] == "Bleach"
        assert "tools" in result["capabilities"]
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, params=None):
        self.serial += 1
        self.send({"jsonrpc": "2.0", "id": self.serial, "method": method, "params": params or {}})
        while True:
            while b"\n" not in self.buffer:
                assert self.selector.select(20), f"MCP timeout: {method}"
                chunk = os.read(self.process.stdout.fileno(), 65536)
                assert chunk, f"MCP exited during {method}: {self.process.stderr.read(4096)!r}"
                self.buffer += chunk
                assert len(self.buffer) <= 16_000_000
            line, self.buffer = self.buffer.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") == self.serial:
                assert "error" not in response, response
                return response["result"]

    def tool(self, name, arguments=None, error=False):
        result = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        assert bool(result.get("isError")) == error, result
        if error:
            return result
        text = "".join(x.get("text", "") for x in result["content"] if x["type"] == "text")
        assert json.loads(text) == result["structuredContent"]
        return result["structuredContent"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
            raise AssertionError("MCP failed to shut down on stdin EOF")
        assert self.process.returncode == 0, self.process.stderr.read(4096)
        self.selector.close()

    def cache_preview(self, scan, path):
        candidate = next((item for item in scan["candidates"] if item["path"] == str(path)), None)
        assert candidate is not None and candidate["recommendation"] != "blocked", {"candidate": candidate, "issues": scan.get("issues", [])}
        return self.tool("bleach_preview", {"plan_id": scan["planID"], "paths": [str(path)]})


def write(root, relative, data=b"fixture payload\n" * 4096):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def verify(binary):
    with tempfile.TemporaryDirectory(prefix="bleach-mcp-fixture-") as temporary:
        root = Path(temporary).resolve()
        keep = write(root, ".codex/sessions/keep.jsonl")
        original = write(root, "Library/Caches/org.bleach.fixture.MCP/cache.bin")
        digest = original.read_bytes()
        app = root / "Applications/Fixture.app"
        write(root, "Applications/Fixture.app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "org.bleach.fixture.MCPApp", "CFBundleName": "Fixture", "CFBundleShortVersionString": "1"}))
        write(root, "Applications/Fixture.app/Contents/MacOS/Fixture", b"fixture executable")
        client = Client(binary, root)
        tools = client.request("tools/list")["tools"]
        assert len(tools) == 13
        assert all(t["annotations"]["readOnlyHint"] for t in tools)
        assert all(t["inputSchema"]["additionalProperties"] is False for t in tools)
        assert client.request("ping") == {}
        assert client.request("resources/list")["resources"][0]["uri"] == "bleach://safety"
        assert "Recovery" in client.request("resources/read", {"uri": "bleach://safety"})["contents"][0]["text"]
        assert client.request("prompts/list")["prompts"][0]["name"] == "review-cleanup"
        assert client.request("prompts/get", {"name": "review-cleanup"})["messages"]
        status = client.tool("bleach_status")
        assert status["mutationsEnabled"] is False and status["permanentDeleteEnabled"] is False
        assert status["system"]["diskTotal"] > 0
        client.tool("bleach_preferences")
        apps = client.tool("bleach_apps")["applications"]
        assert any(a["path"] == str(app) for a in apps)
        client.tool("bleach_uninstall_preview", {"path": str(app)})
        client.tool("bleach_uninstall_preview", {"path": str(root / "not-installed.app")}, error=True)
        client.tool("bleach_processes")
        client.tool("bleach_discover", {"path": str(root)})
        client.tool("bleach_inactive", {"path": str(root)})
        scan = client.tool("bleach_scan")
        assert any(c["path"] == str(original.parent) for c in scan["candidates"])
        page = client.tool("bleach_plan", {"plan_id": scan["planID"], "limit": 1})
        assert len(page["candidates"]) == 1
        client.tool("bleach_analyze", {"path": str(root), "limit": 2})
        client.tool("bleach_analyze", {"path": "/"}, error=True)
        (root / "escape").symlink_to("/Users")
        client.tool("bleach_analyze", {"path": "escape"}, error=True)
        client.tool("bleach_plan", {"plan_id": scan["planID"], "limit": -1}, error=True)
        client.tool("bleach_apply", {}, error=True)
        client.tool("bleach_scan", {"unexpected": True}, error=True)
        preview = client.cache_preview(scan, original.parent)
        assert preview["previewToken"]
        assert original.read_bytes() == digest and keep.exists()
        client.close()
        assert not (root / "Library/Application Support/Bleach").exists(), "Read-only tools created state"

        client = Client(binary, root, ["--allow-mutations", "--allow-permanent-delete"])
        tools = {t["name"]: t for t in client.request("tools/list")["tools"]}
        assert len(tools) == 16 and tools["bleach_delete_permanently"]["annotations"]["destructiveHint"]
        scan = client.tool("bleach_scan")
        preview = client.cache_preview(scan, original.parent)
        args = {"preview_token": preview["previewToken"], "confirmation": "WRONG"}
        client.tool("bleach_apply", args, error=True)
        args["confirmation"] = "MOVE TO RECOVERY"
        moved = client.tool("bleach_apply", args)
        assert not original.exists() and moved["items"][0]["state"] == "moved"
        client.tool("bleach_apply", args, error=True)
        restored = client.tool("bleach_restore", {"batch_id": moved["id"], "confirmation": "RESTORE"})
        assert restored["items"][0]["state"] == "restored" and original.read_bytes() == digest

        scan = client.tool("bleach_scan")
        preview = client.cache_preview(scan, original.parent)
        write(root, "Library/Caches/org.bleach.fixture.MCP/changed.bin", b"keep changed file")
        client.tool("bleach_delete_permanently", {"preview_token": preview["previewToken"], "confirmation": "DELETE PERMANENTLY"}, error=True)
        assert original.exists()
        scan = client.tool("bleach_scan")
        preview = client.cache_preview(scan, original.parent)
        erased = client.tool("bleach_delete_permanently", {"preview_token": preview["previewToken"], "confirmation": "DELETE PERMANENTLY"})
        assert erased["items"][0]["state"] == "erased" and not original.exists() and keep.exists()
        assert client.tool("bleach_recovery")["batches"]
        client.close()
    print("PASS: MCP handshake,13/16tool permissions,resources,prompt,pagination,root/symlink bounds,exact preview,confirmation,move/restore,stale-file rejection,permanent deletion,protected history and EOF shutdown")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    verify(parser.parse_args().binary.resolve())
