#!/usr/bin/env python3
"""
app_server_smoke.py — Minimal smoke test for codex app-server WebSocket protocol.

Protocol reference: codex-rs/app-server/README.md
Transport: WebSocket, one JSON-RPC message per text frame (experimental).
Wire format: JSON-RPC 2.0 with "jsonrpc":"2.0" header OMITTED.

Steps tested:
  1. WebSocket connect
  2. initialize  (request id=0)
  3. initialized (notification, no id)
  4. thread/start (request id=1) → get threadId
  5. turn/start   (request id=2) → begin generation
  6. stream events until turn/completed or timeout

Usage:
  python3 tools/smoke/app_server_smoke.py [--url WS_URL] [--prompt TEXT] [--timeout SECS]

Dependencies:
  pip install websockets
"""

import argparse
import asyncio
import json
import sys
import time
from typing import Any, List, Optional

try:
    import websockets
    import websockets.exceptions
except ImportError:
    print("ERROR: missing dependency. Run: pip install websockets")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_seq = 0


def next_id() -> int:
    global _seq
    _seq += 1
    return _seq


def send_request(method: str, params: Optional[dict] = None) -> dict:
    """Build a JSON-RPC request (no 'jsonrpc' key — omitted on the wire)."""
    msg: dict[str, Any] = {"method": method, "id": next_id()}
    if params is not None:
        msg["params"] = params
    return msg


def send_notification(method: str, params: Optional[dict] = None) -> dict:
    """Build a JSON-RPC notification (no id, no 'jsonrpc' key)."""
    msg: dict[str, Any] = {"method": method}
    if params:
        msg["params"] = params
    return msg


def p(tag: str, payload: Any) -> None:
    ts = time.strftime("%H:%M:%S")
    line = json.dumps(payload) if isinstance(payload, dict) else str(payload)
    print(f"[{ts}] {tag}: {line}")


# ---------------------------------------------------------------------------
# Main smoke flow
# ---------------------------------------------------------------------------

async def run(url: str, prompt: str, timeout: float) -> None:
    steps_ok: List[str] = []
    steps_fail: List[str] = []
    blocker: Optional[str] = None

    def ok(step: str) -> None:
        steps_ok.append(step)
        print(f"  ✓  {step}")

    def fail(step: str, reason: str) -> None:
        steps_fail.append(step)
        nonlocal blocker
        if blocker is None:
            blocker = reason
        print(f"  ✗  {step}: {reason}")

    print(f"\n── smoke test  url={url}  timeout={timeout}s ──\n")

    # ── Step 1: connect ──────────────────────────────────────────────────────
    try:
        ws = await asyncio.wait_for(websockets.connect(url), timeout=5)
        ok("WebSocket connect")
    except Exception as e:
        fail("WebSocket connect", str(e))
        _print_summary(steps_ok, steps_fail, blocker)
        return

    async with ws:
        # ── Step 2: initialize request ───────────────────────────────────────
        init_req = send_request("initialize", {
            "clientInfo": {
                "name": "open_crab_smoke",
                "title": "小螃蟹 Smoke Test",
                "version": "0.0.1",
            }
        })
        p("sent", init_req)
        await ws.send(json.dumps(init_req))

        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=5)
            init_resp = json.loads(raw)
            p("recv", init_resp)
            if "result" in init_resp and init_resp.get("id") == init_req["id"]:
                ok("initialize")
            else:
                fail("initialize", f"unexpected response: {raw[:200]}")
                _print_summary(steps_ok, steps_fail, blocker)
                return
        except asyncio.TimeoutError:
            fail("initialize", "timeout waiting for response")
            _print_summary(steps_ok, steps_fail, blocker)
            return

        # ── Step 3: initialized notification ─────────────────────────────────
        init_notif = send_notification("initialized")
        p("sent", init_notif)
        await ws.send(json.dumps(init_notif))
        ok("initialized notification sent")

        # ── Step 4: thread/start ─────────────────────────────────────────────
        thread_req = send_request("thread/start", {
            "approvalPolicy": "never",  # no interactive approval needed for smoke test
            "ephemeral": True,          # in-memory only, nothing persisted to disk
        })
        p("sent", thread_req)
        await ws.send(json.dumps(thread_req))

        thread_id: Optional[str] = None
        deadline = asyncio.get_event_loop().time() + 5
        while asyncio.get_event_loop().time() < deadline:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=2)
                msg = json.loads(raw)
                p("recv", msg)
                # response to our thread/start request
                if msg.get("id") == thread_req["id"] and "result" in msg:
                    thread_id = msg["result"]["thread"]["id"]
                    ok(f"thread/start → threadId={thread_id}")
                    break
                # ignore out-of-order notifications
            except asyncio.TimeoutError:
                break

        if thread_id is None:
            fail("thread/start", "no thread id received within 5s")
            _print_summary(steps_ok, steps_fail, blocker)
            return

        # ── Step 5: turn/start ───────────────────────────────────────────────
        turn_req = send_request("turn/start", {
            "threadId": thread_id,
            "input": [{"type": "text", "text": prompt}],
            "approvalPolicy": "never",
        })
        p("sent", turn_req)
        await ws.send(json.dumps(turn_req))

        turn_id: Optional[str] = None
        deadline = asyncio.get_event_loop().time() + 5
        while asyncio.get_event_loop().time() < deadline:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=2)
                msg = json.loads(raw)
                p("recv", msg)
                if msg.get("id") == turn_req["id"] and "result" in msg:
                    turn_id = msg["result"]["turn"]["id"]
                    ok(f"turn/start → turnId={turn_id}")
                    break
            except asyncio.TimeoutError:
                break

        if turn_id is None:
            fail("turn/start", "no turn id received within 5s")
            _print_summary(steps_ok, steps_fail, blocker)
            return

        # ── Step 6: stream events until turn/completed ───────────────────────
        print(f"\n── streaming events (timeout={timeout}s) ──")
        completed = False
        agent_text: List[str] = []
        stream_deadline = asyncio.get_event_loop().time() + timeout

        while asyncio.get_event_loop().time() < stream_deadline:
            remaining = stream_deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                break
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=min(remaining, 2))
                msg = json.loads(raw)
                method = msg.get("method", "")
                params = msg.get("params", {})

                # agentMessage delta — collect streamed text
                # delta field may be a plain string or {"text": "..."} object
                if method == "item/agentMessage/delta":
                    raw_delta = params.get("delta", "")
                    if isinstance(raw_delta, str):
                        chunk = raw_delta
                    else:
                        chunk = raw_delta.get("text", "")
                    if chunk:
                        agent_text.append(chunk)
                        print(f"  delta: {chunk!r}")
                    continue

                p("recv", msg)

                if method == "turn/completed":
                    ok(f"turn/completed (status={params.get('turn', {}).get('status', '?')})")
                    completed = True
                    break

            except asyncio.TimeoutError:
                continue
            except websockets.exceptions.ConnectionClosed as e:
                fail("stream", f"connection closed: {e}")
                break

        if not completed:
            fail("turn/completed", f"not received within {timeout}s timeout")

        if agent_text:
            full = "".join(agent_text)
            ok(f"agent replied ({len(full)} chars): {full[:120]!r}")
        else:
            # not necessarily a failure — text might arrive in agentMessage item
            print("  (no agentMessage/delta chunks captured)")

    _print_summary(steps_ok, steps_fail, blocker)


def _print_summary(ok: List[str], fail: List[str], blocker: Optional[str]) -> None:
    print("\n── summary ─────────────────────────────────────────")
    print(f"  passed : {len(ok)}")
    print(f"  failed : {len(fail)}")
    if blocker:
        print(f"  blocker: {blocker}")

    if not fail:
        print("\nresult: PASS")
    elif ok:
        print("\nresult: PARTIAL PASS")
    else:
        print("\nresult: FAIL")
    print("────────────────────────────────────────────────────\n")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Smoke test for codex app-server")
    parser.add_argument("--url", default="ws://127.0.0.1:60000",
                        help="WebSocket URL (default: ws://127.0.0.1:60000)")
    parser.add_argument("--prompt", default="Reply with exactly: ok",
                        help="User prompt sent to the model")
    parser.add_argument("--timeout", type=float, default=60.0,
                        help="Seconds to wait for turn/completed (default: 60)")
    args = parser.parse_args()

    asyncio.run(run(args.url, args.prompt, args.timeout))


if __name__ == "__main__":
    main()
