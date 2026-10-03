#!/usr/bin/env python3
# A stand-in for the two model APIs the real-agent probe (RealAgentProbeTests) points the agents
# at, so a real Claude Code or Codex turn runs end to end without an account and without leaving
# loopback. It answers every turn with the text "pong":
#
#   POST /v1/messages               Anthropic Messages, streamed (SSE) or not; count_tokens too
#   POST /v1/responses              OpenAI Responses, streamed (SSE)
#   GET  anything                   an empty JSON object
#
# A request that offers tools is the agent's main turn; it is held for --delay seconds before the
# answer starts, so the agent's own "busy" state lasts long enough to be observed. Side requests
# (titles, quota probes) carry no tools and answer at once.
#
# Usage: fake-model-api.py <port-file> <request-log> [--delay SECONDS]
# Writes the bound loopback port to <port-file> once it listens; one line per request to the log.
import http.server
import json
import os
import sys
import time

USAGE_ANTHROPIC = {
    "input_tokens": 12, "output_tokens": 3,
    "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
}
USAGE_OPENAI = {
    "input_tokens": 12, "input_tokens_details": {"cached_tokens": 0},
    "output_tokens": 3, "output_tokens_details": {"reasoning_tokens": 0},
    "total_tokens": 15,
}
TEXT = "pong"


def sse(event, data):
    return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    delay = 0.0
    log = None

    def log_message(self, *args):
        pass

    def note(self, line):
        self.log.write(line + "\n")
        self.log.flush()

    def send_json(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_stream(self, body):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        self.note(f"GET {self.path}")
        self.send_json({})

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            request = json.loads(raw or b"{}")
        except ValueError:
            request = {}
        tools = len(request.get("tools") or [])
        self.note(f"POST {self.path} stream={bool(request.get('stream'))} tools={tools}")
        if "count_tokens" in self.path:
            self.send_json({"input_tokens": USAGE_ANTHROPIC["input_tokens"]})
            return
        if tools and self.delay:
            time.sleep(self.delay)
        if self.path.split("?")[0].rstrip("/").endswith("/responses"):
            self.send_stream(self.responses_stream())
        elif request.get("stream"):
            self.send_stream(self.messages_stream(request.get("model", "")))
        else:
            self.send_json({
                "id": "msg_probe", "type": "message", "role": "assistant",
                "model": request.get("model", ""),
                "content": [{"type": "text", "text": TEXT}],
                "stop_reason": "end_turn", "stop_sequence": None, "usage": USAGE_ANTHROPIC,
            })

    def messages_stream(self, model):
        return b"".join([
            sse("message_start", {"type": "message_start", "message": {
                "id": "msg_probe", "type": "message", "role": "assistant", "model": model,
                "content": [], "stop_reason": None, "stop_sequence": None,
                "usage": USAGE_ANTHROPIC}}),
            sse("content_block_start", {"type": "content_block_start", "index": 0,
                                        "content_block": {"type": "text", "text": ""}}),
            sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                                        "delta": {"type": "text_delta", "text": TEXT}}),
            sse("content_block_stop", {"type": "content_block_stop", "index": 0}),
            sse("message_delta", {"type": "message_delta",
                                  "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                  "usage": {"output_tokens": USAGE_ANTHROPIC["output_tokens"]}}),
            sse("message_stop", {"type": "message_stop"}),
        ])

    def responses_stream(self):
        def event(kind, data):
            return sse(kind, dict(data, type=kind))
        item = {"type": "message", "role": "assistant", "id": "msg_probe", "status": "completed",
                "content": [{"type": "output_text", "text": TEXT, "annotations": []}]}
        return b"".join([
            event("response.created", {"response": {"id": "resp_probe"}}),
            event("response.output_item.added",
                  {"output_index": 0, "item": dict(item, content=[], status="in_progress")}),
            event("response.output_text.delta",
                  {"output_index": 0, "content_index": 0, "item_id": "msg_probe", "delta": TEXT}),
            event("response.output_item.done", {"output_index": 0, "item": item}),
            event("response.completed", {"response": {"id": "resp_probe", "usage": USAGE_OPENAI}}),
        ])


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: fake-model-api.py <port-file> <request-log> [--delay SECONDS]")
    if "--delay" in sys.argv:
        Handler.delay = float(sys.argv[sys.argv.index("--delay") + 1])
    Handler.log = open(sys.argv[2], "a")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1] + ".tmp", "w") as f:
        f.write(str(server.server_address[1]))
    os.replace(sys.argv[1] + ".tmp", sys.argv[1])
    server.serve_forever()


if __name__ == "__main__":
    main()
