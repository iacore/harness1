# AGENTS.md

## The Python under `research/python/` is not the harness — do not use it

`research/python/harness1.py`, `research/python/loop.py` and
`research/python/play.py` are a scratch client kept for now. Do not import it,
build on it, extend it, or copy its API. The harness of record is the Zig under
`src/`, reached through `src/root.zig`: `src/remote/deepseek.zig` is the
DeepSeek client. Any work that needs a chat-completions client goes there,
not here.

The only Python the build needs is `src/remote/omp-keys.py`, which
`src/remote/keys.zig` runs to read omp's credential store. That is not the
scratch client and is not covered by this note.

## Experiments too: write small Zig programs, not Python

Even for a one-off experiment — probing the API, trying a field, checking what
the model does — write a small Zig program instead of reaching for Python. The
pattern is already here: `research/deepseek_playground.zig`, a scratch
program that is neither installed by the default build nor built with it, run
from the repository root with
`zig build --build-file ./build.research.zig deepseek_playground`, so `zig build`
stays off the network and builds only the harness. Add a scratch program beside
it, and its step to `build.research.zig`. That file imports `build.zig`, so use
its `harnessModule` and `installOmpKeys` rather than duplicating the module or
the credential install. Do not use `research/python/` for experiments; its whole
purpose is now gone.

## Coding follows `skill://our-coding-style`

Writing, editing, refactoring, or reviewing code here means reading
`skill://our-coding-style` first. Its rule on comments applies: a comment must
carry a fact the code cannot — an external mapping, why an order matters, a
contract not visible in the signature — or it is deleted. And anything that can
be expressed in code — a constraint, an invariant, a value — is expressed in
code, not described.

## AI notes

Measurements live beside the code that produced them:

- `research/deepseek-flash-non-thinking.dj` — what `deepseek-flash` does with
  thinking disabled, measured; re-run with `research/deepseek_flash_probe.py`.
- `research/classifier-test/findings.dj` — whether a system message can make the
  model stop passing off unattested wording as scripture (it cannot); the
  instruments and the sutra citations are beside it; re-run with
  `zig build --build-file ./build.research.zig search`.
- `src/remote/lithos_models.md` — what each LithosAI model does with
  `reasoning_effort: none` and the sampling band the Kimi-K3 ids enforce,
  measured; re-run with
  `zig build --build-file ./build.research.zig lithos_probe`, refresh the
  roster with `zig build --build-file ./build.research.zig lithos_models`.