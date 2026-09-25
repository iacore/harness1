// Package fim implements the DeepSeek FIM (Fill In the Middle) completion
// endpoint, in which the caller supplies a prefix and an optional suffix and
// the model fills in between them.
//
// It covers POST /completions as documented at
// https://api-docs.deepseek.com/api/create-completion. The endpoint is a Beta
// feature, so it always requires the Beta API root: NewClient enables it, and
// Complete and CompleteStream reject a client built without it.
//
// The endpoint runs in non-thinking mode only and generates at most 4K tokens,
// which is why it has no thinking parameters and caps max_tokens at 4096.
package fim

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/iacore/harness1/api/deepseek"
)

const completionsPath = "/completions"

// Request is the body of POST /completions. Optional parameters are pointers so
// that "unset" stays distinguishable from a zero value.
type Request struct {
	// Model is deepseek.ModelFlash or deepseek.ModelV4Pro. Required.
	Model string `json:"model"`

	// Prompt is the text before the completion. Required.
	Prompt string `json:"prompt"`

	// Suffix is the text the completion must lead into. Cannot be combined with
	// Echo.
	Suffix string `json:"suffix,omitempty"`

	// Echo repeats the prompt before the completion. Cannot be combined with
	// Suffix or Logprobs.
	Echo *bool `json:"echo,omitempty"`

	// Logprobs asks for the log probabilities of the most likely output tokens,
	// from 0 to MaxLogprobs. The response carries up to one more entry than
	// requested, since the sampled token is always reported. Cannot be combined
	// with Echo.
	Logprobs *int `json:"logprobs,omitempty"`

	// MaxTokens bounds the generated tokens, 1 to MaxOutputTokens.
	MaxTokens *int `json:"max_tokens,omitempty"`

	// Stop lists up to MaxStopSequences sequences at which generation stops.
	// The returned text does not contain the stop sequence.
	Stop deepseek.StopSequences `json:"stop,omitempty"`

	// Temperature samples between 0 and 2.
	Temperature *float64 `json:"temperature,omitempty"`

	// TopP is nucleus sampling, greater than 0 and at most 1.
	TopP *float64 `json:"top_p,omitempty"`

	// Stream asks for server-sent events instead of one JSON body. Complete
	// requires it to be false; CompleteStream sets it.
	Stream bool `json:"stream,omitempty"`

	// StreamOptions configures a streamed response and requires Stream.
	StreamOptions *deepseek.StreamOptions `json:"stream_options,omitempty"`
}

// Client sends FIM completion requests. It wraps the shared client, so one
// *deepseek.Client can serve this endpoint and the Chat Completions endpoint at
// once:
//
//	ds, err := deepseek.NewClient(key, deepseek.WithBeta())
//	completion, err := (&fim.Client{Client: ds}).Complete(ctx, req)
type Client struct{ *deepseek.Client }

// NewClient returns a client authenticated with apiKey and bound to the Beta
// API root, which this endpoint requires.
func NewClient(apiKey string, opts ...deepseek.Option) (*Client, error) {
	// Copy, so that appending does not write into the caller's backing array.
	opts = append(append([]deepseek.Option(nil), opts...), deepseek.WithBeta())
	ds, err := deepseek.NewClient(apiKey, opts...)
	if err != nil {
		return nil, err
	}
	return &Client{Client: ds}, nil
}

// Complete sends a non-streaming request. req.Stream must be false; use
// CompleteStream to stream a response.
func (c *Client) Complete(ctx context.Context, req *Request) (*Completion, error) {
	if req == nil {
		return nil, errors.New("deepseek: nil request")
	}
	if req.Stream {
		return nil, errors.New("deepseek: Request.Stream is true; use CompleteStream")
	}
	if err := c.prepare(req, false); err != nil {
		return nil, err
	}
	resp, err := c.Post(ctx, completionsPath, req, false)
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

// CompleteStream sends a streaming request and returns the event stream. The
// request is sent with stream set to true whatever req.Stream says, and the
// caller must Close the returned stream, though reading it to the end closes it
// as well.
func (c *Client) CompleteStream(ctx context.Context, req *Request) (*Stream, error) {
	if req == nil {
		return nil, errors.New("deepseek: nil request")
	}
	if err := c.prepare(req, true); err != nil {
		return nil, err
	}
	wire := *req
	wire.Stream = true
	resp, err := c.Post(ctx, completionsPath, &wire, true)
	if err != nil {
		return nil, err
	}
	return newStream(resp.Body), nil
}

// prepare validates req and enforces the client-level Beta requirement.
func (c *Client) prepare(req *Request, stream bool) error {
	if err := req.validate(stream); err != nil {
		return err
	}
	if !c.Beta() {
		return errors.New("deepseek: FIM completion needs the Beta API root; build the client with deepseek.WithBeta")
	}
	return nil
}
