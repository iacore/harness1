// Package chat implements the DeepSeek Chat Completions endpoint.
//
// It covers POST /chat/completions as documented at
// https://api-docs.deepseek.com/api/create-chat-completion: the full request
// surface (messages with text, image and file parts, thinking mode, tool
// calling, JSON output, logprobs, stop sequences, streaming), the non-streaming
// and streaming response shapes, and the API's error envelope.
//
// Two features are restricted to the Beta API root and are rejected by Chat and
// ChatStream unless the client was built with deepseek.WithBeta: Chat Prefix
// Completion (AssistantMessage.Prefix) and strict tool calls (Function.Strict).
//
// Streaming is a sequence of semantic server-sent events carrying chat
// completion chunks, terminated by "data: [DONE]" rather than by a message with
// a done flag, and the tokens billed for the request ride on the last chunk.
package chat

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/iacore/harness1/api/deepseek"
)

const chatCompletionsPath = "/chat/completions"

// Request is the body of POST /chat/completions. Optional parameters are
// pointers so that "unset" stays distinguishable from a zero value, which
// matters for the ones with a server-side default (temperature, top_p,
// max_tokens, logprobs).
type Request struct {
	// Model is deepseek.ModelFlash or deepseek.ModelV4Pro. Required.
	Model string `json:"model"`

	// Messages is the conversation so far, built from *SystemMessage,
	// *UserMessage, *AssistantMessage and *ToolMessage. Required; the API
	// accepts one or more.
	Messages []Message `json:"messages"`

	// Thinking toggles the chain of thought, which is enabled by default. Build
	// it with EnableThinking or DisableThinking.
	Thinking *Thinking `json:"thinking,omitempty"`

	// ReasoningEffort selects the thinking effort. EffortNone disables thinking
	// mode; EffortHigh is the default. Has no effect in non-thinking mode.
	ReasoningEffort string `json:"reasoning_effort,omitempty"`

	// MaxTokens bounds the generated tokens, reasoning included. Defaults to
	// 8192 in non-thinking mode, 65536 in thinking mode, 131072 at EffortMax.
	MaxTokens *int `json:"max_tokens,omitempty"`

	// ResponseFormat asks for plain text or for a JSON object. Build it with
	// TextResponseFormat or JSONResponseFormat.
	ResponseFormat *ResponseFormat `json:"response_format,omitempty"`

	// Stop lists up to MaxStopSequences sequences at which generation stops.
	Stop deepseek.StopSequences `json:"stop,omitempty"`

	// Stream asks for server-sent events instead of one JSON body. Chat
	// requires it to be false; ChatStream sets it.
	Stream bool `json:"stream,omitempty"`

	// StreamOptions configures a streamed response and requires Stream.
	StreamOptions *deepseek.StreamOptions `json:"stream_options,omitempty"`

	// Temperature samples between 0 and 2 and has no effect in thinking mode.
	Temperature *float64 `json:"temperature,omitempty"`

	// TopP is nucleus sampling. It only applies in thinking mode, where the
	// effective range is 0.95 to 1.
	TopP *float64 `json:"top_p,omitempty"`

	// Tools are the functions the model may call, each a function declaration.
	Tools []Tool `json:"tools,omitempty"`

	// ToolChoice constrains tool calling. Required and named choices are not
	// supported in thinking mode.
	ToolChoice *ToolChoice `json:"tool_choice,omitempty"`

	// Logprobs asks for the log probabilities of the generated tokens.
	Logprobs *bool `json:"logprobs,omitempty"`

	// TopLogprobs is how many alternatives to report per token position, from 0
	// to MaxTopLogprobs. Requires Logprobs.
	TopLogprobs *int `json:"top_logprobs,omitempty"`

	// UserID identifies the end user for abuse review, cache isolation and
	// scheduling. Do not put private data in it.
	UserID string `json:"user_id,omitempty"`
}

// Client sends Chat Completions requests. It wraps the shared client, so one
// *deepseek.Client can serve this endpoint and the FIM endpoint at once:
//
//	ds, err := deepseek.NewClient(key, deepseek.WithBeta())
//	completion, err := (&chat.Client{Client: ds}).Chat(ctx, req)
type Client struct{ *deepseek.Client }

// NewClient returns a client authenticated with apiKey.
func NewClient(apiKey string, opts ...deepseek.Option) (*Client, error) {
	ds, err := deepseek.NewClient(apiKey, opts...)
	if err != nil {
		return nil, err
	}
	return &Client{Client: ds}, nil
}

// Chat sends a non-streaming request. req.Stream must be false; use ChatStream
// to stream a response.
func (c *Client) Chat(ctx context.Context, req *Request) (*Completion, error) {
	if req == nil {
		return nil, errors.New("deepseek: nil request")
	}
	if req.Stream {
		return nil, errors.New("deepseek: Request.Stream is true; use ChatStream")
	}
	if err := c.prepare(req, false); err != nil {
		return nil, err
	}
	resp, err := c.Post(ctx, chatCompletionsPath, req, false)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out Completion
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("deepseek: decoding response: %w", err)
	}
	return &out, nil
}

// ChatStream sends a streaming request and returns the event stream. The
// request is sent with stream set to true whatever req.Stream says, and the
// caller must Close the returned stream, though reading it to the end closes it
// as well.
func (c *Client) ChatStream(ctx context.Context, req *Request) (*Stream, error) {
	if req == nil {
		return nil, errors.New("deepseek: nil request")
	}
	if err := c.prepare(req, true); err != nil {
		return nil, err
	}
	wire := *req
	wire.Stream = true
	resp, err := c.Post(ctx, chatCompletionsPath, &wire, true)
	if err != nil {
		return nil, err
	}
	return newStream(resp.Body), nil
}

// prepare validates req and enforces the client-level Beta requirements.
func (c *Client) prepare(req *Request, stream bool) error {
	if err := req.validate(stream); err != nil {
		return err
	}
	if c.Beta() {
		return nil
	}
	for _, tool := range req.Tools {
		if tool.Function.Strict {
			return errors.New("deepseek: strict tool calls need the Beta API root; build the client with deepseek.WithBeta")
		}
	}
	if last := len(req.Messages) - 1; last >= 0 {
		if assistant, ok := req.Messages[last].(*AssistantMessage); ok && assistant.Prefix {
			return errors.New("deepseek: chat prefix completion needs the Beta API root; build the client with deepseek.WithBeta")
		}
	}
	return nil
}
