package fim

import (
	"errors"
	"fmt"
	"strings"
)

// Validate reports whether the request satisfies the constraints the API
// documents for POST /completions, so that a request the API would reject is
// caught before it is sent. Complete and CompleteStream call it, with the
// streaming flag of the method they were called as, so callers rarely need it.
func (r *Request) Validate() error { return r.validate(r.Stream) }

func (r *Request) validate(stream bool) error {
	if strings.TrimSpace(r.Model) == "" {
		return errors.New("deepseek: model is required")
	}
	if r.Prompt == "" {
		return errors.New("deepseek: prompt is required")
	}
	if r.Echo != nil && *r.Echo {
		switch {
		case r.Suffix != "":
			return errors.New("deepseek: echo cannot be combined with suffix")
		case r.Logprobs != nil:
			return errors.New("deepseek: echo cannot be combined with logprobs")
		}
	}
	if r.Logprobs != nil && (*r.Logprobs < 0 || *r.Logprobs > MaxLogprobs) {
		return fmt.Errorf("deepseek: logprobs must be between 0 and %d, got %d", MaxLogprobs, *r.Logprobs)
	}
	if r.MaxTokens != nil && (*r.MaxTokens < 1 || *r.MaxTokens > MaxOutputTokens) {
		return fmt.Errorf("deepseek: max_tokens must be between 1 and %d, got %d", MaxOutputTokens, *r.MaxTokens)
	}
	if len(r.Stop) > MaxStopSequences {
		return fmt.Errorf("deepseek: stop accepts at most %d sequences, got %d", MaxStopSequences, len(r.Stop))
	}
	for _, stop := range r.Stop {
		if stop == "" {
			return errors.New("deepseek: stop sequences must not be empty")
		}
	}
	if r.Temperature != nil && !(*r.Temperature >= 0 && *r.Temperature <= 2) {
		return fmt.Errorf("deepseek: temperature must be between 0 and 2, got %v", *r.Temperature)
	}
	if r.TopP != nil && !(*r.TopP > 0 && *r.TopP <= 1) {
		return fmt.Errorf("deepseek: top_p must be greater than 0 and at most 1, got %v", *r.TopP)
	}
	if r.StreamOptions != nil && !stream {
		return errors.New("deepseek: stream_options requires stream")
	}
	return nil
}
