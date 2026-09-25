package fim

import (
	"github.com/iacore/harness1/api/deepseek"
)

// Object type of a completion and of a streamed chunk.
const ObjectTextCompletion = "text_completion"

// finish_reason values. FIM never calls tools, so there is no "tool_calls".
const (
	FinishStop                       = "stop"
	FinishLength                     = "length"
	FinishContentFilter              = "content_filter"
	FinishInsufficientSystemResource = "insufficient_system_resource"
	FinishAborted                    = "aborted"
)

// Documented request limits. The 4K output ceiling is from the FIM guide, which
// notes the model generates at most 4K tokens for this endpoint.
const (
	MaxOutputTokens  = 4096
	MaxStopSequences = 16
	MaxLogprobs      = 20
)

// Completion is a non-streaming response, and the result of collecting a
// stream.
type Completion struct {
	ID                string          `json:"id"`
	Object            string          `json:"object"`
	Created           int64           `json:"created"`
	Model             string          `json:"model"`
	SystemFingerprint string          `json:"system_fingerprint"`
	Choices           []Choice        `json:"choices"`
	Usage             *deepseek.Usage `json:"usage,omitempty"`
}

// Text returns the text of the first choice, or "" when the response carries no
// choice.
func (c *Completion) Text() string {
	if len(c.Choices) == 0 {
		return ""
	}
	return c.Choices[0].Text
}

// Choice is one completion alternative; within a streamed chunk it carries the
// text added so far.
type Choice struct {
	FinishReason string    `json:"finish_reason"`
	Index        int       `json:"index"`
	Text         string    `json:"text"`
	Logprobs     *Logprobs `json:"logprobs,omitempty"`
}

// Logprobs is the legacy completions log-probability report: parallel lists of
// the sampled tokens, their positions and their probabilities, plus the most
// likely alternatives at each position.
type Logprobs struct {
	TextOffset    []int                `json:"text_offset"`
	TokenLogprobs []float64            `json:"token_logprobs"`
	Tokens        []string             `json:"tokens"`
	TopLogprobs   []map[string]float64 `json:"top_logprobs"`
}
