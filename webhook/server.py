"""Minimal GitHub webhook listener that triggers deployments on push to main."""

import hashlib
import hmac
import json
import os
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
DEPLOY_SCRIPT = "/repos/wess-deploy/scripts/deploy.sh"
PORT = 9000


def verify_signature(payload: bytes, signature: str) -> bool:
    if not WEBHOOK_SECRET:
        return True  # No secret configured, accept all
    expected = "sha256=" + hmac.new(
        WEBHOOK_SECRET.encode(), payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/webhook":
            self.send_error(404)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(content_length)

        # Verify GitHub signature
        signature = self.headers.get("X-Hub-Signature-256", "")
        if WEBHOOK_SECRET and not verify_signature(payload, signature):
            print("[webhook] Invalid signature, rejecting", flush=True)
            self.send_error(403, "Invalid signature")
            return

        # Parse event
        event = self.headers.get("X-GitHub-Event", "")
        if event == "ping":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"pong"}')
            print("[webhook] Received ping event", flush=True)
            return

        if event != "push":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ignored","reason":"not a push event"}')
            return

        try:
            data = json.loads(payload)
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return

        ref = data.get("ref", "")
        repo = data.get("repository", {}).get("name", "unknown")

        # Only deploy on push to main
        if ref != "refs/heads/main":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            msg = f'{{"status":"ignored","reason":"push to {ref}, not main"}}'
            self.wfile.write(msg.encode())
            print(f"[webhook] Ignoring push to {ref} on {repo}", flush=True)
            return

        print(f"[webhook] Push to main on {repo}, triggering deploy...", flush=True)

        # Respond immediately, deploy in background
        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"deploying"}')

        # Trigger deploy with repo name so only the relevant service is rebuilt
        try:
            subprocess.Popen(
                ["bash", DEPLOY_SCRIPT, repo],
                stdout=sys.stdout,
                stderr=sys.stderr,
            )
        except Exception as e:
            print(f"[webhook] Failed to start deploy: {e}", flush=True)

    def do_GET(self):
        if self.path == "/webhook":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"webhook listener running"}')
            return
        self.send_error(404)

    def log_message(self, format, *args):
        print(f"[webhook] {args[0]}", flush=True)


if __name__ == "__main__":
    print(f"[webhook] Starting webhook listener on port {PORT}", flush=True)
    if WEBHOOK_SECRET:
        print("[webhook] Signature verification enabled", flush=True)
    else:
        print("[webhook] WARNING: No WEBHOOK_SECRET set, accepting all requests", flush=True)
    server = HTTPServer(("0.0.0.0", PORT), WebhookHandler)
    server.serve_forever()
