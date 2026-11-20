"""Loopback-only Cohere responses. No provider keys or owner data."""
import http.server
import json
import os
import subprocess
import sys
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size > 1024 * 1024:
            self.send_error(413)
            return
        request = json.loads(self.rfile.read(size))
        assert request['model'] == 'command-a-plus-05-2026'
        assert 'stream_options' not in request
        assert 'response_format' not in request
        case = self.path.split('/')[1]
        if case == 'planner-hang':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', '1000000')
            self.end_headers()
            # Trickle heartbeats: silence deadlines alone cannot bound this call.
            try:
                for _ in range(40):
                    self.wfile.write(b': keepalive\n\n')
                    self.wfile.flush()
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass  # The client is expected to cancel this synthetic stream.
            return
        if case in ('planner-ok', 'planner-large', 'planner-parse', 'planner-delayed'):
            if case == 'planner-delayed':
                time.sleep(1.6)
            reply = 'P' * 9000 if case == 'planner-large' else 'Plan del proveedor sano'
            plan = json.dumps({'kind': 'chat', 'reply': reply})
            chunk = json.dumps({'choices': [{'delta': {'content': plan}}]})
            text = ('data:' if case == 'planner-large' else 'data: ') + chunk + '\n\ndata: [DONE]\n\n'
            if case == 'planner-parse':
                text = 'data: ' + ('X' * (70 * 1024)) + '\n\n'
            status = 200
        else:
            status, text = {
                '429': (429, '{"message":"trial limit reached"}'),
                '404': (404, '{"message":"model not found"}'),
                '400': (400, '{"message":"tools and stream not supported"}'),
                '401': (401, '{"message":"invalid access"}'),
                '403': (403, '{"message":"access denied"}'),
                '402': (402, '{"message":"quota exhausted"}'),
                '503': (503, '{"message":"service unavailable"}'),
                'secret': (400, '{"message":"echo fake-native-key"}'),
                'empty': (200, 'data: [DONE]\n\n'),
                'budget': (200, 'data: {"choices":[{"delta":{"content":"Hola"}}]}\n\ndata: [DONE]\n\n'),
            }[case]
        body = text.encode()
        self.send_response(status)
        self.send_header('Content-Type', 'text/event-stream' if status == 200 else 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    command = sys.argv[1:]
    if command and command[0] == '--':
        command.pop(0)
    if not command:
        raise SystemExit('Usage: ordenes_fixture.py -- command args')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    env = os.environ.copy()
    env['DEVAGENTS_ORDENES_TEST_URL'] = f'http://127.0.0.1:{server.server_port}'
    try:
        print('SYNTHETIC_COHERE_LOOPBACK=' + env['DEVAGENTS_ORDENES_TEST_URL'], flush=True)
        return subprocess.call(command, env=env)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    raise SystemExit(main())
