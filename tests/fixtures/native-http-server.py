#!/usr/bin/env python3
"""Loopback-only fixture for native_http_test.zig; no external API or credentials."""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


TOOL_ARGS = {"exe": "python", "args": ["-c", "print('native-proof')"], "cwd": "."}
COUNTS = {"openai": 0, "anthropic": 0, "gemini": 0}


def protocol_for(path):
    if path.endswith("/chat/completions"):
        return "openai"
    if path.endswith("/messages"):
        return "anthropic"
    if ":generateContent" in path:
        return "gemini"
    raise ValueError("unknown fixture endpoint")


def expected_header(protocol):
    return {
        "openai": ("authorization", "Bearer fake-native-key"),
        "anthropic": ("x-api-key", "fake-native-key"),
        "gemini": ("x-goog-api-key", "fake-native-key"),
    }[protocol]


def tool_result(body, protocol):
    if protocol == "openai":
        return body["messages"][-1]["content"]
    if protocol == "anthropic":
        return body["messages"][-1]["content"][0]["content"]
    return body["contents"][-1]["parts"][0]["functionResponse"]["response"]["result"]


def tool_response(protocol):
    if protocol == "openai":
        return {"choices": [{"message": {"content": None, "tool_calls": [{"id": "native-call", "type": "function", "function": {"name": "run_command", "arguments": json.dumps(TOOL_ARGS)}}]}, "finish_reason": "tool_calls"}]}
    if protocol == "anthropic":
        return {"stop_reason": "tool_use", "content": [{"type": "tool_use", "id": "native-call", "name": "run_command", "input": TOOL_ARGS}]}
    return {"candidates": [{"finishReason": "STOP", "content": {"role": "model", "parts": [{"functionCall": {"id": "native-call", "name": "run_command", "args": TOOL_ARGS}}]}}]}


def done_response(protocol):
    if protocol == "openai":
        return {"choices": [{"message": {"content": "verified"}, "finish_reason": "stop"}]}
    if protocol == "anthropic":
        return {"stop_reason": "end_turn", "content": [{"type": "text", "text": "verified"}]}
    return {"candidates": [{"finishReason": "STOP", "content": {"role": "model", "parts": [{"text": "verified"}]}}]}


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def reply(self, status, value):
        encoded = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        try:
            protocol = protocol_for(self.path)
            name, value = expected_header(protocol)
            if self.headers.get(name) != value:
                raise ValueError("missing fixture authentication header")
            length = int(self.headers.get("content-length", "0"))
            body = json.loads(self.rfile.read(length))
            if "tools" not in body:
                raise ValueError("request omitted tool declarations")
            round_number = COUNTS[protocol]
            print(f"fixture {protocol} request {round_number + 1}", flush=True)
            COUNTS[protocol] += 1
            if round_number == 0:
                self.reply(200, tool_response(protocol))
                return
            if round_number == 1:
                result = json.loads(tool_result(body, protocol))
                print(f"fixture actual command result {result!r}", flush=True)
                if result.get("exit_code") != 0 or result.get("stdout", "").replace("\r\n", "\n") != "native-proof\n" or result.get("timed_out"):
                    raise ValueError("tool result did not contain native stdout and exit code")
                self.reply(200, done_response(protocol))
                COUNTS[protocol] = 0
                return
            raise ValueError("fixture received more than two calls for a protocol")
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            print(f"fixture rejected request: {error}", flush=True)
            self.reply(400, {"error": str(error)})


def main():
    port = int(sys.argv[1]) if len(sys.argv) == 2 else 19443
    server = ThreadingHTTPServer(("127.0.0.1", port), FixtureHandler)
    print(f"native HTTP fixture listening on http://127.0.0.1:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
