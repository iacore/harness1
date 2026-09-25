package fim

import (
	"errors"
	"io"
	"sort"

	"github.com/iacore/harness1/api/deepseek"
)

// Stream is a streamed FIM completion response. Recv returns the chunks in
// order, Usage the tokens billed for the request, and Collect assembles the
// whole response instead. Produce it with CompleteStream.
type Stream struct {
	*deepseek.Stream[Chunk]
}

func newStream(body io.ReadCloser) *Stream {
	return &Stream{Stream: deepseek.NewStream[Chunk](body, func(c *Chunk) *deepseek.Usage { return c.Usage })}
}

// Collect reads the rest of the stream and assembles the text of each choice,
// its log probabilities and the usage into the same completion Complete
// returns.
func (s *Stream) Collect() (*Completion, error) {
	out := &Completion{Object: ObjectTextCompletion, Usage: s.Usage()}
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
				acc = &choiceAccumulator{index: c.Index}
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

// Chunk is one event of a streamed response, in the shape of a completion whose
// text grows chunk by chunk.
type Chunk struct {
	ID                string          `json:"id"`
	Object            string          `json:"object"`
	Created           int64           `json:"created"`
	Model             string          `json:"model"`
	SystemFingerprint string          `json:"system_fingerprint"`
	Choices           []Choice        `json:"choices"`
	Usage             *deepseek.Usage `json:"usage,omitempty"`
}

// choiceAccumulator assembles the deltas of one choice.
type choiceAccumulator struct {
	index        int
	text         string
	finishReason string
	logprobs     *Logprobs
}

func (a *choiceAccumulator) merge(c Choice) {
	a.text += c.Text
	if c.FinishReason != "" {
		a.finishReason = c.FinishReason
	}
	if c.Logprobs != nil {
		if a.logprobs == nil {
			a.logprobs = &Logprobs{}
		}
		// Text offsets are absolute, so the lists are appended as they arrive.
		a.logprobs.TextOffset = append(a.logprobs.TextOffset, c.Logprobs.TextOffset...)
		a.logprobs.TokenLogprobs = append(a.logprobs.TokenLogprobs, c.Logprobs.TokenLogprobs...)
		a.logprobs.Tokens = append(a.logprobs.Tokens, c.Logprobs.Tokens...)
		a.logprobs.TopLogprobs = append(a.logprobs.TopLogprobs, c.Logprobs.TopLogprobs...)
	}
}

func (a *choiceAccumulator) choice() Choice {
	return Choice{
		Index:        a.index,
		Text:         a.text,
		FinishReason: a.finishReason,
		Logprobs:     a.logprobs,
	}
}
