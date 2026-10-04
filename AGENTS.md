# AGENTS.md

## The Python under `src/python/` is not the harness — do not use it

`src/python/harness1.py`, `src/python/loop.py` and `src/python/play.py` are a
scratch client kept for now. Do not import it, build on it, extend it, or copy
its API. The harness of record is the Zig under `src/`, reached through
`src/root.zig`: `src/remote/deepseek.zig` is the DeepSeek client. Any work that
needs a chat-completions client goes there, not here.

The only Python the build needs is `src/credentials.py`, which
`src/remote/keys.zig` runs to read omp's credential store. That is not the
scratch client and is not covered by this note.

## Experiments too: write small Zig programs, not Python

Even for a one-off experiment — probing the API, trying a field, checking what
the model does — write a small Zig program instead of reaching for Python. The
pattern is already here: `src/research/deepseek_playground.zig`, a scratch
program that is neither installed by the default build nor built with it, run
with `zig build deepseek_playground`, so `zig build` stays off the network and
builds only the harness. Add a scratch program beside it or a build step next to
that one. Do not use `src/python/` for experiments; its whole purpose is now
gone.

## Coding follows `skill://our-coding-style`

Writing, editing, refactoring, or reviewing code here means reading
`skill://our-coding-style` first. Its rule on comments applies: a comment must
carry a fact the code cannot — an external mapping, why an order matters, a
contract not visible in the signature — or it is deleted. And anything that can
be expressed in code — a constraint, an invariant, a value — is expressed in
code, not described.