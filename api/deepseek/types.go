package deepseek

import "encoding/json"

// Models served by the API.
const (
	ModelFlash = "deepseek-flash"
	ModelV4Pro = "deepseek-v4-pro"
)

// Usage reports the tokens billed for a request. Both endpoints return it in
// the same shape.
type Usage struct {
	CompletionTokens        int                      `json:"completion_tokens"`
	PromptTokens            int                      `json:"prompt_tokens"`
	TotalTokens             int                      `json:"total_tokens"`
	PromptCacheHitTokens    int                      `json:"prompt_cache_hit_tokens"`
	PromptCacheMissTokens   int                      `json:"prompt_cache_miss_tokens"`
	PromptTokensDetails     *PromptTokensDetails     `json:"prompt_tokens_details,omitempty"`
	CompletionTokensDetails *CompletionTokensDetails `json:"completion_tokens_details,omitempty"`
}

// PromptTokensDetails breaks the prompt tokens down by context-cache hits.
type PromptTokensDetails struct {
	CachedTokens int `json:"cached_tokens"`
}

// CompletionTokensDetails breaks the completion tokens down by reasoning.
type CompletionTokensDetails struct {
	ReasoningTokens int `json:"reasoning_tokens"`
}

// StreamOptions configures a streamed response.
type StreamOptions struct {
	// IncludeUsage puts a usage field on every chunk, null except on the last.
	// The last chunk carries the usage of the whole request either way.
	IncludeUsage bool `json:"include_usage,omitempty"`
}

// StopSequences lists the sequences at which generation stops. Up to 16 are
// accepted. It marshals as a single string when it holds one sequence and as an
// array otherwise, and accepts both forms when decoding.
type StopSequences []string

// MarshalJSON encodes a single sequence as a string.
func (s StopSequences) MarshalJSON() ([]byte, error) {
	if len(s) == 1 {
		return json.Marshal(s[0])
	}
	return json.Marshal([]string(s))
}

// UnmarshalJSON accepts a string or an array of strings.
func (s *StopSequences) UnmarshalJSON(data []byte) error {
	if len(data) > 0 && data[0] == '"' {
		var one string
		if err := json.Unmarshal(data, &one); err != nil {
			return err
		}
		*s = StopSequences{one}
		return nil
	}
	var many []string
	if err := json.Unmarshal(data, &many); err != nil {
		return err
	}
	*s = many
	return nil
}
