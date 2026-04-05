#!/usr/bin/env python3
"""MCP-compliant proxy for Donut Browser.

Donut's MCP server doesn't implement the initialize/initialized handshake
required by the MCP spec. This proxy sits in front and handles the lifecycle
methods locally, forwarding all tool calls to Donut.

Runs on 127.0.0.1:51080 (what omp connects to), forwards to 127.0.0.1:51081
(where socat bridges to Donut via Unix socket).
"""

import http.client
import http.server
import json
import sys
import threading

LISTEN_PORT = 51080
DONUT_PORT = 51081


class MCPProxyHandler(http.server.BaseHTTPRequestHandler):
    """Proxy that adds MCP lifecycle compliance to Donut's stateless server."""

    # Suppress per-request logging; errors still print to stderr
    def log_request(self, code="-", size="-"):
        pass

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            req = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            # Not valid JSON — forward as-is, let Donut deal with it
            self._forward(body)
            return

        method = req.get("method", "")

        if method == "initialize":
            self._respond_json(200, {
                "jsonrpc": "2.0",
                "id": req.get("id"),
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "donut-browser", "version": "1.0"},
                },
            })
            return

        if method == "notifications/initialized":
            # Notification — no response body expected
            self.send_response(200)
            self.end_headers()
            return

        if method == "ping":
            self._respond_json(200, {
                "jsonrpc": "2.0",
                "id": req.get("id"),
                "result": {},
            })
            return

        # Everything else (tools/list, tools/call, etc.) goes to Donut
        if not self._donut_reachable():
            if method == "tools/list":
                # No Donut — advertise zero tools so omp doesn't crash
                self._respond_json(200, {
                    "jsonrpc": "2.0",
                    "id": req.get("id"),
                    "result": {"tools": []},
                })
            else:
                self._respond_json(200, {
                    "jsonrpc": "2.0",
                    "id": req.get("id"),
                    "error": {
                        "code": -32000,
                        "message": "Donut Browser is not running",
                    },
                })
            return

        self._forward(body, fixup_tools=(method == "tools/list"))

    def do_GET(self):
        # Streamable HTTP MCP: GET not supported
        self.send_response(405)
        self.end_headers()

    def do_DELETE(self):
        # Session termination — no-op since Donut is stateless
        self.send_response(200)
        self.end_headers()

    def _respond_json(self, status, obj):
        payload = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    @staticmethod
    def _donut_reachable():
        """Ping Donut to check if it's up."""
        try:
            conn = http.client.HTTPConnection("127.0.0.1", DONUT_PORT, timeout=2)
            conn.request("POST", "/mcp", json.dumps({
                "jsonrpc": "2.0", "id": 0, "method": "ping",
            }), {"Content-Type": "application/json"})
            conn.getresponse().read()
            conn.close()
            return True
        except (ConnectionRefusedError, OSError):
            return False

    @staticmethod
    def _fix_tool_schemas(resp_body):
        """Donut returns input_schema (snake_case) but MCP spec requires inputSchema (camelCase)."""
        try:
            data = json.loads(resp_body)
            for tool in data.get("result", {}).get("tools", []):
                if "input_schema" in tool and "inputSchema" not in tool:
                    tool["inputSchema"] = tool.pop("input_schema")
            return json.dumps(data).encode()
        except (json.JSONDecodeError, TypeError, AttributeError):
            return resp_body

    def _forward(self, body, fixup_tools=False):
        """Forward request to Donut via socat bridge on DONUT_PORT."""
        try:
            conn = http.client.HTTPConnection("127.0.0.1", DONUT_PORT, timeout=30)
            # Forward all headers except hop-by-hop
            fwd_headers = {}
            for key, val in self.headers.items():
                if key.lower() not in ("host", "transfer-encoding", "connection"):
                    fwd_headers[key] = val
            conn.request("POST", self.path, body, fwd_headers)
            resp = conn.getresponse()
            resp_body = resp.read()

            if fixup_tools:
                resp_body = self._fix_tool_schemas(resp_body)

            self.send_response(resp.status)
            # Recalculate Content-Length since body may have changed
            for key, val in resp.getheaders():
                if key.lower() not in ("transfer-encoding", "connection", "content-length"):
                    self.send_header(key, val)
            self.send_header("Content-Length", str(len(resp_body)))
            self.end_headers()
            self.wfile.write(resp_body)
            conn.close()
        except (ConnectionRefusedError, OSError) as exc:
            # Donut not reachable — return a proper JSON-RPC error
            self._respond_json(502, {
                "jsonrpc": "2.0",
                "id": None,
                "error": {
                    "code": -32000,
                    "message": f"Donut Browser unreachable: {exc}",
                },
            })


def main():
    server = http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), MCPProxyHandler)
    server.daemon_threads = True
    print(f"donut-mcp-proxy: listening on 127.0.0.1:{LISTEN_PORT}, forwarding to :{DONUT_PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
