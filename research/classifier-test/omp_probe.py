#!/usr/bin/env python3
"""Runs the zhengjian corpus through the installed `omp` and judges each answer.

`search.zig` measures the raw API; this measures the harness as configured,
system prompt, extensions and all. Same corpus, same judger, different
answerer — which is the comparison that matters when the question is whether
the *harness* keeps its answers grounded rather than whether the model does.

    python3 omp_probe.py --mode gate    # installed configuration
    python3 omp_probe.py --mode plain   # --no-extensions

Writes `omp-<mode>.json` beside the corpus and prints a tally.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import typing

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent.parent  # run1/
JUDGER_TIMEOUT = 300
OMP_TIMEOUT = 600


class Case(typing.TypedDict):
    id: str
    question: str
    rubric: str


class Corpus(typing.TypedDict):
    cases: list[Case]


class Verdict(typing.TypedDict):
    pass_: bool  # parsed from "pass", which is a Python keyword
    why: str


class Row(typing.TypedDict, total=False):
    id: str
    outcome: str
    answer: str
    why: str
    error: str


def parse_verdict(raw: str) -> Verdict:
    """Reads the judger's one-line JSON. Raises ValueError on anything else."""
    # `json.loads` is typed as returning `Any`; the check below is what makes
    # the cast true, so it has to come first.
    decoded: object = typing.cast(object, json.loads(raw.strip().splitlines()[-1]))
    if not isinstance(decoded, dict):
        raise ValueError(f"verdict is not an object: {raw[:200]}")
    fields = typing.cast("dict[str, object]", decoded)
    passed = fields.get("pass")
    why = fields.get("why")
    if not isinstance(passed, bool) or not isinstance(why, str):
        raise ValueError(f"verdict has the wrong shape: {raw[:200]}")
    return {"pass_": passed, "why": why}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    _ = parser.add_argument("--mode", choices=["gate", "plain"], default="gate")
    _ = parser.add_argument("--corpus", default=str(HERE / "corpus.json"))
    _ = parser.add_argument("--cwd", default="/tmp", help="where omp runs; long paths make it wander")
    _ = parser.add_argument("--only", default=None)
    return parser


def ask(question: str, cwd: str, mode: str) -> tuple[str, str]:
    """Returns (answer, error). The question is put to `omp -p`."""
    argv = ["omp", "-p", "--no-session"]
    if mode == "plain":
        argv.append("--no-extensions")
    argv.append(question)
    try:
        done = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=OMP_TIMEOUT)
    except subprocess.TimeoutExpired:
        return "", "timeout"
    answer = done.stdout.strip()
    if done.returncode != 0:
        return answer, f"exit {done.returncode}: {done.stderr.strip()[:200]}"
    return answer, ""


def judge(
    workdir: pathlib.Path, question: str, answer: str, rubric: str, tag: str
) -> tuple[bool | None, str]:
    """Returns (verdict, why); verdict is None when no judgement was obtained."""
    request = workdir / f"req-{tag}.json"
    _ = request.write_text(
        json.dumps({"question": question, "answer": answer, "rubric": rubric}, ensure_ascii=False),
        encoding="utf-8",
    )
    try:
        done = subprocess.run(
            ["zig", "build", "judge", "--", str(request), "--beta"],
            cwd=REPO,
            capture_output=True,
            text=True,
            timeout=JUDGER_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return None, "judger timeout"
    if done.returncode != 0:
        return None, f"judger exit {done.returncode}: {done.stdout.strip()[:200]}"
    try:
        verdict = parse_verdict(done.stdout)
    except (ValueError, IndexError, json.JSONDecodeError):
        return None, f"unparsable verdict: {done.stdout.strip()[:200]}"
    return verdict["pass_"], verdict["why"]


def main() -> int:
    args = build_parser().parse_args()

    corpus: Corpus = typing.cast(
        Corpus, json.loads(pathlib.Path(args.corpus).read_text(encoding="utf-8"))
    )
    cases: list[Case] = corpus["cases"]
    if args.only:
        cases = [case for case in cases if case["id"] == args.only]

    workdir = HERE / f"omp-{args.mode}-requests"
    workdir.mkdir(exist_ok=True)

    rows: list[Row] = []
    passed = failed = unjudged = 0
    for case in cases:
        answer, error = ask(case["question"], args.cwd, args.mode)
        if error:
            print(f"{case['id']:26} ASK FAILED  {error}")
            rows.append({"id": case["id"], "outcome": "ask_failed", "error": error})
            unjudged += 1
            continue
        verdict, why = judge(
            workdir, case["question"], answer, case["rubric"], f"{args.mode}-{case['id']}"
        )
        if verdict is None:
            unjudged += 1
            print(f"{case['id']:26} UNJUDGED    {why}")
            rows.append({"id": case["id"], "outcome": "unjudged", "answer": answer, "why": why})
            continue
        if verdict:
            passed += 1
        else:
            failed += 1
        print(f"{case['id']:26} {'pass' if verdict else 'FAIL'}  {why[:110]}")
        rows.append(
            {
                "id": case["id"],
                "outcome": "passed" if verdict else "failed",
                "answer": answer,
                "why": why,
            }
        )

    total = passed + failed
    print(f"\nmode={args.mode}  passed {passed}/{total}  failed {failed}  unjudged {unjudged}")
    out = HERE / f"omp-{args.mode}.json"
    _ = out.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {out}")
    return 0 if unjudged == 0 else 3


if __name__ == "__main__":
    sys.exit(main())
