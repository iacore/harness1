"""A DeepSeek chat-completions client for experimenting with prompts.

    from harness1 import Deepseek, SystemMessage

    def get_weather(city: str) -> str:
        "Report the weather in a city."

    sea = Deepseek()                    # the key from the environment, or omp's
    sea.tool["get_weather"] = get_weather
    sea.append(SystemMessage("Be brief."))
    sea.append("What is the weather in Kyoto?")
    sea.run()                           # one turn, running tools until it stops
    print(sea[-1])

Plain Python over the API, stdlib only: `urllib` for the request, the API's own
JSON for everything else. A message is the API's message object, so nothing
here translates one shape into another. `Deepseek` is a conversation; `Client`
below it is one call at a time.

This is a scratch surface for trying prompts and agent loops out. The harness is
the Zig library under `src/` and it is run from harness rigs, not from here;
what the two share is the API key, read the way `src/env/omp.zig` reads it.
"""

from __future__ import annotations

import copy
import difflib
import http.client
import inspect
import json
import os
import subprocess
import sys
import types
import urllib.error
import urllib.request
from typing import (
    Any,
    Callable,
    Iterable,
    Iterator,
    Mapping,
    Union,
    cast,
    get_args,
    get_origin,
    get_type_hints,
    overload,
)

BASE_URL = "https://api.deepseek.com"

# The models the API serves, by the names it serves them under.
FLASH = "deepseek-flash"
V4_PRO = "deepseek-v4-pro"

_HERE = os.path.dirname(os.path.abspath(__file__))

# The request fields the API documents as no longer supported: "It will not
# take effect if you pass it to the API." It accepts them and does nothing with
# them, which is worse than refusing them, because a caller who sets one and
# gets an answer has no way to tell it was ignored. Nothing here sends them.
_DEPRECATED: tuple[str, ...] = ("frequency_penalty", "presence_penalty")


class Harness1Error(Exception):
    """A call that produced no completion."""


class APIError(Harness1Error):
    """The API's own error envelope, as a refusal.

    `status` is the HTTP status, and the rest is what the envelope said.
    """

    def __init__(self, status: int, envelope: dict[str, Any]) -> None:
        self.status = status
        self.type = envelope.get("type") or ""
        self.code = envelope.get("code") or ""
        self.param = envelope.get("param") or ""
        self.message = envelope.get("message") or ""
        named = "/".join(part for part in (self.type, self.code) if part)
        super().__init__(
            f"deepseek: HTTP {status}"
            + (f" {named}" if named else "")
            + (f" (param {self.param})" if self.param else "")
            + (f": {self.message}" if self.message else "")
        )


# ---------------------------------------------------------------------------
# The API key.
# ---------------------------------------------------------------------------


def api_key(provider: str = "deepseek", environment_variable: str = "DEEPSEEK_API_KEY") -> str | None:
    """The key for `provider`, by the rule `src/env/omp.zig` uses: the
    environment variable when it is set and non-empty, otherwise the credential
    omp stores, read by the helper that ships beside the harness. None when
    neither has one.

    The helper is run through this interpreter rather than `python3`, so a
    virtualenv or a system without `python3` on the PATH still reads the store.
    """
    value = os.environ.get(environment_variable)
    if value:
        return value

    helper = os.path.normpath(os.path.join(_HERE, "..", "credentials.py"))
    store = os.path.expanduser("~/.omp/agent/agent.db")
    if not (os.path.exists(helper) and os.path.exists(store)):
        return None

    answered = subprocess.run(
        [sys.executable, helper, store, provider],
        capture_output=True,
        text=True,
    )
    if answered.returncode != 0:
        return None
    return answered.stdout.strip() or None


# ---------------------------------------------------------------------------
# The messages.
# ---------------------------------------------------------------------------


class Message(dict[str, Any]):
    """One entry of the conversation, as the API's own object.

    It is the dict that goes on the wire, so nothing has to be converted; the
    fields read as attributes as well as keys, and printing one prints its
    text, which is what makes `print(sea[-1])` the answer.

    Nothing here enumerates the fields a message may carry, so the ones the
    subclasses below do not name — `name`, the optional participant name — are
    set on one as a key or an attribute: `message.name = "ada"` is
    `message["name"] = "ada"` is what the API receives.
    """

    def __getattr__(self, name: str) -> Any:
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name) from None

    def __setattr__(self, name: str, value: Any) -> None:
        self[name] = value

    def __str__(self) -> str:
        content = self.get("content")
        if isinstance(content, list):
            content = "".join(part.get("text") or "" for part in content if isinstance(part, dict))
        if isinstance(content, str) and content:
            return content
        # A turn that only called tools has no text of its own, and the calls
        # are what it has to show instead.
        if self.get("tool_calls"):
            return "\n".join(
                f"{call['function']['name']}({call['function']['arguments']})"
                for call in self["tool_calls"]
            )
        return ""

    def __repr__(self) -> str:
        return f"{type(self).__name__}({str(self)!r})"


class SystemMessage(Message):
    """The instruction that steers the model."""

    def __init__(self, content: str | list[dict[str, Any]]) -> None:
        super().__init__(role="system", content=content)


class UserMessage(Message):
    """Input from the caller: text, or a list of content parts."""

    def __init__(self, content: str | list[dict[str, Any]]) -> None:
        super().__init__(role="user", content=content)


class AssistantMessage(Message):
    """A model turn: its text, the chain of thought behind it, the calls it
    asked for, and — under the Beta root — a prefix to start its answer with.

    `reasoning_content` is absent when the turn had no chain of thought and a
    string, possibly empty, when it did. The difference matters: the API wants
    the field back on a tool-calling turn, and a model that calls a tool
    without thinking answers with an empty one.
    """

    def __init__(
        self,
        content: str = "",
        reasoning_content: str | None = None,
        tool_calls: list[dict[str, Any]] | None = None,
        prefix: bool = False,
    ) -> None:
        super().__init__(role="assistant", content=content)
        if reasoning_content is not None:
            self["reasoning_content"] = reasoning_content
        if tool_calls:
            self["tool_calls"] = list(tool_calls)
        if prefix:
            self["prefix"] = True


class ToolMessage(Message):
    """The answer to one call, which the turn after it runs with."""

    def __init__(self, content: str, tool_call_id: str = "") -> None:
        super().__init__(role="tool", content=content, tool_call_id=tool_call_id)


def _api_message(payload: dict[str, Any]) -> Message:
    """One of the API's message objects as a `Message`.

    A tool call's `index` is left out. It numbers the fragments a call arrives
    in, which is a streamed delta's business; a call that is sent back is the
    id, the type and the function. What a turn holds then reads the same
    whether the answer was streamed or not, and what it holds is what can go
    back out.
    """
    message = Message(payload)
    if message.get("tool_calls"):
        message["tool_calls"] = [
            {name: value for name, value in call.items() if name != "index"}
            for call in message["tool_calls"]
        ]
    return message


def as_message(value: Message | str | dict[str, Any]) -> Message:
    """Whatever the caller had, as a `Message`: a Message as it stands, a
    string as the user turn it reads as, a dict as the message it describes."""
    if isinstance(value, Message):
        return value
    if isinstance(value, str):
        return UserMessage(value)
    if isinstance(value, dict):
        return Message(value)
    raise TypeError(f"not a message: {value!r}")


# ---------------------------------------------------------------------------
# The tools.
# ---------------------------------------------------------------------------

_PRIMITIVES: dict[type, dict[str, Any]] = {
    str: {"type": "string"},
    int: {"type": "integer"},
    float: {"type": "number"},
    bool: {"type": "boolean"},
    list: {"type": "array"},
    dict: {"type": "object"},
    type(None): {"type": "null"},
}


def _schema_for(annotation: Any) -> dict[str, Any]:
    """The schema for one parameter. Anything the annotations do not describe
    is left open, which is the schema that accepts anything."""
    if annotation in (inspect.Parameter.empty, Any):
        return {}
    origin = get_origin(annotation)
    if origin in (Union, types.UnionType):
        # `X | None` is still X — the null is how a caller leaves it out.
        members = [member for member in get_args(annotation) if member is not type(None)]
        if len(members) == 1:
            return _schema_for(members[0])
        return {"anyOf": [_schema_for(member) for member in members]}
    if origin is list:
        members = get_args(annotation)
        return {"type": "array", "items": _schema_for(members[0])} if members else {"type": "array"}
    if origin is dict:
        return {"type": "object"}
    return _PRIMITIVES.get(annotation, {})


def schema(fn: Callable[..., Any]) -> dict[str, Any]:
    """A JSON Schema object for a function's arguments, read off its
    annotations. A parameter that has none accepts anything."""
    try:
        hints = get_type_hints(fn)
    except Exception:
        # A callable whose annotations cannot be resolved — a lambda over names
        # that are gone, a builtin — is still callable, just not describable.
        hints = {}
    properties = {}
    required = []
    for name, parameter in inspect.signature(fn).parameters.items():
        if parameter.kind in (parameter.VAR_POSITIONAL, parameter.VAR_KEYWORD):
            continue
        properties[name] = _schema_for(hints.get(name, parameter.annotation))
        if parameter.default is parameter.empty:
            required.append(name)
    return {"type": "object", "properties": properties, "required": required}


def _first_line(docstring: str | None) -> str:
    for line in (docstring or "").splitlines():
        if line.strip():
            return line.strip()
    return ""


class Tool:
    """A function the model may call.

    The name it is offered under, the description it picks it by and the schema
    it fills in are all read off the function — its `__name__`, the first line
    of its docstring, its annotated parameters. Pass `name=`, `description=` or
    `parameters=` to say any of them yourself.
    """

    def __init__(
        self,
        fn: Callable[..., Any],
        name: str | None = None,
        description: str | None = None,
        parameters: dict[str, Any] | None = None,
        strict: bool = False,
    ) -> None:
        self.fn = fn
        self.name = name or getattr(fn, "__name__", "tool")
        self.description = description if description is not None else _first_line(fn.__doc__)
        self.parameters = parameters if parameters is not None else schema(fn)
        self.strict = strict

    def call(self, arguments: str | None) -> Any:
        """Runs the tool on the JSON text the model sent."""
        kwargs = json.loads(arguments) if arguments and arguments.strip() else {}
        return self.fn(**kwargs)

    def to_json(self) -> dict[str, Any]:
        function = {"name": self.name}
        if self.description:
            function["description"] = self.description
        # The schema is the object it is, not text: this goes to the wire
        # directly and there is no encoder in between to have an opinion.
        function["parameters"] = self.parameters
        if self.strict:
            function["strict"] = True
        return {"type": "function", "function": function}

    def __repr__(self) -> str:
        return f"Tool({self.name!r})"


class Tools(dict[str, Tool]):
    """The tools the model is offered, by the name it calls them by:

        sea.tool["get_weather"] = get_weather

    The key is the name, whether or not it is also the function's own. A value
    that is not a `Tool` is wrapped into one, so a plain function is enough.
    """

    def __init__(self, tools: Mapping[str, Tool | Callable[..., Any]] | None = None) -> None:
        # Not `dict.__init__`: that stores what it is given without going
        # through `__setitem__`, and so without wrapping anything.
        super().__init__()
        for name, tool in (tools or {}).items():
            self[name] = tool

    def __setitem__(self, name: str, tool: Tool | Callable[..., Any]) -> None:
        if not isinstance(tool, Tool):
            tool = Tool(tool)
        tool.name = str(name)
        super().__setitem__(str(name), tool)

    def to_json(self) -> list[dict[str, Any]]:
        return [tool.to_json() for tool in self.values()]


# ---------------------------------------------------------------------------
# The transport.
# ---------------------------------------------------------------------------


def _post(
    url: str, key: str, body: dict[str, Any], stream: bool, timeout: float
) -> http.client.HTTPResponse:
    request = urllib.request.Request(
        url,
        data=json.dumps(body, ensure_ascii=False).encode(),
        headers={
            "authorization": f"Bearer {key}",
            "content-type": "application/json",
            **({"accept": "text/event-stream"} if stream else {}),
        },
    )
    # `urlopen` is declared to return `Any`; for an http(s) URL what it hands
    # back is the response the rest of this file reads, so that is said once
    # here rather than assumed at every use.
    return cast(http.client.HTTPResponse, urllib.request.urlopen(request, timeout=timeout))


def _envelope(error: urllib.error.HTTPError) -> dict[str, Any]:
    """The API's error object out of a failed response. A body that is not one
    stands as the message, which is better than losing it."""
    text = error.read().decode("utf-8", "replace")
    try:
        return json.loads(text)["error"]
    except Exception:
        return {"message": text.strip()}


def _events(response: Iterable[bytes]) -> Iterator[dict[str, Any]]:
    """The payload of each server-sent event, in order, up to the sentinel the
    API ends a stream with. Comment lines such as `: keep-alive` are ignored."""
    for line in response:
        line = line.decode("utf-8", "replace").rstrip("\r\n")
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if not data:
            continue
        if data == "[DONE]":
            return
        yield json.loads(data)


class Client:
    """One API root, authenticated.

    `chat` sends one request and returns the completion; `stream` yields the
    chunks of one as they arrive. The keywords are the API's own request
    fields, verbatim — `messages`, `model`, `thinking`, `reasoning_effort`,
    `max_tokens`, `response_format`, `stop`, `temperature`, `top_p`, `tools`,
    `tool_choice`, `logprobs`, `top_logprobs`, `user_id` — so nothing here has
    to be kept in step with a list of them. Two of them are not the API's own:
    `thinking` may also be given as a bool, which is what a caller means by it,
    and the two fields the API no longer supports — `frequency_penalty` and
    `presence_penalty` — are refused rather than sent to be ignored.
    """

    def __init__(
        self,
        key: str | None = None,
        base_url: str | None = None,
        beta: bool = False,
        model: str = FLASH,
        timeout: float = 600,
    ) -> None:
        resolved = key if key is not None else api_key()
        if not resolved:
            raise Harness1Error(
                "no DeepSeek key: pass key=, or set DEEPSEEK_API_KEY, or sign "
                "in to omp's `deepseek` provider"
            )
        self.key: str = resolved
        self.model: str = model
        self.url: str = (base_url or BASE_URL).rstrip("/") + ("/beta" if beta else "")
        self.timeout: float = timeout

    def chat(self, **request: Any) -> dict[str, Any]:
        """Sends one request and returns the completion, as the API shaped it.

        `choices` is a list because this API is OpenAI-compatible and OpenAI's
        takes an `n`, answering with one completion per `n`. This one does not:
        it has no `n` to set and refuses one sent anyway — "Invalid n value
        (currently only n = 1 is supported)" — so there is one choice, at index
        0, and `completion["choices"][0]["message"]` is the message. That
        message is already a `Message`, so a caller can read its fields or
        print it.
        """
        with self._open(request, stream=False) as response:
            completion = json.load(response)
        for choice in completion.get("choices") or []:
            if isinstance(choice.get("message"), dict):
                choice["message"] = _api_message(choice["message"])
        return completion

    def stream(self, **request: Any) -> Iterator[dict[str, Any]]:
        """Sends one request and yields the chunks of the answer as they
        arrive, the API's own `chat.completion.chunk` objects."""
        with self._open(request, stream=True) as response:
            yield from _events(response)

    def _open(self, request: dict[str, Any], stream: bool) -> http.client.HTTPResponse:
        body = dict(request)
        for name in _DEPRECATED:
            if name in body:
                raise Harness1Error(
                    f"{name} is deprecated: the API accepts it and does nothing "
                    "with it, so sending it would change nothing"
                )
        body.setdefault("model", self.model)
        if isinstance(body.get("thinking"), bool):
            # The API takes `{"type": ...}` here and a caller means the bool.
            body["thinking"] = {"type": "enabled" if body["thinking"] else "disabled"}
        if stream:
            body["stream"] = True
        try:
            return _post(self.url + "/chat/completions", self.key, body, stream, self.timeout)
        except urllib.error.HTTPError as error:
            raise APIError(error.code, _envelope(error)) from None


# ---------------------------------------------------------------------------
# Reading an answer.
# ---------------------------------------------------------------------------


def chunk_text(chunk: dict[str, Any]) -> str:
    """The text one streamed chunk adds; "" for the chunks that only carry a
    role, a finish reason or the tool calls."""
    for choice in chunk.get("choices") or []:
        delta = choice.get("delta") or {}
        content = delta.get("content")
        if isinstance(content, str) and content:
            return content
    return ""


def chunk_reasoning(chunk: dict[str, Any]) -> str:
    """The chain of thought one streamed chunk adds."""
    for choice in chunk.get("choices") or []:
        delta = choice.get("delta") or {}
        thought = delta.get("reasoning_content")
        if isinstance(thought, str) and thought:
            return thought
    return ""


# ---------------------------------------------------------------------------
# The conversation.
# ---------------------------------------------------------------------------

# The request fields a conversation can be set to, by the name it calls them;
# `_field` maps each onto the API's own name and shape. Every field the
# endpoint takes is here but five: `messages`, `stream` and `tools`, which the
# conversation carries or the call sets rather than the caller setting an
# attribute, and the two in `_DEPRECATED`, which nothing here sends.
#
# The list is the one at
# https://api-docs.deepseek.com/api/create-chat-completion
# read on 2026-10-01. What each value may be was checked against the live API
# the same day, which is how `reasoning_effort` came to be known to accept
# `ultra` — a value that page does not list — and how `tool_choice` was found
# to refuse a bare function name where the object is what it wants.
_SETTINGS: tuple[str, ...] = (
    "model",
    "thinking",
    "effort",
    "max_tokens",
    "temperature",
    "top_p",
    "stop",
    "json_object",
    "tool_choice",
    "logprobs",
    "top_logprobs",
    "user_id",
    "stream_options",
)

# What a `Deepseek` keeps for itself rather than sending.
_OWN: frozenset[str] = frozenset({"client", "messages", "tool", "usage", "settings", "stop_reason"})

# The three values `tool_choice` takes as a bare string. Anything else given
# there is the name of a function, which the API takes as an object.
_TOOL_CHOICES: tuple[str, ...] = ("none", "auto", "required")

# The thinking levels: the ones that select a budget, and only those. `none`
# turns thinking off rather than lowering it; `low`, `high` and `max` are the
# budgets, of which `high` is the default and `max` is the one that also raises
# the default `max_tokens` to 128K.
_LEVELS: tuple[str, ...] = ("none", "low", "high", "max")

# Other clients spell some of those levels differently, and the API takes their
# spellings and maps them onto one of the four. They are not levels here — they
# select no budget of their own — so one is refused with the level it stands
# for, which is what a caller needs to fix it.
_SPELLINGS: dict[str, str] = {
    "minimal": "low",
    "medium": "high",
    "xhigh": "high",
    "ultra": "max",
}

# The finish reasons whose tool calls are the model still working: `tool_calls`
# is a turn with work in it, and `stop` is the model deciding it is finished —
# which it is not, if it also called something. Everything else — `length`,
# `content_filter`, `insufficient_system_resource`, `aborted` — is the model
# being stopped by something other than itself, and the calls in such a turn
# are answered rather than run: the arguments of a turn cut off at the token
# limit may be half-written, and a turn the provider ended is not one to take
# side effects from.
RUNNABLE: tuple[str, ...] = ("tool_calls", "stop")


def _not_a_setting(name: str) -> str:
    """Why a name is not one of the request's fields, and what they are. The
    near miss is worth naming: a typo here is a turn that quietly goes out
    without the field it was supposed to carry."""
    if name in _DEPRECATED:
        return (
            f"{name!r} is deprecated: the API accepts it and does nothing with "
            "it, so there is nothing here to set"
        )
    close = difflib.get_close_matches(name, _SETTINGS, n=1)
    hint = f", did you mean {close[0]!r}?" if close else "."
    return f"{name!r} is not a field of a chat completion{hint} The fields are {', '.join(_SETTINGS)}"


def _level(value: str) -> str:
    """A thinking level, or why the name given is not one."""
    if value in _LEVELS:
        return value
    stands_for = _SPELLINGS.get(value)
    if stands_for is not None:
        raise ValueError(
            f"{value!r} is not a thinking level: it is {stands_for!r}, spelled "
            "the way another client spells it"
        )
    raise ValueError(f"{value!r} is not a thinking level: they are {', '.join(_LEVELS)}")


def _field(name: str, value: Any) -> tuple[str, Any]:
    """The API's field for a setting, and its value in the shape the API takes.

    Five of them differ from the API's own spelling. `effort` is
    `reasoning_effort`; `json_object` is the one value of `response_format`
    worth a flag; `thinking` is a `{"type": ...}` and not a bool; `stop` is one
    sequence or several; and `tool_choice` takes its three modes as bare
    strings and a named function as an object, so a name given bare is one and
    is sent as the object the API asks for — it refuses `"get_weather"` where
    it takes `{"type": "function", "function": {"name": "get_weather"}}`.
    """
    if name == "thinking":
        return "thinking", None if value is None else {"type": "enabled" if value else "disabled"}
    if name == "effort" and value is not None:
        return "reasoning_effort", _level(value)
    if name == "json_object":
        return "response_format", {"type": "json_object"} if value else None
    if name == "stop" and isinstance(value, str):
        return "stop", [value]
    if name == "tool_choice" and isinstance(value, str) and value not in _TOOL_CHOICES:
        return "tool_choice", {"type": "function", "function": {"name": value}}
    return name, value


class Turn:
    """The message a streamed turn adds up to.

    A stream gives back what the answer is made of rather than the answer: the
    text and the chain of thought in pieces, and the arguments of each tool
    call in fragments. A conversation has to hold the whole of it before the
    next turn can be asked, and the API wants the calls whole when they are
    sent back. The tokens billed and the reason the model stopped arrive on the
    last chunk, and are held here too.
    """

    def __init__(self) -> None:
        self.message: AssistantMessage = AssistantMessage()
        self.usage: dict[str, Any] | None = None
        self.finish_reason: str | None = None
        self._thought: str | None = None
        self._calls: dict[int, dict[str, Any]] = {}

    def add(self, chunk: dict[str, Any]) -> Turn:
        if chunk.get("usage"):
            self.usage = chunk["usage"]
        for choice in chunk.get("choices") or []:
            if choice.get("finish_reason"):
                self.finish_reason = choice["finish_reason"]
            delta = choice.get("delta") or {}
            if delta.get("content"):
                self.message["content"] += delta["content"]
            # A chunk that carries the field at all carries a chain of thought,
            # empty or not, and the API wants that back on a tool-calling turn.
            # A chunk that carries null — every chunk of the answer that
            # follows the thinking — does not.
            if delta.get("reasoning_content") is not None:
                self._thought = (self._thought or "") + delta["reasoning_content"]
            for call in delta.get("tool_calls") or []:
                slot = self._calls.setdefault(
                    call.get("index") or 0,
                    {"id": "", "type": "function", "function": {"name": "", "arguments": ""}},
                )
                if call.get("id"):
                    slot["id"] = call["id"]
                function = call.get("function") or {}
                if function.get("name"):
                    slot["function"]["name"] = function["name"]
                if function.get("arguments"):
                    slot["function"]["arguments"] += function["arguments"]
        return self

    def result(self) -> AssistantMessage:
        if self._thought is not None:
            self.message["reasoning_content"] = self._thought
        if self._calls:
            self.message["tool_calls"] = [call for _, call in sorted(self._calls.items())]
        return self.message


class Deepseek:
    """A conversation and the client that runs it.

    The fields of the request are the conversation's own attributes, under the
    names it calls them by — `model`, `thinking`, `effort` (the API's
    `reasoning_effort`), `max_tokens`, `temperature`, `top_p`, `stop`,
    `json_object`, `tool_choice`, `logprobs`, `top_logprobs`, `user_id`,
    `stream_options`:

        sea = Deepseek()
        sea.effort = "high"            # none, low, high, max
        sea.stop = "END"               # one sequence, or a list of up to 16
        sea.effort = None              # back to what the API does by itself

    `thinking` is True, False, or unset for the API's own default, which is
    thinking on; `effort` only means anything in thinking mode, where it is one
    of the four levels that select a budget — `none` turns thinking off, and
    `low`, `high` and `max` are the budgets. The spellings other clients use
    for those levels are not levels here, and are refused with the one each
    stands for, which is what to set instead. Any of the fields as a keyword of
    `run` applies to that turn alone and leaves the attribute as it was.
    `request()` shows the body a `run` would send, without sending it.

    `tool_choice` is `"none"`, `"auto"`, `"required"`, a function's name, or
    the object the API takes for one. Note that `required` and a named function
    are not choices the model may decline: they apply to every turn of a run,
    so it has to call that tool on each of them and `run` will spend `steps`
    doing so. Give it to one turn — `turn(..., tool_choice=...)` — or clear it
    when it has done its job.

    A turn that asks for tools runs them before returning, and so does every
    turn after it that asks for more, until the model answers without asking.
    A tool that raises is not an error here: what it said goes back as the
    tool's answer, for the model to correct.

    A name that is neither a field nor one of `client`, `messages`, `tool`,
    `usage` or `settings` is a typo, and is refused as one.
    """

    def __init__(
        self,
        key: str | None = None,
        base_url: str | None = None,
        beta: bool = False,
        tools: Mapping[str, Tool | Callable[..., Any]] | None = None,
        **settings: Any,
    ) -> None:
        self.settings: dict[str, Any] = {}
        self.messages: list[Message] = []
        self.tool: Tools = Tools(tools or {})
        # What the last turn reported: the tokens it was billed for, and the
        # API's `finish_reason` for why the model stopped.
        self.usage: dict[str, Any] | None = None
        self.stop_reason: str | None = None

        self.model: str = settings.pop("model", FLASH)
        for name, value in settings.items():
            setattr(self, name, value)
        self.client = Client(key=key, base_url=base_url, beta=beta, model=self.model)

    # -- the request fields -------------------------------------------------

    def __setattr__(self, name: str, value: Any) -> None:
        if name in _SETTINGS:
            field, wanted = _field(name, value)
            if wanted is None:
                # None is Python for "leave the field out", which is how a
                # setting goes back to whatever the API does by itself.
                self.settings.pop(field, None)
            else:
                self.settings[field] = wanted
        elif name in _OWN:
            super().__setattr__(name, value)
        else:
            raise AttributeError(_not_a_setting(name))

    def __getattr__(self, name: str) -> Any:
        # Only reached when the ordinary lookup found nothing, so this is a
        # field nobody has set, or a name that is not a field at all.
        if name.startswith("_"):
            raise AttributeError(name)
        if name in _SETTINGS:
            field, _ = _field(name, True)
            return self.settings.get(field)
        raise AttributeError(_not_a_setting(name))

    # -- the conversation ---------------------------------------------------

    def append(self, message: Message | str | dict[str, Any]) -> Message:
        """Adds one turn — a `Message`, a string (a user turn), or the API's
        own message object — and returns it."""
        message = as_message(message)
        self.messages.append(message)
        return message

    def extend(self, messages: Iterable[Message | str | dict[str, Any]]) -> list[Message]:
        """Adds several turns, and returns them."""
        return [self.append(message) for message in messages]

    def clone(self, **settings: Any) -> Deepseek:
        """A second conversation at the same point: the same turns, tools and
        settings, with a history of its own from here on.

            first = Deepseek()
            first.run("Write one line about the sea.")
            bolder = first.clone(temperature=1.0)
            bolder.run("Say it again, differently.")

        The turns are copied, so appending to one does not add to the other,
        and so does the usage of the last turn. The tools and the client are
        shared — a clone does not read the API key again — and the settings
        given here override the ones the conversation was running under.
        """
        twin = Deepseek.__new__(Deepseek)
        twin.settings = copy.deepcopy(self.settings)
        twin.messages = [copy.deepcopy(message) for message in self.messages]
        twin.tool = Tools(self.tool)
        twin.usage = copy.deepcopy(self.usage)
        twin.stop_reason = self.stop_reason
        twin.client = self.client
        for name, value in settings.items():
            setattr(twin, name, value)
        return twin

    @overload
    def __getitem__(self, index: int) -> Message: ...

    @overload
    def __getitem__(self, index: slice) -> list[Message]: ...

    def __getitem__(self, index: int | slice) -> Message | list[Message]:
        return self.messages[index]

    def __delitem__(self, index: int | slice) -> None:
        """Drops a turn, or a slice of them.

        A request carries the whole conversation and nothing else, so a turn
        that is gone from here is a turn the model will not have seen next time
        it is asked. Dropping the answer and running the same conversation
        again is how a turn is asked for twice; `run()` takes no prompt for
        that, since a prompt would be another turn on top of it:

            sea.run("Write one line about the sea.")
            del sea[-1]                     # not that one
            sea.run()                       # the same question, again
        """
        del self.messages[index]

    def __len__(self) -> int:
        return len(self.messages)

    def __iter__(self) -> Iterator[Message]:
        return iter(self.messages)

    def __repr__(self) -> str:
        fields = ", ".join(f"{name}={value!r}" for name, value in sorted(self.settings.items()))
        return f"Deepseek({fields}, {len(self.messages)} messages)"

    # -- running ------------------------------------------------------------

    def request(self, **settings: Any) -> dict[str, Any]:
        """The body the next `run` would send, as the dict it would be written
        from. Takes the same keywords as `run`."""
        return self._body(settings)

    def run(
        self,
        prompt: Message | str | dict[str, Any] | None = None,
        steps: int = 8,
        stream: bool = False,
        on_chunk: Callable[[dict[str, Any]], None] | None = None,
        **settings: Any,
    ) -> Message:
        """Runs one turn, and the turns of any tools it calls, until the model
        answers without calling one. Returns that answer, which is also the
        last message appended.

        `steps` bounds how many model turns that may take, and raises when the
        model is still calling tools at the end of them. `stream` reads each
        turn as it arrives rather than waiting for it, handing every chunk to
        `on_chunk`.

        This is one policy of several; `turn` and `run_tool` are the two
        pieces to write another with. It turns on `RUNNABLE`: a call is run
        only when the turn that asked for it ended because the model was still
        working. A turn stopped by the token limit gets another turn instead,
        so the model can pick up where it was cut off; a turn stopped by
        anything else ends the run.
        """
        if prompt is not None:
            self.append(prompt)
        for _ in range(steps):
            answer = self.turn(stream=stream, on_chunk=on_chunk, **settings)
            calls = answer.get("tool_calls") or []
            if not calls:
                return answer
            if self.stop_reason not in RUNNABLE:
                for call in calls:
                    self.append(ToolMessage(f"not run: the turn ended on {self.stop_reason}", call["id"]))
                if self.stop_reason != "length":
                    return answer
                continue
            for call in calls:
                self.append(self.run_tool(call))
        raise Harness1Error(
            f"the model was still calling tools after {steps} turns; "
            "call run() again to carry on"
        )

    def turn(
        self,
        stream: bool = False,
        on_chunk: Callable[[dict[str, Any]], None] | None = None,
        **settings: Any,
    ) -> Message:
        """Runs one model turn — one request, and the answer to it — and
        appends it. Returns the turn.

        One turn is not one answer: it is whatever the model did between one
        request and the next, which may be a chain of thought, some text and
        some tool calls, in the order it produced them. `usage` and
        `stop_reason` are left set to what this turn reported; the reason is
        the API's `finish_reason`, so `stop`, `tool_calls`, `length`,
        `content_filter` or `insufficient_system_resource`.
        """
        body = self._body(settings)
        if stream:
            assembled = Turn()
            for chunk in self.client.stream(**body):
                assembled.add(chunk)
                if on_chunk is not None:
                    on_chunk(chunk)
            self.usage = assembled.usage
            self.stop_reason = assembled.finish_reason
            answer = assembled.result()
        else:
            completion = self.client.chat(**body)
            # One choice, at index 0; see `Client.chat`.
            choices = completion.get("choices") or []
            self.usage = completion.get("usage")
            self.stop_reason = choices[0].get("finish_reason") if choices else None
            answer = as_message(choices[0]["message"]) if choices else AssistantMessage()
        self.messages.append(answer)
        return answer

    def _body(self, settings: dict[str, Any]) -> dict[str, Any]:
        body = dict(self.settings)
        for name, value in settings.items():
            if name not in _SETTINGS:
                raise TypeError(_not_a_setting(name))
            field, wanted = _field(name, value)
            if wanted is None:
                body.pop(field, None)
            else:
                body[field] = wanted
        body["messages"] = [dict(message) for message in self.messages]
        if self.tool:
            body.setdefault("tools", self.tool.to_json())
        return body

    def run_tool(self, call: dict[str, Any]) -> ToolMessage:
        """Runs one call the model asked for, and returns the turn that answers
        it. A tool nobody registered, or one that raised, is the model's to
        correct, so it goes back as the answer rather than raising here."""
        function = call.get("function") or {}
        tool = self.tool.get(function.get("name"))
        if tool is None:
            return ToolMessage(f"no tool named {function.get('name')!r} is registered", call.get("id") or "")
        try:
            result = tool.call(function.get("arguments") or "")
        except Exception as error:
            return ToolMessage(f"{type(error).__name__}: {error}", call.get("id") or "")
        if not isinstance(result, str):
            result = json.dumps(result, ensure_ascii=False, default=str)
        return ToolMessage(result, call.get("id") or "")
