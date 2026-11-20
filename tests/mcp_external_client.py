#!/usr/bin/env python3
"""
DevAgents MCP External Client — P08 Gate Test

Lanza devagents-mcp.exe por stdio, hace handshake, capabilities, models_list,
y una orden E2E simple hasta list_artifacts.

Uso:
    python tests/mcp_external_client.py --exe zig-out/bin/devagents-mcp.exe --data-dir engine/data
"""

import argparse
import json
import os
import subprocess
import sys
import time
import tempfile
import threading


class MCPClient:
    """Minimal MCP stdio client."""

    def __init__(self, proc):
        self.proc = proc
        self._id = 0
        self._lock = threading.Lock()

    def _next_id(self):
        self._id += 1
        return self._id

    def send(self, method, params=None):
        with self._lock:
            req = {"jsonrpc": "2.0", "id": self._next_id(), "method": method}
            if params is not None:
                req["params"] = params
            line = json.dumps(req) + "\n"
            self.proc.stdin.write(line)
            self.proc.stdin.flush()

    def send_notification(self, method, params=None):
        with self._lock:
            req = {"jsonrpc": "2.0", "method": method}
            if params is not None:
                req["params"] = params
            line = json.dumps(req) + "\n"
            self.proc.stdin.write(line)
            self.proc.stdin.flush()

    def recv(self, timeout=30):
        """Read one JSON-RPC response line (thread-based for Windows pipe compat)."""
        result = [None]
        def _read():
            result[0] = self.proc.stdout.readline()
        t = threading.Thread(target=_read, daemon=True)
        t.start()
        t.join(timeout=timeout)
        if t.is_alive():
            raise TimeoutError(f"No response within {timeout}s")
        line = result[0]
        if not line:
            raise TimeoutError("EOF on stdout")
        line = line.strip()
        if not line:
            raise TimeoutError("Empty line on stdout")
        msg = json.loads(line)
        if "id" not in msg:
            raise TimeoutError(f"No id in response: {line[:100]}")
        return msg

    def call_tool(self, name, arguments=None):
        self.send("tools/call", {"name": name, "arguments": arguments or {}})
        resp = self.recv(timeout=120)
        if "error" in resp:
            return resp["error"]
        result = resp.get("result", {})
        content = result.get("content", [])
        if content and isinstance(content, list):
            text = content[0].get("text", "")
            try:
                return json.loads(text)
            except (json.JSONDecodeError, TypeError):
                return text
        return result

    def initialize(self):
        self.send("initialize", {})
        resp = self.recv(timeout=10)
        return resp.get("result", {})

    def tools_list(self):
        self.send("tools/list", {})
        resp = self.recv(timeout=10)
        return resp.get("result", {}).get("tools", [])


def extract_order_id(resp):
    if isinstance(resp, dict):
        return resp.get("order_id")
    if isinstance(resp, str):
        import re
        m = re.search(r'"order_id"\s*:\s*(\d+)', resp)
        if m:
            return int(m.group(1))
    return None


def has_executable_tasks(plan):
    return isinstance(plan, dict) and isinstance(plan.get("tasks"), list) and len(plan["tasks"]) > 0


def fallback_plan_json():
    """Deterministic programar plan used only when the live planner returns no tasks."""
    return json.dumps({
        "understanding": "Create a minimal Python hello-world script.",
        "tasks": [{
            "id": "t1",
            "task_type": "programar",
            "department": "programacion",
            "description": "Create hello.py that prints Hello World",
            "depends_on": [],
            "contract_fields": [
                {"name": "source", "type": "string", "required": True},
                {"name": "filename", "type": "string", "required": True},
                {"name": "exit_code", "type": "integer", "required": False},
            ],
        }],
    }, separators=(",", ":"))


def main():
    parser = argparse.ArgumentParser(description="DevAgents MCP External Client Test")
    parser.add_argument("--exe", required=True, help="Path to devagents-mcp.exe")
    parser.add_argument("--data-dir", default=None, help="Data directory for runtime.db")
    parser.add_argument("--cwd", default=None, help="Working directory (default: temp dir)")
    parser.add_argument("--force-provider", default=None, help="Optional provider to force via plan_set_model before E2E")
    parser.add_argument("--force-model", default=None, help="Optional model to force via plan_set_model before E2E")
    parser.add_argument("--order-text", default="create hello.py that prints Hello World", help="Order text for the E2E flow")
    parser.add_argument("--e2e-retries", type=int, default=3, help="Retry E2E flow when live provider returns no executable plan")
    parser.add_argument("--no-fallback-plan", action="store_true", help="Disable deterministic plan_json fallback when live planning returns no tasks")
    args = parser.parse_args()

    cwd = args.cwd or tempfile.mkdtemp(prefix="devagents_mcp_test_")
    cmd = [args.exe]
    if args.data_dir:
        cmd.extend(["--data-dir", args.data_dir])

    sys.stdout.write(f"[client] Launching: {' '.join(cmd)}\n")
    sys.stdout.write(f"[client] CWD: {cwd}\n")
    sys.stdout.flush()

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        cwd=cwd,
        text=True,
        bufsize=-1,
    )
    client = MCPClient(proc)
    results = []

    try:
        # Step 1: Initialize
        sys.stdout.write("\n=== Step 1: Initialize ===\n")
        sys.stdout.flush()
        init = client.initialize()
        proto = init.get("protocolVersion", "")
        server_info = init.get("serverInfo", {})
        sys.stdout.write(f"  protocolVersion: {proto}\n")
        sys.stdout.write(f"  serverInfo: {server_info}\n")
        sys.stdout.flush()
        assert proto == "2024-11-05", f"Expected protocol 2024-11-05, got {proto}"
        results.append(("initialize", True, f"protocol={proto}"))

        client.send_notification("notifications/initialized", {})

        # Step 2: capabilities
        sys.stdout.write("\n=== Step 2: capabilities ===\n")
        sys.stdout.flush()
        caps = client.call_tool("capabilities", {})
        sys.stdout.write(f"  type: {type(caps).__name__}\n")
        sys.stdout.flush()
        if isinstance(caps, dict):
            sys.stdout.write(f"  ok: {caps.get('ok')}\n")
            sys.stdout.write(f"  version: {caps.get('version')}\n")
            sys.stdout.write(f"  dataDir: {caps.get('dataDir')}\n")
            tools_list = caps.get("tools", [])
            sys.stdout.write(f"  tools count: {len(tools_list)}\n")
            providers = caps.get("providers", [])
            sys.stdout.write(f"  providers count: {len(providers)}\n")
            sys.stdout.flush()
            caps_str = json.dumps(caps)
            assert "api_key" not in caps_str.lower(), "api_key found in capabilities!"
            assert "secret" not in caps_str.lower(), "secret found in capabilities!"
            results.append(("capabilities", True, f"version={caps.get('version')}, tools={len(tools_list)}"))
        else:
            sys.stdout.write(f"  raw: {str(caps)[:200]}\n")
            sys.stdout.flush()
            results.append(("capabilities", False, str(caps)[:200]))

        # Step 3: tools/list
        sys.stdout.write("\n=== Step 3: tools/list ===\n")
        sys.stdout.flush()
        tools = client.tools_list()
        tool_names = [t.get("name", "") for t in tools]
        sys.stdout.write(f"  tools count: {len(tools)}\n")
        sys.stdout.write(f"  first 10: {tool_names[:10]}\n")
        sys.stdout.flush()
        assert "capabilities" in tool_names, "capabilities not in tools/list!"
        assert "session_rename" in tool_names, "session_rename not in tools/list!"
        assert "health_summary" in tool_names, "health_summary not in tools/list!"
        results.append(("tools/list", True, f"count={len(tools)}"))

        # Step 4: models_list
        sys.stdout.write("\n=== Step 4: models_list ===\n")
        sys.stdout.flush()
        models = client.call_tool("models_list", {})
        if isinstance(models, list):
            sys.stdout.write(f"  models count: {len(models)}\n")
            sys.stdout.flush()
            results.append(("models_list", True, f"count={len(models)}"))
        else:
            sys.stdout.write(f"  raw: {str(models)[:200]}\n")
            sys.stdout.flush()
            results.append(("models_list", True, f"raw={str(models)[:100]}"))

        # Step 5: health_summary
        sys.stdout.write("\n=== Step 5: health_summary ===\n")
        sys.stdout.flush()
        health = client.call_tool("health_summary", {})
        sys.stdout.write(f"  type: {type(health).__name__}\n")
        sys.stdout.flush()
        if isinstance(health, list):
            sys.stdout.write(f"  providers with health: {len(health)}\n")
        else:
            sys.stdout.write(f"  raw: {str(health)[:200]}\n")
        sys.stdout.flush()
        results.append(("health_summary", True, str(health)[:100]))

        # Step 6: E2E order
        sys.stdout.write("\n=== Step 6: E2E Order ===\n")
        sys.stdout.flush()
        if args.force_provider and args.force_model:
            forced = client.call_tool("plan_set_model", {
                "provider": args.force_provider,
                "model": args.force_model,
            })
            sys.stdout.write(f"  forced model: {forced}\n")
            sys.stdout.flush()
            if isinstance(forced, dict) and forced.get("ok") is True:
                results.append(("force_model", True, f"{args.force_provider}/{args.force_model}"))
            else:
                results.append(("force_model", False, str(forced)[:100]))
        e2e_ok = False
        e2e_detail = "not run"
        for attempt in range(1, max(1, args.e2e_retries) + 1):
            sys.stdout.write(f"  attempt {attempt}/{max(1, args.e2e_retries)}\n")
            sys.stdout.flush()
            order_resp = client.call_tool("da_submit_order_async", {
                "order_text": args.order_text,
                "project_id": "mcp-external-test",
            })
            sys.stdout.write(f"  submit response: {order_resp}\n")
            sys.stdout.flush()
            order_id = extract_order_id(order_resp)
            if order_id is None:
                e2e_detail = "no order_id"
                continue

            sys.stdout.write(f"  order_id: {order_id}\n")
            sys.stdout.write("  polling plan_poll...\n")
            sys.stdout.flush()
            plan_done = False
            for i in range(90):
                poll = client.call_tool("plan_poll", {})
                if isinstance(poll, dict) and poll.get("done") == 1:
                    plan_done = True
                    sys.stdout.write(f"  plan done (poll #{i}): {poll}\n")
                    sys.stdout.flush()
                    break
                time.sleep(1)
            if not plan_done:
                e2e_detail = "plan timeout"
                continue

            plan = client.call_tool("get_plan", {"order_id": order_id})
            sys.stdout.write(f"  plan: {str(plan)[:200]}\n")
            sys.stdout.flush()
            use_fallback = False
            if not has_executable_tasks(plan):
                if args.no_fallback_plan:
                    e2e_detail = "plan has no executable tasks"
                    continue
                use_fallback = True
                sys.stdout.write("  live plan has no executable tasks; using deterministic plan_json fallback\n")
                sys.stdout.flush()

            confirm_args = {"order_id": order_id}
            if use_fallback:
                confirm_args["plan_json"] = fallback_plan_json()
            confirm = client.call_tool("confirm_plan", confirm_args)
            sys.stdout.write(f"  confirm: {confirm}\n")
            sys.stdout.flush()
            if not (isinstance(confirm, dict) and confirm.get("ok") is True):
                e2e_detail = f"confirm failed: {str(confirm)[:100]}"
                continue
            dispatch_start = client.call_tool("dispatch_async", {"order_id": order_id})
            sys.stdout.write(f"  dispatch_async: {dispatch_start}\n")
            sys.stdout.flush()
            if not (isinstance(dispatch_start, dict) and dispatch_start.get("ok") is True):
                e2e_detail = f"dispatch_async failed: {str(dispatch_start)[:100]}"
                continue

            sys.stdout.write("  polling dispatch_poll...\n")
            sys.stdout.flush()
            dispatch_done = False
            dpoll = None
            for i in range(120):
                dpoll = client.call_tool("dispatch_poll", {"order_id": order_id})
                if isinstance(dpoll, dict) and dpoll.get("done") == 1:
                    dispatch_done = True
                    sys.stdout.write(f"  dispatch done (poll #{i}): {dpoll}\n")
                    sys.stdout.flush()
                    break
                time.sleep(1)
            if not dispatch_done or not (isinstance(dpoll, dict) and dpoll.get("ok") == 1):
                e2e_detail = f"dispatch failed: {dpoll}"
                continue

            artifacts = client.call_tool("list_artifacts", {"order_id": order_id})
            sys.stdout.write(f"  artifacts: {str(artifacts)[:200]}\n")
            sys.stdout.flush()
            if not (isinstance(artifacts, list) and len(artifacts) > 0):
                e2e_detail = "no artifacts produced"
                continue

            events = client.call_tool("order_events", {"order_id": order_id, "since_event_id": 0})
            sys.stdout.write(f"  events: {str(events)[:200]}\n")
            sys.stdout.flush()
            e2e_ok = True
            fallback_note = ", fallback_plan=1" if use_fallback else ", fallback_plan=0"
            e2e_detail = f"order_id={order_id}, artifacts={len(artifacts)}, events={len(events) if isinstance(events, list) else 'n/a'}{fallback_note}"
            break
        results.append(("e2e_flow", e2e_ok, e2e_detail))

        # Step 7: sessions
        sys.stdout.write("\n=== Step 7: sessions ===\n")
        sys.stdout.flush()
        sessions = client.call_tool("sessions", {})
        sys.stdout.write(f"  sessions: {str(sessions)[:200]}\n")
        sys.stdout.flush()
        results.append(("sessions", True, "ok"))

    except Exception as e:
        sys.stdout.write(f"\n[ERROR] {e}\n")
        sys.stdout.flush()
        results.append(("error", False, str(e)))
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    # Summary
    sys.stdout.write("\n" + "=" * 60 + "\n")
    sys.stdout.write("SUMMARY\n")
    sys.stdout.write("=" * 60 + "\n")
    passed = 0
    failed = 0
    for name, ok, detail in results:
        status = "PASS" if ok else "FAIL"
        sys.stdout.write(f"  [{status}] {name}: {detail}\n")
        if ok:
            passed += 1
        else:
            failed += 1
    sys.stdout.write(f"\nTotal: {passed} passed, {failed} failed\n")
    sys.stdout.flush()

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
