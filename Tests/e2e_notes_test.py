#!/usr/bin/env python3
"""
E2E tests for macos-ecosystem-mcp server (MCP JSON-RPC über stdio).
Flags:
  --baseline   Nur CRUD-Tests ohne notes_update und Concurrency
"""
import json, subprocess, sys, threading
from pathlib import Path

BINARY = str(Path(__file__).parent.parent / ".build/release/macos-mcp")
OK = "\033[32m✓\033[0m"; FAIL = "\033[31m✗\033[0m"; SKIP = "\033[33m○\033[0m"
_results = []
_note_id = None   # wird in test_create gesetzt, in cleanup gelöscht


class MCPClient:
    def __init__(self, binary):
        self.proc = subprocess.Popen(
            [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        self._id = 0
        self._send({"jsonrpc":"2.0","id":self._nid(),"method":"initialize",
                    "params":{"protocolVersion":"2024-11-05","capabilities":{},
                              "clientInfo":{"name":"e2e","version":"1.0"}}})
        resp = self._recv(10)
        assert resp and "result" in resp, f"init failed: {resp}"
        self._send({"jsonrpc":"2.0","method":"notifications/initialized"})

    def _nid(self):
        self._id += 1; return self._id

    def _send(self, msg):
        self.proc.stdin.write((json.dumps(msg)+"\n").encode())
        self.proc.stdin.flush()

    def _recv(self, timeout=20):
        out = [None]
        def r():
            line = self.proc.stdout.readline()
            if line: out[0] = json.loads(line)
        t = threading.Thread(target=r, daemon=True); t.start(); t.join(timeout)
        return out[0]

    def call(self, name, args=None, timeout=20):
        self._send({"jsonrpc":"2.0","id":self._nid(),"method":"tools/call",
                    "params":{"name":name,"arguments":args or {}}})
        resp = self._recv(timeout)
        assert resp and "result" in resp, f"{name}: no response (timeout?)"
        r = resp["result"]
        return r["content"][0]["text"] if r.get("content") else "", r.get("isError", False)

    def list_tool_names(self):
        self._send({"jsonrpc":"2.0","id":self._nid(),"method":"tools/list"})
        resp = self._recv(10)
        return [t["name"] for t in resp["result"]["tools"]] if resp else []

    def close(self):
        try: self.proc.stdin.close(); self.proc.wait(timeout=5)
        except: pass


def run(label, fn):
    try:
        fn(); _results.append((OK, label)); print(f"  {OK} {label}")
    except Exception as e:
        _results.append((FAIL, label)); print(f"  {FAIL} {label}: {e}")


# ── Baseline CRUD ─────────────────────────────────────────────────────────────

def baseline_tests(c):
    global _note_id
    print("\n── Baseline: Notes CRUD ──")

    def t_list():
        text, err = c.call("notes_list", {"limit": 5})
        assert not err; assert "note" in text.lower()
    run("notes_list", t_list)

    def t_create():
        global _note_id
        text, err = c.call("notes_create",
                           {"title":"E2E Test Note","body":"Original body","folder":"Notes"})
        assert not err; assert "✓ Created" in text
        for line in text.splitlines():
            if "ID:" in line: _note_id = line.split("ID:",1)[1].strip(); break
        assert _note_id, f"no ID in: {text}"
    run("notes_create", t_create)

    def t_get():
        text, err = c.call("notes_get", {"noteId": _note_id})
        assert not err; assert "Original body" in text
    run("notes_get by noteId", t_get)

    def t_get_title():
        text, err = c.call("notes_get", {"title":"E2E Test Note","folder":"Notes"})
        assert not err; assert "E2E Test Note" in text
    run("notes_get by title+folder", t_get_title)

    def t_append():
        text, err = c.call("notes_append", {"noteId": _note_id, "content": "Appended"})
        assert not err; assert "✓ Appended" in text
        body, _ = c.call("notes_get", {"noteId": _note_id})
        assert "Original body" in body; assert "Appended" in body
    run("notes_append adds to body", t_append)

    def t_search():
        text, err = c.call("notes_search", {"query": "E2E Test Note"})
        assert not err; assert "E2E Test Note" in text
    run("notes_search finds note", t_search)

    def t_create_err():
        _, err = c.call("notes_create", {"body": "no title"})
        assert err
    run("notes_create requires title", t_create_err)

    def t_append_err():
        _, err = c.call("notes_append", {"content": "no target"})
        assert err
    run("notes_append requires noteId or title", t_append_err)


# ── notes_update ──────────────────────────────────────────────────────────────

def update_tests(c):
    print("\n── notes_update tests ──")

    def t_by_id():
        text, err = c.call("notes_update", {"noteId": _note_id, "body": "Replaced body"})
        assert not err; assert "✓ Updated" in text
        body, _ = c.call("notes_get", {"noteId": _note_id})
        assert "Replaced body" in body
        assert "Original body" not in body, "old body still present"
        assert "Appended" not in body, "appended content still present"
    run("notes_update replaces body (by noteId)", t_by_id)

    def t_by_title_folder():
        text, err = c.call("notes_update",
                           {"title":"E2E Test Note","folder":"Notes","body":"Via title+folder"})
        assert not err; assert "✓ Updated" in text
        body, _ = c.call("notes_get", {"noteId": _note_id})
        assert "Via title+folder" in body
    run("notes_update by title+folder", t_by_title_folder)

    def t_by_title():
        text, err = c.call("notes_update", {"title":"E2E Test Note","body":"Via title only"})
        assert not err; assert "✓ Updated" in text
    run("notes_update by title only", t_by_title)

    def t_no_body():
        _, err = c.call("notes_update", {"noteId": _note_id})
        assert err
    run("notes_update requires body", t_no_body)

    def t_no_target():
        _, err = c.call("notes_update", {"body": "no target"})
        assert err
    run("notes_update requires noteId or title", t_no_target)


# ── Timeout-Logging ───────────────────────────────────────────────────────────

def timeout_log_test(c):
    print("\n── Timeout/Logging test ──")
    import time, select
    c.call("notes_list", {"limit": 1})
    time.sleep(0.5)
    ready, _, _ = select.select([c.proc.stderr], [], [], 2.0)
    stderr_data = c.proc.stderr.read1(4096).decode(errors="replace") if ready else ""

    def t_ts():
        assert "[macos-mcp +" in stderr_data, \
            f"no timestamp in stderr (got: {stderr_data[:200]!r})"
    run("log() includes elapsed timestamp", t_ts)

    def t_osc():
        assert "osascript:" in stderr_data, \
            f"no osascript timing log in stderr (got: {stderr_data[:200]!r})"
    run("runAppleScript() logs timing", t_osc)


# ── Concurrency ───────────────────────────────────────────────────────────────

def concurrency_test(binary):
    print("\n── Concurrency test (zwei Clients) ──")
    c1 = MCPClient(binary)
    c2 = MCPClient(binary)
    results, errors = [None, None], [None, None]

    def call(idx, client):
        try: results[idx], _ = client.call("notes_list", {"limit": 5}, timeout=35)
        except Exception as e: errors[idx] = e

    t1 = threading.Thread(target=call, args=(0, c1))
    t2 = threading.Thread(target=call, args=(1, c2))
    t1.start(); t2.start(); t1.join(40); t2.join(40)
    c1.close(); c2.close()

    def t_both():
        assert errors[0] is None, f"client1: {errors[0]}"
        assert errors[1] is None, f"client2: {errors[1]}"
        assert results[0] is not None; assert results[1] is not None
    run("concurrent notes_list — beide erfolgreich", t_both)


# ── Cleanup ───────────────────────────────────────────────────────────────────

def cleanup(c):
    print("\n── Cleanup ──")
    if _note_id:
        text, err = c.call("notes_delete", {"noteId": _note_id})
        status = OK if not err else FAIL
        print(f"  {status} delete test note: {text[:60]}")


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    baseline_only = "--baseline" in sys.argv
    if not Path(BINARY).exists():
        print(f"Binary fehlt: {BINARY}\nBauen mit: swift build -c release")
        sys.exit(1)
    print(f"Binary: {BINARY}")
    c = MCPClient(BINARY)
    try:
        baseline_tests(c)
        if not baseline_only:
            tools = c.list_tool_names()
            if "notes_update" in tools:
                update_tests(c)
            else:
                print(f"\n  {SKIP} notes_update nicht verfügbar — übersprungen")
            timeout_log_test(c)
        cleanup(c)
    finally:
        c.close()
    if not baseline_only:
        concurrency_test(BINARY)

    passed = sum(1 for r,_ in _results if r == OK)
    failed  = sum(1 for r,_ in _results if r == FAIL)
    print(f"\n{'═'*45}")
    print(f"Ergebnis: {passed} bestanden, {failed} fehlgeschlagen")
    sys.exit(0 if failed == 0 else 1)
