package chat

import (
	"errors"
	"io"
	"sort"

	"github.com/iacore/harness1/api/deepseek"
)

// Stream is a streamed Chat Completions response. Recv returns the chunks in
// order, Usage the tokens billed for the request, and Collect assembles the
// whole response instead. Produce it with ChatStream.
type Stream struct {
	*deepseek.Stream[Chunk]
}

func newStream(body io.ReadCloser) *Stream {
	return &Stream{Stream: deepseek.NewStream[Chunk](body, func(c *Chunk) *deepseek.Usage { return c.Usage })}
}

// Collect reads the rest of the stream and assembles the deltas into the same
// completion Chat returns, including the content, the chain of thought, the
// tool calls whose arguments arrive in fragments, the log probabilities and the
// usage.
func (s *Stream) Collect() (*Completion, error) {
	out := &Completion{Object: ObjectCompletion, Usage: s.Usage()}
	accs := make(map[int]*choiceAccumulator)
	var order []int
	for {
		chunk, err := s.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if out.ID == "" {
			out.ID = chunk.ID
			out.Created = chunk.Created
			out.Model = chunk.Model
			out.SystemFingerprint = chunk.SystemFingerprint
		}
		for _, c := range chunk.Choices {
			acc, ok := accs[c.Index]
			if !ok {
				acc = &choiceAccumulator{index: c.Index, toolCalls: make(map[int]*ToolCall)}
				accs[c.Index] = acc
				order = append(order, c.Index)
			}
			acc.merge(c)
		}
		if chunk.Usage != nil {
			out.Usage = chunk.Usage
		}
	}
	sort.Ints(order)
	for _, index := range order {
		out.Choices = append(out.Choices, accs[index].choice())
	}
	return out, nil
}

// Chunk is one event of a streamed response.
type Chunk struct {
	ID                string          `json:"id"`
	Object            string          `json:"object"`
	Created           int64           `json:"created"`
	Model             string          `json:"model"`
	SystemFingerprint string          `json:"system_fingerprint"`
	Choices           []ChunkChoice   `json:"choices"`
	Usage             *deepseek.Usage `json:"usage,omitempty"`
}

// ChunkChoice is the increment of one choice within a chunk. FinishReason is
// empty until the model stops.
type ChunkChoice struct {
	Index        int       `json:"index"`
	Delta        Delta     `json:"delta"`
	FinishReason string    `json:"finish_reason"`
	Logprobs     *Logprobs `json:"logprobs,omitempty"`
}

// Delta is the content a chunk adds. Tool call fragments carry an Index; the
// first fragment of each call also carries ID, Type and the function name, and
// later fragments only extend the arguments.
type Delta struct {
	Role             string     `json:"role,omitempty"`
	Content          string     `json:"content,omitempty"`
	ReasoningContent string     `json:"reasoning_content,omitempty"`
	ToolCalls        []ToolCall `json:"tool_calls,omitempty"`
}

// choiceAccumulator assembles the deltas of one choice.
type choiceAccumulator struct {
	index        int
	message      AssistantMessage
	toolCalls    map[int]*ToolCall
	toolOrder    []int
	finishReason string
	logprobs     *Logprobs
}

func (a *choiceAccumulator) merge(c ChunkChoice) {
	d := c.Delta
	if d.Role != "" {
		a.message.Role = d.Role
	}
	a.message.Content += d.Content
	a.message.ReasoningContent += d.ReasoningContent
	for _, call := range d.ToolCalls {
		index := 0
		if call.Index != nil {
			index = *call.Index
		}
		acc, ok := a.toolCalls[index]
		if !ok {
			acc = &ToolCall{}
			a.toolCalls[index] = acc
			a.toolOrder = append(a.toolOrder, index)
		}
		if call.ID != "" {
			acc.ID = call.ID
		}
		if call.Type != "" {
			acc.Type = call.Type
		}
		if call.Function.Name != "" {
			acc.Function.Name = call.Function.Name
		}
		acc.Function.Arguments += call.Function.Arguments
	}
	if c.FinishReason != "" {
		a.finishReason = c.FinishReason
	}
	if c.Logprobs != nil {
		if a.logprobs == nil {
			a.logprobs = &Logprobs{}
		}
		a.logprobs.Content = append(a.logprobs.Content, c.Logprobs.Content...)
		a.logprobs.ReasoningContent = append(a.logprobs.ReasoningContent, c.Logprobs.ReasoningContent...)
	}
}

func (a *choiceAccumulator) choice() Choice {
	message := a.message
	if message.Role == "" {
		message.Role = RoleAssistant
	}
	sort.Ints(a.toolOrder)
	for _, index := range a.toolOrder {
		message.ToolCalls = append(message.ToolCalls, *a.toolCalls[index])
	}
	return Choice{
		Index:        a.index,
		FinishReason: a.finishReason,
		Message:      message,
		Logprobs:     a.logprobs,
	}
}
