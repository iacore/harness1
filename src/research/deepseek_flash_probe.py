#!/usr/bin/env python3
"""One-shot probe: what deepseek-flash does with thinking disabled.

    python3 src/research/flash_probe.py            # every case, thinking off
    python3 src/research/flash_probe.py --mode high  # same cases, thinking on

The key is read the way the library reads it: DEEPSEEK_API_KEY first, then
omp's own store through the installed credentials helper. Prints one JSON
object per case on stdout.

Scratch, like the playground next to it: it takes no arguments worth keeping
and asserts nothing.
"""

import base64
import json
import os
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zlib

BASE = "https://api.deepseek.com"
MODEL = "deepseek-flash"


def api_key() -> str:
    key = os.environ.get("DEEPSEEK_API_KEY", "")
    if key:
        return key
    helper = "zig-out/lib/harness1/credentials.py"
    if os.path.exists(helper):
        done = subprocess.run(
            [sys.executable, helper, os.path.expanduser("~/.omp/agent/agent.db"), "deepseek"],
            capture_output=True,
            text=True,
        )
        if done.returncode == 0:
            return done.stdout.strip()
    raise SystemExit("no DeepSeek key")


def png(width: int, height: int, rgb: tuple[int, int, int]) -> str:
    """A solid-colour PNG as a data URI. Enough for the vision path to have
    something real to look at."""
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(tag: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))

    data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )
    return "data:image/png;base64," + base64.b64encode(data).decode()


def post(path: str, body: dict, key: str) -> tuple[int, dict]:
    request = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as failure:
        return failure.code, json.loads(failure.read() or b"{}")


def chat(key: str, mode: str, **body) -> dict:
    body = {"model": MODEL, "messages": body.pop("messages"), **body}
    if mode == "off":
        body["thinking"] = {"type": "disabled"}
    else:
        body["thinking"] = {"type": "enabled"}
        body["reasoning_effort"] = mode
    started = time.time()
    status, reply = post("/chat/completions", body, key)
    elapsed = round(time.time() - started, 2)
    if status != 200:
        return {"status": status, "error": reply.get("error", reply), "s": elapsed}
    choice = reply["choices"][0]["message"]
    usage = reply.get("usage") or {}
    details = usage.get("completion_tokens_details") or {}
    return {
        "status": status,
        "s": elapsed,
        "content": choice.get("content"),
        "reasoning": (choice.get("reasoning_content") or "")[:200] or None,
        "tool_calls": choice.get("tool_calls"),
        "finish": reply["choices"][0].get("finish_reason"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "reasoning_tokens": details.get("reasoning_tokens"),
    }


TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get the weather.",
            "parameters": {
                "type": "object",
                "properties": {"location": {"type": "string"}},
                "required": ["location"],
            },
        },
    }
]


def cases(key: str, mode: str) -> dict:
    out = {}

    out["arith"] = chat(
        key, mode, messages=[{"role": "user", "content": "What is 17*19? Answer with the number only."}]
    )
    out["multistep"] = chat(
        key,
        mode,
        messages=[
            {
                "role": "user",
                "content": "A bat and a ball cost 1.10 together. The bat costs 1.00 more than the ball. "
                "How much is the ball, in cents? Answer with the number only.",
            }
        ],
    )
    out["exact_shape"] = chat(
        key,
        mode,
        messages=[{"role": "user", "content": "Reply with exactly this and nothing else: OK"}],
        max_tokens=16,
    )
    out["json_mode"] = chat(
        key,
        mode,
        messages=[
            {"role": "system", "content": 'Answer as JSON: {"city": string, "population": integer}.'},
            {"role": "user", "content": "Lisbon."},
        ],
        response_format={"type": "json_object"},
    )
    out["tools_required"] = chat(
        key,
        mode,
        messages=[{"role": "user", "content": "What is the weather in Hangzhou?"}],
        tools=TOOLS,
        tool_choice="required",
    )
    out["tools_auto"] = chat(
        key,
        mode,
        messages=[{"role": "user", "content": "Say hello in one short sentence."}],
        tools=TOOLS,
    )
    out["stop"] = chat(
        key,
        mode,
        messages=[{"role": "user", "content": "Count from 1 upward, one number per line, no other text."}],
        stop=["3"],
        max_tokens=64,
    )
    out["vision"] = chat(
        key,
        mode,
        messages=[
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": png(64, 64, (220, 30, 30))}},
                    {"type": "text", "text": "Name the colour of this image in one word."},
                ],
            }
        ],
        max_tokens=32,
    )
    out["temperature_applied"] = chat(
        key,
        mode,
        messages=[{"role": "user", "content": "Write one sentence about the sea."}],
        temperature=0.0,
        top_p=0.5,
    )
    out["effort_conflict"] = chat(
        key,
        "off",
        messages=[{"role": "user", "content": "hi"}],
        reasoning_effort="high",
    )

    # FIM is documented as non-thinking only, through the beta root.
    started = time.time()
    status, reply = post(
        "/beta/completions",
        {
            "model": MODEL,
            "prompt": "def fib(a):\n",
            "suffix": "    return fib(a-1) + fib(a-2)\n",
            "max_tokens": 64,
            "thinking": {"type": "disabled"},
        },
        key,
    )
    out["fim"] = (
        {"status": status, "s": round(time.time() - started, 2), "text": reply["choices"][0]["text"]}
        if status == 200
        else {"status": status, "error": reply.get("error", reply)}
    )
    return out


def suite(key: str, modes: list[str]) -> None:
    """Checkable answers, one sample per mode. Small n: a run that differs is
    a lead to chase, not a rate."""

    def exact(*allowed: str):
        wanted = {a.lower() for a in allowed}

        def judge(text: str) -> str:
            got = text.strip().lower()
            return "ok" if got in wanted else f"MISS({text.strip()[:44]!r})"

        return judge

    def json_array(*wanted: str):
        def judge(text: str) -> str:
            try:
                got = json.loads(text)
            except ValueError:
                return "MISS(not json)"
            if not isinstance(got, list):
                return "MISS(not a list)"
            if {str(item).lower() for item in got} == {w.lower() for w in wanted}:
                return "ok" if text == json.dumps(list(wanted)) else "ok(loose)"
            return f"MISS({text[:44]!r})"

        return judge

    def run_python(text: str) -> str:
        body = text.strip().splitlines()[-1]
        source = "def largest(xs):\n" + ("    " + body if not body.strip().startswith("def") else body)
        try:
            namespace: dict = {}
            exec(source, namespace)  # scratch: the model's own text, run on purpose
        except Exception as broken:  # noqa: BLE001 - any failure is a miss
            return f"MISS({type(broken).__name__})"
        return "ok" if namespace["largest"]([3, 9, 4]) == 9 else "MISS(wrong answer)"

    tasks = [
        ("9.11 vs 9.8", "Which is greater, 9.11 or 9.8? Answer with the number only.", exact("9.8")),
        ("strawberry rs", "How many r's are in the word strawberry? Answer with the number only.", exact("3")),
        ("age arithmetic", "In 1990 a person was 15. What year were they 40? Answer with the year only.", exact("2015")),
        (
            "digit reverse",
            "Take 8147, reverse the digits, then subtract the smaller number from the larger. "
            "Answer with the number only.",
            exact("729"),
        ),
        ("weekday", "What weekday was 2026-10-01? Answer with the weekday only.", exact("thursday")),
        (
            "json extract",
            'Extract every email from this text as a JSON array of strings, nothing else: '
            '"write to a@b.co or cc@d.org, not e@f".',
            json_array("a@b.co", "cc@d.org"),
        ),
        (
            "python bug",
            "The function below is meant to return the largest element. Reply with only the corrected "
            "one-line body. def largest(xs): return xs[0]",
            run_python,
        ),
        ("modular", "What is 2^100 mod 1000? Answer with the number only.", exact("376")),
    ]
    for name, prompt, judge in tasks:
        for mode in modes:
            got = chat(key, mode, messages=[{"role": "user", "content": prompt}], max_tokens=2048)
            text = got.get("content") or ""
            verdict = judge(text) if text else f"MISS({got.get('status')})"
            print(
                f"{name:15} {mode:6} {verdict:22} {got.get('s')}s "
                f"{got.get('completion_tokens')} tok "
                f"({got.get('reasoning_tokens') or 0} reasoning)"
            )


def main() -> None:
    key = api_key()
    if "--suite" in sys.argv:
        suite(key, ["off", "high", "max"])
        return
    mode = "off"
    if "--mode" in sys.argv:
        mode = sys.argv[sys.argv.index("--mode") + 1]
    print(f"# mode={mode}", file=sys.stderr)
    print(json.dumps(cases(key, mode), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
