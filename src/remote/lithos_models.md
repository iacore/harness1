# LithosAI model constraints

What each model on the LithosAI roster does with the request fields the wire
format leaves open. Nothing here is in the client's types or validation — the
client checks only the bounds the vendor's OpenAPI reference states for every
request, and per-model behaviour is data, measured and written down here.

Roster rows: `GET /v1/models` publishes only `{id, object, created, owned_by}` —
no limits, tariffs or capabilities. So every constraint below comes from one of
three places, and each entry says which:

- **wire** — the vendor's OpenAPI reference (`docs.lithosai.com/openapi.yaml`,
  `info.version` 2026-09-17), the request schema's own field descriptions.
- **live** — measured against `api.lithosai.cloud` by `zig build --build-file ./build.research.zig lithos_probe`
  (section "Probe" below), on 2026-10-04.
- **console** — the vendor's Models page, as transcribed by the sibling
  `omp-custom` repo (`packages/catalog/src/compat/rules/providers/lithosai.kdl`),
  not re-verified by this harness.

Re-run `zig build --build-file ./build.research.zig lithos_probe` to refresh the **live** column. When a line
changes, update this file — the probe prints; it does not assert.

## Wire facts (every model)

- **Thinking control.** One field, `reasoning_effort`, takes two shapes:
  - a named effort: `none | minimal | low | medium | high | xhigh | max`;
  - a float budget in `[0, 0.99]`.

  Both are accepted for every roster model (**live**). An unknown string, or a
  budget above 0.99, is refused with HTTP 400 in the **engine** error shape,
  e.g. `reasoning_effort.constrained-float: Input should be less than or equal
  to 0.99`. `none` is the off switch, not a rung of the ladder.
- **Reasoning output.** `reasoning_content` on the message (and the streamed
  delta), and `completion_tokens_details.reasoning_tokens` in `usage`. Whether
  `none` actually empties them is per-model — see the table.
- **Errors** come in two shapes: the API's own `{error:{message,type,param,code}}`
  (e.g. an unknown model, or `n` on Kimi) and the inference engine's raw
  `{object:"error",message,type,param,code:<integer>}` passthrough (e.g. a
  rejected `top_p`). A body that is neither is plain text. `APIError.form`
  carries which one arrived.
- **Not implemented**: `/completions`, `/embeddings`, `/responses`, `/batches`
  answer 404.

## Tool calls and the `strict` flag

- **Function calling** is documented: `tools` and `tool_choice` on the request,
  `tool_calls`/`tool_call_id` on messages, `finish_reason: tool_calls`. The
  reference writes `tools.items` as a bare `type: object`, so it gives no
  function-object schema at all.
- **`strict` is undocumented but honored** (**live**, 2026-10-04, measured by
  `zig build --build-file ./build.research.zig lithos_strict` on `deepseek-ai/DeepSeek-V4.1-Flash`). The
  reference never names a `strict` field; sending one is accepted and changes
  decoding. A tool schema whose `city` is an `enum` of `["Paris"]`, prompted to
  report on Tokyo: with `strict: true` the arguments are `{"city":"Paris"}` —
  the decoder cannot emit the disallowed value — and with `strict: false` the
  same schema and prompt give `{"city":"Tokyo"}`. Stable over four runs. So
  `strict: true` compiles the schema into a decoding constraint, not merely
  advice.
- **But not OpenAI's strict rules.** OpenAI refuses a strict schema that omits
  `required` or `additionalProperties`, or sets `additionalProperties: true`;
  LithosAI accepted all three shapes at 200 with `strict: true`. It compiles
  whatever JSON Schema it is handed, so a caller who wants OpenAI's strict
  contract must still write it out — nothing enforces it server-side.
- Only `deepseek-ai/DeepSeek-V4.1-Flash` was probed; other roster rows are
  untested.

The client side is a plain flag: `chat.Function.strict` is `?bool` beside
`parameters`, a pre-encoded JSON Schema.

## Per-model (live, 2026-10-04)

`none` = does `reasoning_effort: "none"` switch thinking off (empty
`reasoning_content`, `reasoning_tokens` 0)? `top_p 0.5` = does the model accept
a `top_p` outside the OpenAI default band?

| model | `none` off? | `top_p 0.5` | notes |
| --- | --- | --- | --- |
| `deepseek-ai/DeepSeek-V4.1-Flash` | yes | accepted | |
| `deepseek-ai/DeepSeek-V4.1-Flash-fast` | yes | accepted | |
| `deepseek-ai/DeepSeek-V4.1-Flash-ultra` | yes | accepted | |
| `deepseek-ai/DeepSeek-V4.1-Flash-ultra-chat` | yes | accepted | `completion_tokens_details` is `null` |
| `zai-org/GLM-5.3` | **no** | accepted | ignores `none`; thinks anyway |
| `zai-org/GLM-5.3-Flash` | **no** | accepted | ignores `none`; thinks anyway |
| `zai-org/GLM-5.3-Flash-ultra` | **no** | accepted | ignores `none`; thinks anyway |
| `zai-org/GLM-5.3-Flash-ultra-chat` | **no** | accepted | ignores `none`; thinks anyway |
| `zai-org/GLM-5.3-ultra-chat` | **no** | accepted | ignores `none`; thinks anyway |
| `moonshotai/Kimi-K3` | yes | **refused 400** | |
| `moonshotai/Kimi-K3-fast` | yes | **refused 400** | |
| `moonshotai/Kimi-K3-ultra` | yes | **refused 400** | |
| `moonshotai/Kimi-K3-ultra-chat` | yes | accepted | `completion_tokens_details` is `null`; does not enforce the band |

### GLM-5.3 family — `reasoning_effort: "none"` is ignored (**live**)

Every GLM-5.3 deployment ignores the off switch: the API answers 200, no error,
with a non-empty `reasoning_content` and `reasoning_tokens` above zero. Asking
it not to think does not stop it. The DeepSeek and Kimi families honour `none`.

One run suggests the GLM ladder is not DeepSeek's: `low` emptied
`reasoning_content` (`reasoning_tokens` 1) while `none` produced the longest
trace. Not characterised further — one observation, not a rule.

### Kimi-K3 family — sampling is constrained (**wire**, **live**)

The OpenAPI request schema names three constraints, attributed to "prod-flagged
Kimi-K3 engines":

- `top_p` must be in `[0.95, 1.0]`. A lower value is refused with HTTP 400 in
  the **engine** shape: `top_p must be between 0.95 and 1.0 for this model; got
  0.5`.
- `n` must be `1`. `n: 2` is refused with the API's own envelope and
  `code: "unsupported_n"`, message `n must be 1`.
- `presence_penalty` and `frequency_penalty` must be `0.0`. A nonzero value is
  refused with an **engine** error: `presence_penalty must be 0.0 for this
  model; got 1.0`.

`moonshotai/Kimi-K3-ultra-chat` accepted `top_p: 0.5` (**live**), so whatever
"prod-flagged" selects does not include every Kimi id. The other three Kimi ids
enforce it.

## Limits and cost (**console**)

From the vendor's Models page via `omp-custom`; not re-verified here. Every row
is `context-window` 1,048,576 and `max-tokens` 1,048,576 — the output cap is the
context window, not DeepSeek's published 384K. The endpoint accepts any
`max_tokens` that fits (1,048,000 succeeded; 1,048,576 was rejected as exceeding
the window), so a request must bound output below the window itself.

Cost per million tokens (input / cache-read / output):

| model | input | cache-read | output |
| --- | --- | --- | --- |
| `deepseek-ai/DeepSeek-V4.1-Flash` | 0.15 | 0.003 | 0.60 |
| `deepseek-ai/DeepSeek-V4.1-Flash-fast` | 0.25 | 0.005 | 1.00 |
| `deepseek-ai/DeepSeek-V4.1-Flash-ultra` | 0.35 | 0.007 | 1.40 |
| `deepseek-ai/DeepSeek-V4.1-Flash-ultra-chat` | 0.35 | 0.007 | 1.40 |
| `zai-org/GLM-5.3` | 1.05 | 0.195 | 3.30 |
| `zai-org/GLM-5.3-Flash` | 0.30 | 0.06 | 1.00 |
| `zai-org/GLM-5.3-Flash-ultra` | 0.30 | 0.06 | 1.00 |
| `zai-org/GLM-5.3-Flash-ultra-chat` | 0.30 | 0.06 | 1.00 |
| `zai-org/GLM-5.3-ultra-chat` | 2.10 | 0.39 | 6.60 |
| `moonshotai/Kimi-K3` | 2.40 | 0.24 | 12.00 |
| `moonshotai/Kimi-K3-fast` | 4.00 | 0.40 | 20.00 |
| `moonshotai/Kimi-K3-ultra` | 5.60 | 0.56 | 28.00 |
| `moonshotai/Kimi-K3-ultra-chat` | 5.60 | 0.56 | 28.00 |

## Message roles beyond the six in the reference (**live**)

`zig build --build-file ./build.research.zig lithos_roles`
(`research/lithos_roles_probe.zig`) speaks raw HTTP, because the client's
`chat.Message` is a closed six-role union and cannot express a seventh.
Measured 2026-10-04 against `deepseek-ai/DeepSeek-V4.1-Flash`, with Kimi-K3 and
GLM-5.3 where noted.

The API layer validates `role` with a Pydantic discriminated union that names
**seven** values — one more than the OpenAPI enum
`[system, user, assistant, tool, function, developer]`:

> `'role' must be one of 'system', 'assistant', 'tool', 'function',
> 'developer', 'latest_reminder' (case-insensitive).; ... Input should be
> 'user'`

- **`latest_reminder`** — undocumented, accepted, and *rendered as an
  instruction*. A turn whose content is `The secret word is BANANA.`, followed
  by a user question, returns `BANANA` (two runs); `Always answer in French.`
  returns French. Honored on DeepSeek and `zai-org/GLM-5.3`; `moonshotai/Kimi-K3`
  rejects it (`Unknown message role 'latest_reminder'`, 400). It has **no stable
  precedence** over `system`: with the two carrying conflicting language
  instructions the answer went French twice and English once across three
  placements (reminder before/after system, both orders of the instruction).
- **Case-insensitivity is asymmetric.** The other six match case-insensitively
  (`SYSTEM`, `Assistant`, `Tool`, `Developer`, `LATEST_REMINDER`,
  `Latest_Reminder` all 200). `user` does not: `USER` and `User` are 400, as is
  `user ` (trailing space) and `user\t`.
- **`function` is unservable on DeepSeek.** Any `function` message — alone, with
  `name`, with `tool_call_id`, or followed by a user turn — answers
  `500 InternalServerError`. On Kimi-K3 the same message answers 400
  `Unknown message role 'function'`. Do not send it.
- **No open role surface.** `agent`, `model`, `human`, `bot`, `narrator`,
  `observation`, `critic`, `tool_result`, `system_prompt`, `prompt`, `ai`,
  `deepseek`, `root`, the empty string, non-ASCII, and non-string `role` values
  all 400. The seven are the whole set.
- **Extra fields are ignored, not role-checked.** `tool` without
  `tool_call_id`, `system` with a `tool_call_id`, and `user` with `tool_calls`
  are all accepted (200).
- **Shapes.** `messages` must be a non-empty array of objects: `[]`, a missing
  key, an object, `[null]`, and a string element all 400. `content` must be a
  string or an array of parts: a number, object, or `null` 400s; an unknown part
  `type` 400s. Parts on `system` are accepted. `user` with `content` omitted
  400s, but `content: ""` is accepted (200). A NUL inside content reaches the
  model as a space. Duplicate `role` keys in one object are accepted; the last
  wins.
- **Top-level.** Unknown keys are refused, not ignored: `agent_mode` → 400
  `unknown_parameter`. `n: 2` → 400 `unsupported_n` on DeepSeek as well as Kimi.
  `max_tokens: 0` is accepted despite the reference's `minimum: 1`, and returns
  an empty completion with `finish_reason: length`. An `image_url` part on
  `user` reaches an image loader: an unreachable URL gives 400
  `An exception occurred while loading IMAGE data at index 0: ... 404`.

The client models five, not the endpoint's seven. It gained
`Role.latest_reminder` and a `Message.latest_reminder` variant;
`lithos_test.zig` pins the wire name each encodes to. `developer` is not
modelled separately — the section below measures it as `system` under another
name — and `function` is left out because no model tested serves it.

## `system` versus `developer` (**live**)

`zig build --build-file ./build.research.zig lithos_sysdev`
(`research/lithos_sysdev_probe.zig`); 3 trials per case on
`deepseek-ai/DeepSeek-V4.1-Flash`, 2026-10-04. The discriminator is a codeword:
one turn names it (`ALPHA` or `BETA`), a later user turn asks for it, and the
answer says which turn the model read.

- **Both roles carry instructions and are obeyed wherever they sit.** `system`
  and `developer` each returned the codeword when placed first, when placed
  after a user turn, and even when placed *after* the question turn — a trailing
  instruction still steered the answer. Neither has a positional restriction.
- **They share one channel ordered by recency; there is no priority between
  them.** With `system`=ALPHA and `developer`=BETA both first, `[system,
  developer]` answered BETA and `[developer, system]` answered ALPHA — the later
  turn wins, whichever role it is, in both orders, 3/3 each.
- **Split across the conversation the rule holds but stops being
  deterministic.** `[system ALPHA, user, developer BETA, user]` answered BETA
  twice and ALPHA once; `[developer BETA, user, system ALPHA, user]` answered
  ALPHA 3/3. So "the last instruction wins" is the rule, with the older
  instruction leaking through occasionally.
- **No behavioural difference between the two was found on this model** — same
  rendering, same recency rule, same positions. The only `developer`-specific
  edge is at the API layer (its name folds case; only `user` must be exact), not
  in how the model weights it.

## Probe

`zig build --build-file ./build.research.zig lithos_probe` sends each roster model two requests — `reasoning_effort:
"none"` and `top_p: 0.5` — and prints `reasoning_tokens`, whether
`reasoning_content` was non-empty, the answer length and the finish reason. It is
a scratch program (`research/lithos_probe.zig`), neither installed nor built
by the default step.

`zig build --build-file ./build.research.zig lithos_strict` asks the endpoint about the `strict` flag
(`research/lithos_strict_probe.zig`): it sends a forced tool call whose
schema is varied against a prompt that contradicts it, and prints the returned
arguments.

`zig build --build-file ./build.research.zig lithos_roles` asks the message-shape
questions (`research/lithos_roles_probe.zig`): it POSTs hand-written bodies with
roles, content shapes, and top-level keys the typed client cannot express, and
checks each against the status recorded beside it in `cases` — the section above
as an executable list. A body that drifts from the record prints `CHANGED`; the
run ends with a count. Re-run it after touching the role set.

`zig build --build-file ./build.research.zig lithos_sysdev` asks the instruction
question (`research/lithos_sysdev_probe.zig`): it runs the codeword matrix —
`system` against `developer`, first against later — a fixed number of trials
each and prints every answer, since a single answer cannot separate a rule from
a sample.

The adapter itself (`src/remote/lithos.zig`) checks only the wire bounds every
request shares; the per-model rows above are deliberately not encoded there.