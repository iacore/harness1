# AGENTS.md

## Commit after every stage of work

Commit the moment a stage is finished — a rename, a refactor, a probe, one file
— and commit frequently through a long sequence rather than batching it at the
end. Work left uncommitted is work the next edit can overwrite and a crash can
take; a change left in the working tree is not done, because the next reader
cannot see it and the next turn cannot build on it. This binds every agent that
works on run1: stop with the tree clean, and never leave a stage uncommitted for
the next one to build on.

## Fix what you see

Fix anything you feel like fixing, including a design, without asking first.
A defect left alone because it fell outside the request is still a defect the
next reader inherits. When the fix was not asked for, say what you changed and
why — but never ask whether you are allowed.

## Be precise over cheap

We will rather bust the prefix cache rather than let a running prompt see stale data. a hit is an
optimisation; a turn that no longer says what it said is a lie. the miss is
deliberate, and it is bounded by where the edit is — see `research/prompt-cache.dj`.

## Some words are defined in `research/terminology.dj`

`research/terminology.dj` fixes what `agent`, `prompt` and `last prompt` mean
here — an agent is a running prompt, a prompt is every chat turn visible to the
LithosAI API, the last prompt is the last turn — and carries the constraint that
every run1 agent on a machine shares a single Linux process group. Use the
words with those meanings, and add to that file rather than redefining them
elsewhere.

## Experiments too: write small Zig programs, not Python

Even for a one-off experiment — probing the API, trying a field, checking what
the model does — write a small Zig program instead of reaching for Python. The
pattern is already here: `research/deepseek_playground.zig`, a scratch
program that is neither installed by the default build nor built with it, run
from the repository root with
`zig build --build-file ./build.research.zig deepseek_playground`, so `zig build`
stays off the network and builds only the harness. Add a scratch program beside
it, and its step to `build.research.zig`. Every research program lives under
`research/` — never beside the code it probes, however close the tie (a probe of
`ui/kitty.zig` still goes in `research/`, importing it as a module). That file imports `build.zig`, so use
its `harnessModule` and `installOmpKeys` rather than duplicating the module or
the credential install. Do not use `research/python/` for experiments; its whole
purpose is now gone.

Zig's build is incremental and can watch: `--watch` (with `--build-file
./build.research.zig` for a research step) rebuilds and re-runs the step
whenever a source file changes — measured here: `zig build test --watch` ran the
step again after one `touch` of a source file — so a program being iterated on is
not re-invoked by hand. `--debounce <ms>` delays the rebuild. And for type errors
alone, `zls` answers without a build at all: check it is on PATH (`zls
--version`), and under omp ask the `lsp` tool for `diagnostics`.

## Coding follows `skill://our-coding-style`

Writing, editing, refactoring, or reviewing code here means reading
`skill://our-coding-style` first. Its rule on comments applies: a comment must
carry a fact the code cannot — an external mapping, why an order matters, a
contract not visible in the signature — or it is deleted. And anything that can
be expressed in code — a constraint, an invariant, a value — is expressed in
code, not described.

## Other notes

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