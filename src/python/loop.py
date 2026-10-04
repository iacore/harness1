"""An agent loop in the shape of omp's, on top of harness1.

    python3 src/python/loop.py "what is the weather in Kyoto?"
    python3 src/python/loop.py --then "and in Oslo?" "what is the weather in Kyoto?"
    python3 src/python/loop.py --budget 2 "check the weather, the time, and the news"

`harness1.Deepseek.run()` is already a loop. This is the same loop written out,
because the interesting part of an agent harness is not running tools — it is
deciding when to stop. The shape is omp's `runLoop`
(`packages/agent/src/agent-loop.ts`), reduced to its mechanism:

  * a turn continues while it carries tool calls *and* ended for a reason that
    means the model is still working — omp's `hasMoreToolCalls = runnableStop
    && toolCalls.length > 0`;
  * the tools a turn asked for run, and their answers are appended;
  * a turn the API cut off at the token limit is the exception: its arguments
    may be half-written, so its calls are answered and not run;
  * when the agent is ready to stop, the queue is polled one last time before
    the run really ends, so a message that arrives as the agent finishes is not
    stranded until the next prompt.

Left out, because it is policy rather than mechanism: subagents, pause gates,
speculative execution, forced tool choice, compaction, and the eight different
ways omp bounds a run.
"""

import argparse
import time

from harness1 import RUNNABLE, Deepseek, ToolMessage, chunk_reasoning, chunk_text

# `RUNNABLE` is the client's own list — `tool_calls` and `stop`, which omp calls
# `toolUse` and `stop`. The loop below is what it is for.


def get_weather(city: str) -> str:
    """Report the weather in a city."""
    return f"18 degrees and raining in {city}"


def get_time(city: str) -> str:
    """Report the current local time in a city."""
    return f"{city} is at 21:40 local time"


def loop(agent, prompt=None, poll=None, budget=8, seconds=None, stream=True, on_chunk=None):
    """One run: from a prompt, through the turns its tools take it, to the
    point where the model answers without calling one.

    Returns `(the last turn, why it stopped)`. The reasons are the API's own
    `finish_reason` values, plus `deadline` and `budget` for the two bounds,
    which are the only things here that can end a run the model wanted to
    continue.

    `poll` is called for messages that arrive while the run is going: once
    before each turn, and once more when the agent is ready to stop. It is what
    omp's `getSteeringMessages` and `getFollowUpMessages` do, and it is the
    caller's to fill however it likes — a queue, an input prompt, a file.
    """
    poll = poll or (lambda: ())
    if prompt is not None:
        agent.append(prompt)
    deadline = None if seconds is None else time.monotonic() + seconds

    for _ in range(budget):
        if deadline is not None and time.monotonic() >= deadline:
            return agent[-1], "deadline"

        turn = agent.turn(stream=stream, on_chunk=on_chunk)
        reason = agent.stop_reason
        calls = turn.get("tool_calls") or []

        more = reason in RUNNABLE and len(calls) > 0

        if reason in ("error", "aborted"):
            # The provider stopped the turn. Nothing in it is worth running.
            return turn, reason

        if more:
            for call in calls:
                function = call["function"]
                print(f"\n[call] {function['name']}({function['arguments']})")
                answer = agent.run_tool(call)
                agent.append(answer)
                print(f"[tool] {answer}")
        elif calls:
            # The turn was stopped by something other than the model, so a call
            # in it may have half-written arguments. Answering each without
            # running it keeps the pairing the API insists on, and leaves the
            # model free to try again — which, after the token limit, is worth
            # another turn; after anything else, is not.
            for call in calls:
                agent.append(ToolMessage(f"not run: the turn ended on {reason}", call["id"]))
            more = reason == "length"

        if more:
            continue

        # The stop boundary. The queue is read *here*, when the agent would
        # otherwise be finished, and not before: a follow-up is something said
        # after the agent has answered, and reading the queue at the top of the
        # loop would fold it into the prompt that started the run instead. omp
        # polls its follow-up queue in this spot; its steering queue, for input
        # typed while the agent is still working, is polled every turn as well,
        # which is the one part of this left out.
        arrived = poll()
        agent.extend(arrived)
        if arrived:
            continue
        return turn, reason

    return agent[-1], "budget"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompt", nargs="*", default=["Hello"], help="what to ask first")
    parser.add_argument("--then", default=None, help="a follow-up handed over as the agent stops")
    parser.add_argument("--budget", type=int, default=8, help="the most model turns one run may take")
    parser.add_argument("--seconds", type=float, default=None, help="a deadline for the whole run")
    parser.add_argument("--no-stream", action="store_true")
    arguments = parser.parse_args()

    agent = Deepseek(thinking=False)
    agent.tool["get_weather"] = get_weather
    agent.tool["get_time"] = get_time

    waiting = [arguments.then] if arguments.then else []

    def poll():
        """The queue, which here is a list the script fills from the command
        line. A real harness polls a socket, a prompt or a file."""
        return [waiting.pop(0)] if waiting else []

    shown = None

    def render(chunk):
        nonlocal shown
        for label, piece in (("think", chunk_reasoning(chunk)), ("answer", chunk_text(chunk))):
            if not piece:
                continue
            if shown != label:
                print(f"\n[{label}] ", end="")
                shown = label
            print(piece, end="", flush=True)
        for choice in chunk.get("choices") or []:
            if choice.get("finish_reason"):
                shown = None  # the turn is over; the next one starts afresh

    turn, reason = loop(
        agent,
        " ".join(arguments.prompt),
        poll=poll,
        budget=arguments.budget,
        seconds=arguments.seconds,
        stream=not arguments.no_stream,
        on_chunk=render,
    )
    print()
    if arguments.no_stream:
        # Nothing printed it as it arrived.
        print(f"[answer] {turn}")

    print(f"\nstopped on {reason!r} after {len(agent)} turns")
    if agent.usage:
        print(
            f"{agent.usage['prompt_tokens']} prompt + {agent.usage['completion_tokens']} "
            f"completion = {agent.usage['total_tokens']} tokens on the last turn"
        )


if __name__ == "__main__":
    main()
