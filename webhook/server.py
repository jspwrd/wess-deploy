"""GitHub webhook listener that deploys when a CI/Deploy workflow succeeds.

Listens for `workflow_run` events (Settings -> Webhooks -> "Workflow runs")
and triggers deploy.sh only when the image-publishing workflow for a known
repo completes successfully on main. Push events are acknowledged but
ignored, so a push that fails CI never reaches production.
"""

import hashlib
import hmac
import json
import os
import signal
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
DEPLOY_SCRIPT = os.environ.get("DEPLOY_SCRIPT", "/opt/wess/scripts/deploy.sh")
PORT = 9000

# repo -> name of the workflow whose success means "a fresh image is in ghcr"
DEPLOYABLE = {
    "wess": "Deploy",
    "wess-backend": "Deploy",
    "AutoTLE": "CI",  # AutoTLE's CI workflow contains its docker-publish job
}


def verify_signature(payload: bytes, signature: str) -> bool:
    expected = "sha256=" + hmac.new(
        WEBHOOK_SECRET.encode(), payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


class WebhookHandler(BaseHTTPRequestHandler):
    def _respond(self, code: int, body: dict) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_POST(self):
        if self.path != "/webhook":
            self.send_error(404)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(content_length)

        signature = self.headers.get("X-Hub-Signature-256", "")
        if not verify_signature(payload, signature):
            print("[webhook] Invalid signature, rejecting", flush=True)
            self.send_error(403, "Invalid signature")
            return

        event = self.headers.get("X-GitHub-Event", "")

        if event == "ping":
            print("[webhook] Received ping event", flush=True)
            self._respond(200, {"status": "pong"})
            return

        if event == "push":
            # Deploys are gated on CI now; the push itself does nothing.
            self._respond(200, {"status": "ignored",
                                "reason": "deploys trigger on workflow_run success"})
            return

        if event != "workflow_run":
            self._respond(200, {"status": "ignored", "reason": f"event {event}"})
            return

        try:
            data = json.loads(payload)
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return

        repo = data.get("repository", {}).get("name", "")
        run = data.get("workflow_run", {}) or {}
        action = data.get("action", "")
        name = run.get("name", "")
        branch = run.get("head_branch", "")
        conclusion = run.get("conclusion", "")
        sha = (run.get("head_sha") or "")[:7]

        expected_workflow = DEPLOYABLE.get(repo)
        if expected_workflow is None:
            self._respond(200, {"status": "ignored", "reason": f"unknown repo {repo}"})
            return
        if action != "completed" or name != expected_workflow or branch != "main":
            self._respond(200, {"status": "ignored",
                                "reason": f"{repo}/{name} action={action} branch={branch}"})
            return
        if conclusion != "success":
            print(f"[webhook] {repo} {name} on main concluded '{conclusion}' "
                  f"({sha}) — not deploying", flush=True)
            self._respond(200, {"status": "ignored", "reason": f"conclusion {conclusion}"})
            return

        print(f"[webhook] {repo} {name} succeeded on main ({sha}), deploying...",
              flush=True)
        self._respond(202, {"status": "deploying", "repo": repo, "sha": sha})

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
            self._respond(200, {"status": "webhook listener running",
                                "deploys": list(DEPLOYABLE)})
            return
        self.send_error(404)

    def log_message(self, format, *args):
        print(f"[webhook] {args[0]}", flush=True)


if __name__ == "__main__":
    if not WEBHOOK_SECRET:
        print("[webhook] FATAL: WEBHOOK_SECRET is not set; refusing to start "
              "(signature verification is mandatory)", flush=True)
        sys.exit(1)
    # Auto-reap deploy children (we never inspect their exit status; without
    # this, each fire-and-forget Popen leaves a zombie under PID 1).
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    print(f"[webhook] Starting webhook listener on port {PORT}", flush=True)
    print(f"[webhook] Deploy script: {DEPLOY_SCRIPT}", flush=True)
    server = HTTPServer(("0.0.0.0", PORT), WebhookHandler)
    server.serve_forever()
