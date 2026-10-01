"""Poke at the harness's DeepSeek client from Python.

    python3 src/python/play.py "why is the sky blue?"
    python3 src/python/play.py --thinking --effort high "17*23?"
    python3 src/python/play.py --tool "what is the weather in Kyoto?"
    python3 src/python/play.py --json "one sentence about the sea, as JSON"
    python3 src/python/play.py --no-stream --temperature 0.1 "name three primes"

The client is built from the Zig on the way in, whenever the Zig has changed,
so there is no build step to remember.

A scratch program, like `src/research/deepseek_playground.zig`: edit it. The
conversation is a `Deepseek`, which holds the messages, the tools, the client
and the fields of the request. Its fields are attributes — `model`, `thinking`,
`effort`, `max_tokens`, `temperature`, `top_p`, `stop`, `json_object`,
`tool_choice`, `logprobs`, `top_logprobs`, `user_id`, `stream_options` — and
`sea.run(...)` takes any of them as a keyword for that turn alone.

`--effort` is the API's `reasoning_effort`, one of the four levels that select
a thinking budget: none, low, high or max. It only means anything in thinking
mode, and thinking is on unless `--thinking` says otherwise. `--json` asks for
a JSON object.
"""

import argparse
from typing import Any

from harness1 import (
    AssistantMessage,
    Deepseek,
    SystemMessage,
    ToolMessage,
    chunk_reasoning,
    chunk_text,
)


def get_weather(city: str) -> str:
    """Report the weather in a city.

    A tool is a plain function: its name, this docstring and the annotation on
    `city` are the name, description and schema the model is offered.
    """
    return f"18 degrees and raining in {city}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompt", nargs="*", default=["Hello"], help="the user turn")
    parser.add_argument("--model", default="deepseek-flash")
    parser.add_argument("--tool", action="store_true", help="offer the weather tool")
    parser.add_argument("--thinking", action="store_true", help="keep the chain of thought, off here for speed")
    parser.add_argument("--effort", default=None, help="none, low, high or max")
    parser.add_argument("--json", action="store_true", help="ask for a JSON object back")
    parser.add_argument("--stop", default=None, help="stop at this sequence")
    parser.add_argument("--temperature", type=float, default=None)
    parser.add_argument("--max-tokens", type=int, default=None)
    parser.add_argument("--no-stream", action="store_true")
    arguments = parser.parse_args()

    sea = Deepseek(model=arguments.model, thinking=arguments.thinking)
    # None is "leave the field out", so every one of these can be assigned
    # whether or not it was given.
    sea.effort = arguments.effort
    sea.max_tokens = arguments.max_tokens
    sea.temperature = arguments.temperature
    sea.stop = arguments.stop
    sea.json_object = arguments.json

    if arguments.tool:
        sea.tool["get_weather"] = get_weather
    sea.append(SystemMessage("Be brief."))
    sea.append(" ".join(arguments.prompt))

    printing: str | None = None

    def on_chunk(chunk: dict[str, Any]) -> None:
        nonlocal printing
        for label, piece in (
            ("think", chunk_reasoning(chunk)),
            ("answer", chunk_text(chunk)),
        ):
            if not piece:
                continue
            if printing != label:
                print(f"\n[{label}] ", end="")
                printing = label
            print(piece, end="", flush=True)

    answer = sea.run(
        stream=not arguments.no_stream,
        on_chunk=None if arguments.no_stream else on_chunk,
    )
    if arguments.no_stream:
        if answer.get("reasoning_content"):
            print(f"[think] {answer['reasoning_content']}")
        print(f"[answer] {answer}")
    else:
        # Already printed, chunk by chunk, as it arrived.
        print()

    # A run that called tools left the calls and their answers in the
    # conversation; the answer printed above is only the turn after them.
    for message in sea.messages:
        if isinstance(message, ToolMessage) or (
            isinstance(message, AssistantMessage) and message.get("tool_calls")
        ):
            print(f"[{message['role']}] {message}")

    if sea.usage:
        print(
            f"\n{sea.usage['prompt_tokens']} prompt + {sea.usage['completion_tokens']} "
            f"completion = {sea.usage['total_tokens']} tokens"
        )


if __name__ == "__main__":
    main()
