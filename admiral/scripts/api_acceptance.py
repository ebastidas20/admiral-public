# admiral/scripts/api_acceptance.py
"""Acceptance: a stock Anthropic SDK client against Admiral's endpoint.

Prereqs: Admiral dev build running, API Server toggled on (port 4141), and a
managed claude tab whose name you pass as --tab. No API token is required.
The Anthropic SDK still sends an API key; ADMIRAL_API_TOKEN is optional and Admiral ignores it.

    uv run --with anthropic python scripts/api_acceptance.py --tab "Worker"

The tab is routed by the required ADMIRAL_TAB_NAME header, sent here as an SDK
default header; `model` stays a real model id and is only echoed back.
"""
import argparse
import os
import anthropic

MODEL = "claude-opus-4-8"

parser = argparse.ArgumentParser()
parser.add_argument("--tab", required=True, help="Admiral tab name (the ADMIRAL_TAB_NAME header)")
parser.add_argument("--base-url", default="http://127.0.0.1:4141")
args = parser.parse_args()
TOKEN = os.environ.get("ADMIRAL_API_TOKEN", "unused")

client = anthropic.Anthropic(base_url=args.base_url, api_key=TOKEN, max_retries=0,
                             default_headers={"ADMIRAL_TAB_NAME": args.tab})

print("== non-streaming ==")
msg = client.messages.create(
    model=MODEL, max_tokens=1024,
    messages=[{"role": "user", "content": "Reply with exactly: PONG-1"}],
)
assert msg.model == MODEL, f"model should be echoed, not the tab: {msg.model}"
assert msg.role == "assistant" and msg.type == "message", msg
assert msg.stop_reason == "end_turn", msg.stop_reason
assert "PONG-1" in msg.content[0].text, msg.content[0].text
print(f"ok: {msg.content[0].text[:80]!r} usage={msg.usage.input_tokens}/{msg.usage.output_tokens}")

print("== streaming ==")
with client.messages.stream(
    model=MODEL, max_tokens=1024,
    messages=[
        {"role": "user", "content": "Reply with exactly: PONG-1"},   # already seen: delta skips it
        {"role": "assistant", "content": "PONG-1"},
        {"role": "user", "content": "Reply with exactly: PONG-2"},
    ],
) as stream:
    for text in stream.text_stream:
        print(text, end="", flush=True)
    final = stream.get_final_message()
print()
assert "PONG-2" in final.content[0].text, final.content[0].text
assert final.stop_reason == "end_turn"

print("== error shape ==")
try:
    client.messages.create(model=MODEL, max_tokens=16,
                           messages=[{"role": "user", "content": "x"}],
                           extra_headers={"ADMIRAL_TAB_NAME": "no-such-tab-xyz"})
    raise SystemExit("expected NotFoundError")
except anthropic.NotFoundError as e:
    print(f"ok: 404 not_found_error ({e.message[:60]})")

print("== header is required ==")
try:
    anthropic.Anthropic(base_url=args.base_url, api_key=TOKEN, max_retries=0).messages.create(
        model=MODEL, max_tokens=16, messages=[{"role": "user", "content": "x"}])
    raise SystemExit("expected BadRequestError when ADMIRAL_TAB_NAME is absent")
except anthropic.BadRequestError as e:
    print(f"ok: 400 invalid_request_error ({e.message[:60]})")

print("ALL ACCEPTANCE CHECKS PASSED")
