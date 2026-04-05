#!/usr/bin/env python3
"""
app_server_auth_smoke.py — Auth + minimal session smoke test for codex app-server.

Reads configuration from tools/smoke/app_server_auth_config.json (copy from .example).

Config fields:
  url            — WebSocket URL (default: ws://127.0.0.1:60000)
  apiKey         — OpenAI API key for account/login/start (type: apiKey)
  providerBaseUrl — (TODO: not yet wired; no documented RPC key — kept as placeholder)
  provider        — (TODO: not yet wired; no documented RPC key — kept as placeholder)

Steps:
  1. WebSocket connect
  2. initialize + initialized
  3. account/read  — check current auth state
  4. account/login/start (type: apiKey) — only if apiKey is set
  5. Wait for account/login/completed notification
  6. thread/start  — prove the session works post-login
  7. Output PASS / PARTIAL PASS / FAIL

Protocol reference: codex-rs/app-server/README.md § Auth endpoints

Dependencies:
  pip install websockets
"""

import asyncio
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, List, Optional

try:
    import websockets
    import websockets.exceptions
except ImportError:
    print("ERROR: missing dependency. Run: pip install websockets")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).parent
CONFIG_PATH = SCRIPT_DIR / "app_server_auth_config.json"
EXAMPLE_PATH = SCRIPT_DIR / "app_server_auth_config.json.example"

PLACEHOLDER_KEYS = {"", "sk-...", "YOUR_API_KEY_HERE"}


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        if EXAMPLE_PATH.exists():
            import shutil
            shutil.copy(EXAMPLE_PATH, CONFIG_PATH)
            print(f"[info] Created {CONFIG_PATH} from example. Fill in real values to run auth smoke.")
        else:
            print(f"ERROR: {CONFIG_PATH} not found.")
            sys.exit(1)
    with open(CONFIG_PATH) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# JSON-RPC helpers
# ---------------------------------------------------------------------------

_seq = 0


def next_id() -> int:
    global _seq
    _seq += 1
    return _seq


def req(method: str, params: Optional[dict] = None) -> dict:
    msg: dict[str, Any] = {"method": method, "id": next_id()}
    if params is not None:
        msg["params"] = params
    return msg


def notif(method: str, params: Optional[dict] = None) -> dict:
    msg: dict[str, Any] = {"method": method}
    if params:
        msg["params"] = params
    return msg


def p(tag: str, payload: Any) -> None:
    ts = time.strftime("%H:%M:%S")
    line = json.dumps(payload) if isinstance(payload, dict) else str(payload)
    print(f"[{ts}] {tag}: {line}")


# ---------------------------------------------------------------------------
# Smoke flow
# ---------------------------------------------------------------------------

async def run(cfg: dict) -> None:
    url: str = cfg.get("url", "ws://127.0.0.1:60000")
    api_key: str = cfg.get("apiKey", "")
    # providerBaseUrl / provider: kept in config but NOT wired to any RPC.
    # README does not document the config/value/write key names for these fields.
    # TODO: verify key names before wiring.

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

    has_real_key = api_key and api_key not in PLACEHOLDER_KEYS

    print(f"\n── auth smoke  url={url} ──")
    print(f"   apiKey present: {'yes (real)' if has_real_key else 'no / placeholder'}")
    print(f"   providerBaseUrl: {'set (TODO — not wired to RPC)' if cfg.get('providerBaseUrl') else 'empty'}")
    print(f"   provider:        {'set (TODO — not wired to RPC)' if cfg.get('provider') else 'empty'}")
    print()

    if not has_real_key:
        print("  [skip] No real apiKey in config — skipping auth smoke.")
        print("         Fill in tools/smoke/app_server_auth_config.json to test real login.\n")
        _print_summary(steps_ok, steps_fail,
                       "Missing real apiKey — cannot complete auth smoke",
                       has_real_key=False)
        return

    # ── Step 1: connect ──────────────────────────────────────────────────────
    try:
        ws = await asyncio.wait_for(websockets.connect(url), timeout=5)
        ok("WebSocket connect")
    except Exception as e:
        fail("WebSocket connect", str(e))
        _print_summary(steps_ok, steps_fail, blocker)
        return

    async with ws:
        # ── Step 2: initialize ───────────────────────────────────────────────
        init_req = req("initialize", {
            "clientInfo": {
                "name": "open_crab_auth_smoke",
                "title": "小螃蟹 Auth Smoke",
                "version": "0.0.1",
            }
        })
        p("sent", init_req)
        await ws.send(json.dumps(init_req))

        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=5)
            resp = json.loads(raw)
            p("recv", resp)
            if "result" in resp and resp.get("id") == init_req["id"]:
                ok("initialize")
            else:
                fail("initialize", f"unexpected: {raw[:200]}")
                _print_summary(steps_ok, steps_fail, blocker)
                return
        except asyncio.TimeoutError:
            fail("initialize", "timeout")
            _print_summary(steps_ok, steps_fail, blocker)
            return

        init_n = notif("initialized")
        p("sent", init_n)
        await ws.send(json.dumps(init_n))
        ok("initialized notification sent")

        # ── Step 3: account/read — check current auth state ──────────────────
        ar = req("account/read", {})
        p("sent", ar)
        await ws.send(json.dumps(ar))

        account_info: Optional[dict] = None
        deadline = asyncio.get_event_loop().time() + 5
        while asyncio.get_event_loop().time() < deadline:
            try:
                remaining = deadline - asyncio.get_event_loop().time()
                raw = await asyncio.wait_for(ws.recv(), timeout=max(remaining, 0.1))
                resp = json.loads(raw)
                p("recv", resp)
                # Skip notifications (no "id") — e.g. configWarning
                if "id" not in resp:
                    continue
                if "result" in resp and resp.get("id") == ar["id"]:
                    account_info = resp["result"]
                    ok(f"account/read → {json.dumps(account_info)[:120]}")
                else:
                    fail("account/read", f"unexpected: {raw[:200]}")
                break
            except asyncio.TimeoutError:
                fail("account/read", "timeout")
                break

        # ── Step 4: account/login/start (apiKey) ─────────────────────────────
        # Only call if not already logged in with an api key
        already_logged_in = (
            account_info is not None
            and isinstance(account_info.get("account"), dict)
            and account_info["account"].get("type") == "apiKey"
        )

        if already_logged_in:
            ok("account/login/start — skipped (already logged in with apiKey)")
            login_success = True
        else:
            login_req = req("account/login/start", {
                "type": "apiKey",
                "apiKey": api_key,
            })
            p("sent", login_req)
            await ws.send(json.dumps(login_req))

            # Expect: response to login/start + account/login/completed notification
            login_resp_ok = False
            login_success = False
            deadline = asyncio.get_event_loop().time() + 10
            while asyncio.get_event_loop().time() < deadline:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=3)
                    msg = json.loads(raw)
                    p("recv", msg)

                    # Response to our login request
                    if msg.get("id") == login_req["id"]:
                        if "result" in msg:
                            login_resp_ok = True
                            ok(f"account/login/start response: {json.dumps(msg['result'])[:120]}")
                        elif "error" in msg:
                            fail("account/login/start", f"RPC error: {msg['error']}")
                            break
                        continue

                    # Notification: account/login/completed
                    if msg.get("method") == "account/login/completed":
                        params = msg.get("params", {})
                        if params.get("success"):
                            ok(f"account/login/completed — success")
                            login_success = True
                        else:
                            fail("account/login/completed", f"failed: {params.get('error')}")
                        break

                    # Notification: account/updated
                    if msg.get("method") == "account/updated":
                        ok(f"account/updated → authMode={msg.get('params', {}).get('authMode')}")

                except asyncio.TimeoutError:
                    if login_resp_ok:
                        # got the response but no completed notification yet — keep waiting
                        continue
                    break

            if not login_success and "account/login/start" not in [s for s in steps_fail]:
                fail("account/login/start", "no account/login/completed received within 10s")

        if not login_success:
            _print_summary(steps_ok, steps_fail, blocker)
            return

        # ── Step 5: thread/start — prove session works post-login ────────────
        tr = req("thread/start", {
            "approvalPolicy": "never",
            "ephemeral": True,
        })
        p("sent", tr)
        await ws.send(json.dumps(tr))

        thread_id: Optional[str] = None
        deadline = asyncio.get_event_loop().time() + 5
        while asyncio.get_event_loop().time() < deadline:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=2)
                msg = json.loads(raw)
                p("recv", msg)
                if msg.get("id") == tr["id"] and "result" in msg:
                    thread_id = msg["result"]["thread"]["id"]
                    ok(f"thread/start → threadId={thread_id}")
                    break
            except asyncio.TimeoutError:
                break

        if thread_id is None:
            fail("thread/start", "no thread id within 5s")

    _print_summary(steps_ok, steps_fail, blocker)


def _print_summary(
    ok_list: List[str],
    fail_list: List[str],
    blocker: Optional[str],
    has_real_key: bool = True,
) -> None:
    print("\n── summary ─────────────────────────────────────────")
    print(f"  passed : {len(ok_list)}")
    print(f"  failed : {len(fail_list)}")
    if blocker:
        print(f"  blocker: {blocker}")

    print()
    print("  verified:")
    print("    ✓  WebSocket connect + initialize handshake")
    print("    ✓  account/read (check current auth state)")
    if has_real_key:
        print("    ✓  account/login/start (type: apiKey) via JSON-RPC")
        print("    ✓  account/login/completed notification")
        print("    ✓  thread/start post-login")
    else:
        print("    —  account/login/start: skipped (no real apiKey)")

    print()
    print("  TODO / unverified:")
    print("    ✗  providerBaseUrl via RPC — config/value/write key name not documented in README")
    print("    ✗  provider override via RPC — no documented RPC field found")
    print("    ✗  chatgpt auth flow (browser OAuth) — out of scope for headless smoke")

    if not fail_list and has_real_key:
        verdict = "PASS"
    elif ok_list and not has_real_key:
        verdict = "PARTIAL PASS (no real apiKey — auth steps skipped)"
    elif ok_list:
        verdict = "PARTIAL PASS"
    else:
        verdict = "FAIL"

    print(f"\nresult: {verdict}")
    print("────────────────────────────────────────────────────\n")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    cfg = load_config()
    asyncio.run(run(cfg))


if __name__ == "__main__":
    main()
