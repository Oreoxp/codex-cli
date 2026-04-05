#!/usr/bin/env python3
"""
app_server_config_smoke.py — Verify provider / baseURL config via config/batchWrite RPC.

Reads from tools/smoke/app_server_auth_config.json:
  url            — WebSocket URL (default ws://127.0.0.1:60000)
  apiKey         — used as experimental_bearer_token for the custom provider entry
  providerBaseUrl — base URL to write into model_providers (e.g. https://api.siliconflow.cn/v1)
  provider       — model name (informational; used in thread/start if present)

What this smoke test verifies:
  1. config/read         — current effective config can be fetched
  2. config/batchWrite   — provider entry + model_provider key are written to config.toml
  3. config/read (again) — written values round-trip back from disk
  4. thread/start        — thread.modelProvider in the response matches the written provider ID

True config key names (verified from source):
  model_providers.<id>   dot-notation key path for one provider entry in model_providers map
  model_provider         string key selecting the active provider ID

RPC param fields use camelCase (all structs have #[serde(rename_all = "camelCase")]):
  keyPath, mergeStrategy, filePath, expectedVersion, reloadUserConfig, includeLayers

MergeStrategy enum (camelCase): "replace", "upsert"

Provider entry fields use snake_case (ModelProviderInfo has no rename_all):
  name, base_url, experimental_bearer_token, wire_api

Runtime effectiveness:
  config/batchWrite with reloadUserConfig=true hot-reloads into loaded threads.
  thread/start after the write reports which provider was resolved (thread.modelProvider).
  If these match, the runtime HAS read the new config without restart.
  If they don't match, the smoke will report the discrepancy clearly.

Difference from auth smoke:
  auth smoke verifies account/login/start (OpenAI API key auth flow).
  config smoke verifies config/batchWrite for custom provider injection.
  They are complementary; config smoke only runs if real providerBaseUrl + apiKey are present.

Dependencies:
  pip install websockets

Usage:
  python3 tools/smoke/app_server_config_smoke.py
"""

import asyncio
import json
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

PLACEHOLDER_VALUES = {"", "sk-...", "YOUR_API_KEY_HERE", "https://api.openai.com/v1"}
SMOKE_PROVIDER_ID = "smoke_siliconflow"


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        print(f"ERROR: {CONFIG_PATH} not found.")
        print("       Copy app_server_auth_config.json.example and fill in real values.")
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
    line = json.dumps(payload, ensure_ascii=False) if isinstance(payload, (dict, list)) else str(payload)
    # Truncate long lines
    if len(line) > 300:
        line = line[:297] + "..."
    print(f"[{ts}] {tag}: {line}")


async def recv_until_response(ws, request_id: int, timeout_secs: float = 10.0) -> Optional[dict]:
    """
    Read frames until we receive a response matching request_id, or timeout.
    Prints (and skips) any notifications received along the way.
    """
    deadline = asyncio.get_event_loop().time() + timeout_secs
    while asyncio.get_event_loop().time() < deadline:
        remaining = deadline - asyncio.get_event_loop().time()
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=min(remaining, 2.0))
            msg = json.loads(raw)
            if "id" not in msg:
                # notification — print and skip
                p("notif", msg)
                continue
            p("recv", msg)
            if msg.get("id") == request_id:
                return msg
            # response to a different id — skip (shouldn't happen in serial flow)
        except asyncio.TimeoutError:
            continue
        except websockets.exceptions.ConnectionClosed as e:
            print(f"  [!] connection closed: {e}")
            return None
    return None  # timeout


# ---------------------------------------------------------------------------
# Main smoke flow
# ---------------------------------------------------------------------------

async def run(cfg: dict) -> None:
    url: str = cfg.get("url", "ws://127.0.0.1:60000")
    api_key: str = cfg.get("apiKey", "")
    provider_base_url: str = cfg.get("providerBaseUrl", "")
    model_name: str = cfg.get("provider", "")  # model name (e.g. deepseek-ai/DeepSeek-V3.2)

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

    has_base_url = bool(provider_base_url) and provider_base_url not in PLACEHOLDER_VALUES
    has_api_key = bool(api_key) and api_key not in PLACEHOLDER_VALUES

    print(f"\n── config smoke  url={url} ──")
    print(f"   providerBaseUrl : {'set → ' + provider_base_url if has_base_url else 'missing / placeholder'}")
    print(f"   apiKey present  : {'yes' if has_api_key else 'no / placeholder'}")
    print(f"   model name      : {model_name or '(not set)'}")
    print()

    if not has_base_url:
        print("  [skip] providerBaseUrl not set — cannot verify provider config injection.")
        print("         Fill in tools/smoke/app_server_auth_config.json to run full config smoke.")
        _print_summary(steps_ok, steps_fail,
                       "Missing real providerBaseUrl — config write step not attempted",
                       has_real_config=False)
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
        # ── Step 2: initialize + initialized ─────────────────────────────────
        init_req = req("initialize", {
            "clientInfo": {
                "name": "open_crab_config_smoke",
                "title": "小螃蟹 Config Smoke",
                "version": "0.0.1",
            }
        })
        p("sent", init_req)
        await ws.send(json.dumps(init_req))
        resp = await recv_until_response(ws, init_req["id"])
        if resp and "result" in resp:
            ok("initialize")
        else:
            fail("initialize", f"unexpected response: {resp}")
            _print_summary(steps_ok, steps_fail, blocker)
            return

        init_n = notif("initialized")
        p("sent", init_n)
        await ws.send(json.dumps(init_n))
        ok("initialized notification sent")

        # ── Step 3: config/read — snapshot current config ────────────────────
        cr = req("config/read", {"includeLayers": False})
        p("sent", cr)
        await ws.send(json.dumps(cr))
        cr_resp = await recv_until_response(ws, cr["id"])

        original_model_provider: Optional[str] = None
        if cr_resp and "result" in cr_resp:
            config_before = cr_resp["result"].get("config", {})
            original_model_provider = config_before.get("model_provider")
            ok(f"config/read (before) — model_provider={original_model_provider!r}")
            # Show existing custom providers if any
            existing_providers = list((config_before.get("model_providers") or {}).keys())
            if existing_providers:
                print(f"       existing model_providers: {existing_providers}")
        else:
            fail("config/read (before)", f"unexpected response: {cr_resp}")
            _print_summary(steps_ok, steps_fail, blocker)
            return

        # ── Step 4: config/batchWrite — inject provider + select it ──────────
        # Key path "model_providers.<id>" uses dot-notation to add one entry
        # without destroying other providers already in the map.
        # ModelProviderInfo fields are snake_case (no rename_all on the struct).
        # experimental_bearer_token is used as Authorization: Bearer <token>.
        provider_entry: dict[str, Any] = {
            "name": "SiliconFlow (smoke test)",
            "base_url": provider_base_url,
            "wire_api": "responses",
            "requires_openai_auth": False,
        }
        if has_api_key:
            # Store key as experimental_bearer_token for direct injection.
            # NOTE: this writes the key to config.toml on disk.
            provider_entry["experimental_bearer_token"] = api_key

        bw = req("config/batchWrite", {
            "edits": [
                {
                    "keyPath": f"model_providers.{SMOKE_PROVIDER_ID}",
                    "value": provider_entry,
                    "mergeStrategy": "replace",
                },
                {
                    "keyPath": "model_provider",
                    "value": SMOKE_PROVIDER_ID,
                    "mergeStrategy": "replace",
                },
            ],
            "reloadUserConfig": True,
        })
        p("sent", bw)
        await ws.send(json.dumps(bw))
        bw_resp = await recv_until_response(ws, bw["id"])

        if bw_resp and "result" in bw_resp:
            status = bw_resp["result"].get("status", "?")
            written_path = bw_resp["result"].get("filePath", "?")
            ok(f"config/batchWrite → status={status}, file={written_path}")
        elif bw_resp and "error" in bw_resp:
            fail("config/batchWrite", f"RPC error: {bw_resp['error']}")
            _print_summary(steps_ok, steps_fail, blocker)
            return
        else:
            fail("config/batchWrite", f"unexpected response: {bw_resp}")
            _print_summary(steps_ok, steps_fail, blocker)
            return

        # ── Step 5: config/read — verify write persisted ─────────────────────
        cr2 = req("config/read", {"includeLayers": False})
        p("sent", cr2)
        await ws.send(json.dumps(cr2))
        cr2_resp = await recv_until_response(ws, cr2["id"])

        written_model_provider: Optional[str] = None
        written_base_url: Optional[str] = None
        if cr2_resp and "result" in cr2_resp:
            config_after = cr2_resp["result"].get("config", {})
            written_model_provider = config_after.get("model_provider")
            providers_after = config_after.get("model_providers") or {}
            smoke_entry = providers_after.get(SMOKE_PROVIDER_ID, {})
            written_base_url = smoke_entry.get("base_url")

            if written_model_provider == SMOKE_PROVIDER_ID:
                ok(f"config/read (after) — model_provider={written_model_provider!r} ✓ matches written value")
            else:
                fail("config/read (after)", f"model_provider={written_model_provider!r} (expected {SMOKE_PROVIDER_ID!r})")

            if written_base_url == provider_base_url:
                ok(f"config/read (after) — model_providers.{SMOKE_PROVIDER_ID}.base_url={written_base_url!r} ✓")
            else:
                fail("config/read (after)",
                     f"base_url mismatch: got {written_base_url!r}, expected {provider_base_url!r}")
        else:
            fail("config/read (after)", f"unexpected response: {cr2_resp}")
            _print_summary(steps_ok, steps_fail, blocker)
            return

        # ── Step 6: thread/start — does runtime use the new provider? ─────────
        # thread.modelProvider in the response tells us which provider was resolved.
        thread_params: dict[str, Any] = {
            "approvalPolicy": "never",
            "ephemeral": True,
        }
        if model_name:
            thread_params["model"] = model_name

        tr = req("thread/start", thread_params)
        p("sent", tr)
        await ws.send(json.dumps(tr))
        tr_resp = await recv_until_response(ws, tr["id"], timeout_secs=10.0)

        runtime_provider: Optional[str] = None
        thread_id: Optional[str] = None
        if tr_resp and "result" in tr_resp:
            thread = tr_resp["result"].get("thread", {})
            thread_id = thread.get("id")
            runtime_provider = thread.get("modelProvider")
            ok(f"thread/start → id={thread_id}, modelProvider={runtime_provider!r}")
        elif tr_resp and "error" in tr_resp:
            # thread/start may fail if model is wrong or provider config bad
            fail("thread/start", f"RPC error: {tr_resp['error']}")
        else:
            fail("thread/start", f"unexpected response: {tr_resp}")

        # ── Step 7: turn/start — verify no 404 /v1/responses ─────────────────
        # Minimal prompt just to confirm the LLM call reaches the right endpoint.
        turn_started = False
        turn_error: Optional[str] = None
        turn_id: Optional[str] = None
        if thread_id and runtime_provider == SMOKE_PROVIDER_ID:
            turn_params: dict[str, Any] = {
                "threadId": thread_id,
                "input": [{"type": "text", "text": "Reply with exactly: ok"}],
                "approvalPolicy": "never",
            }
            if model_name:
                turn_params["model"] = model_name
            trn = req("turn/start", turn_params)
            p("sent", trn)
            await ws.send(json.dumps(trn))
            trn_resp = await recv_until_response(ws, trn["id"], timeout_secs=10.0)
            if trn_resp and "result" in trn_resp:
                turn_id = trn_resp["result"].get("turn", {}).get("id")
                ok(f"turn/start → turnId={turn_id}")
                turn_started = True
            elif trn_resp and "error" in trn_resp:
                fail("turn/start", f"RPC error: {trn_resp['error']}")
            else:
                fail("turn/start", f"unexpected: {trn_resp}")

            # Drain notifications for up to 15s; watch for error or turn/completed.
            if turn_started:
                print("  (draining notifications up to 15s...)")
                drain_deadline = asyncio.get_event_loop().time() + 15.0
                got_404 = False
                while asyncio.get_event_loop().time() < drain_deadline:
                    remaining = drain_deadline - asyncio.get_event_loop().time()
                    try:
                        raw = await asyncio.wait_for(ws.recv(), timeout=min(remaining, 2.0))
                        msg = json.loads(raw)
                        method = msg.get("method", "")
                        params_n = msg.get("params", {})
                        if "id" in msg:
                            continue  # response — skip
                        if method == "turn/completed":
                            status = params_n.get("turn", {}).get("status", "?")
                            if status in ("completed", "success"):
                                ok(f"turn/completed status={status} — LLM call succeeded")
                            else:
                                fail("turn/completed", f"status={status}")
                            break
                        if method == "error":
                            err_msg = (params_n.get("error") or {}).get("message", str(params_n.get("error")))
                            will_retry = params_n.get("willRetry", False)
                            if "/v1/responses" in str(err_msg):
                                got_404 = True
                                fail("turn/error", f"still hitting /v1/responses: {err_msg}")
                            elif not will_retry:
                                # Final error, no more retries
                                fail("turn/error (final)", err_msg)
                                break
                            else:
                                p("notif", {"method": method, "error": err_msg, "willRetry": will_retry})
                        else:
                            p("notif", msg)
                    except asyncio.TimeoutError:
                        continue
                if got_404:
                    fail("wire_api check", "404 /v1/responses still occurring — wire_api may not have taken effect")
                elif turn_started:
                    ok("wire_api check — no /v1/responses 404 observed")
        else:
            print("  [skip] turn/start skipped (thread not started or provider mismatch)")

        # ── Step 8: restore original model_provider ───────────────────────────
        # Always restore, even if original was None (JSON null removes the key).
        # Skip only if the config already had SMOKE_PROVIDER_ID selected before this run
        # (idempotent: writing the same value back is harmless but unnecessary noise).
        restore_value = original_model_provider  # None → JSON null → removes the key from toml
        restore_req = req("config/batchWrite", {
            "edits": [
                {
                    "keyPath": "model_provider",
                    "value": restore_value,
                    "mergeStrategy": "replace",
                }
            ],
            "reloadUserConfig": True,
        })
        p("sent", restore_req)
        await ws.send(json.dumps(restore_req))
        restore_resp = await recv_until_response(ws, restore_req["id"])
        if restore_resp and "result" in restore_resp:
            restored_display = repr(original_model_provider) if original_model_provider else "null (default — key removed)"
            ok(f"restored model_provider → {restored_display}")
        else:
            print(f"  [warn] restore model_provider failed: {restore_resp}")

    # ── Summary ───────────────────────────────────────────────────────────────
    _print_summary(
        steps_ok, steps_fail, blocker,
        has_real_config=True,
        written_model_provider=written_model_provider,
        runtime_provider=runtime_provider,
        expected_provider=SMOKE_PROVIDER_ID,
        original_model_provider=original_model_provider,
    )


def _print_summary(
    ok_list: List[str],
    fail_list: List[str],
    blocker: Optional[str],
    has_real_config: bool = True,
    written_model_provider: Optional[str] = None,
    runtime_provider: Optional[str] = None,
    expected_provider: Optional[str] = None,
    original_model_provider: Optional[str] = None,
) -> None:
    print("\n── summary ─────────────────────────────────────────")
    print(f"  passed : {len(ok_list)}")
    print(f"  failed : {len(fail_list)}")
    if blocker:
        print(f"  blocker: {blocker}")

    print()
    print("  config key names used (verified from source):")
    print(f"    model_providers.{SMOKE_PROVIDER_ID}  — custom provider entry (ModelProviderInfo)")
    print(f"    model_provider                       — active provider selector")

    if has_real_config:
        print()
        print("  config/read round-trip:")
        if written_model_provider == expected_provider:
            print(f"    ✓  model_provider written and read back as {written_model_provider!r}")
        else:
            print(f"    ✗  model_provider: written={expected_provider!r}, read back={written_model_provider!r}")

        print()
        print("  runtime effectiveness (thread/start → thread.modelProvider):")
        if runtime_provider == expected_provider:
            print(f"    ✓  runtime IS using the new provider: {runtime_provider!r}")
            print("       Conclusion: config/batchWrite + reloadUserConfig=true takes effect immediately.")
            print("       No app-server restart required for new threads.")
        elif runtime_provider is not None:
            print(f"    ✗  runtime still using: {runtime_provider!r}")
            print(f"       Expected: {expected_provider!r}")
            print("       Possible cause: reloadUserConfig did not propagate to new thread/start.")
            print("       Try: restart app-server and re-run to confirm if restart is required.")
        else:
            print("    —  thread/start did not complete (see blocker)")

        print()
        if original_model_provider is not None:
            print(f"  cleanup: model_provider restored to {original_model_provider!r}")
        else:
            print("  cleanup: model_provider set to null (key removed — default provider takes effect)")
        print(f"  note:    model_providers.{SMOKE_PROVIDER_ID} entry left in config.toml (harmless)")
        print("           Remove manually if not needed.")

    if not has_real_config:
        verdict = "SKIP (missing real providerBaseUrl)"
    elif not fail_list and runtime_provider == expected_provider:
        verdict = "PASS"
    elif not fail_list and runtime_provider != expected_provider:
        verdict = "PARTIAL PASS (config written but runtime provider mismatch)"
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
