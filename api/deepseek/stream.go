package deepseek

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

// doneSentinel is the last event of a stream: generation is over.
var doneSentinel = []byte("[DONE]")

// Stream decodes a streamed response whose chunks are of type T. Recv returns
// the chunks in order and io.EOF after the API's [DONE] sentinel, and Usage
// reports the tokens billed for the request, which arrive on the last chunk. A
// stream is read from one goroutine at a time, and the request's context
// cancels it.
type Stream[T any] struct {
	body    io.ReadCloser
	r       *sseReader
	usageOf func(*T) *Usage
	usage   *Usage
	err     error
	open    bool
}

// NewStream reads chunks of type T from body. usageOf locates the usage of a
// chunk, which the API reports on the last one; it may be nil.
func NewStream[T any](body io.ReadCloser, usageOf func(*T) *Usage) *Stream[T] {
	return &Stream[T]{body: body, r: newSSEReader(body), usageOf: usageOf, open: true}
}

// Recv returns the next chunk of the response. It returns io.EOF after the
// final [DONE] event, the read error when the response is interrupted before
// it, and io.ErrUnexpectedEOF when the body ends without [DONE]. Once it has
// returned an error the stream is closed and every later call returns that same
// error.
func (s *Stream[T]) Recv() (*T, error) {
	if s.err != nil {
		return nil, s.err
	}
	for {
		data, err := s.r.next()
		if err != nil {
			if errors.Is(err, io.EOF) {
				// The body ended without [DONE]: the response is incomplete.
				return nil, s.fail(io.ErrUnexpectedEOF)
			}
			return nil, s.fail(fmt.Errorf("deepseek: reading stream: %w", err))
		}
		if bytes.Equal(bytes.TrimSpace(data), doneSentinel) {
			return nil, s.finish()
		}
		var chunk T
		if err := json.Unmarshal(data, &chunk); err != nil {
			return nil, s.fail(fmt.Errorf("deepseek: malformed stream chunk %q: %w", data, err))
		}
		if s.usageOf != nil {
			if usage := s.usageOf(&chunk); usage != nil {
				s.usage = usage
			}
		}
		return &chunk, nil
	}
}

// Usage returns the token usage the API reported for the request, or nil while
// it has not arrived.
func (s *Stream[T]) Usage() *Usage { return s.usage }

// Close releases the connection. Reading the stream to its end closes it too.
func (s *Stream[T]) Close() error {
	if s.err == nil {
		// Closing early is not a failure: later reads just report the end.
		s.err = io.EOF
	}
	if !s.open {
		return nil
	}
	s.open = false
	return s.body.Close()
}

// fail closes the stream and remembers err as its terminal state.
func (s *Stream[T]) fail(err error) error {
	if s.open {
		s.open = false
		_ = s.body.Close()
	}
	s.err = err
	return err
}

// finish closes the stream at the [DONE] sentinel.
func (s *Stream[T]) finish() error { return s.fail(io.EOF) }

// sseReader decodes the subset of the Server-Sent Events format that the API's
// streaming endpoints emit: events of "data:" lines, ended by an empty line,
// with comment lines such as ": keep-alive" and any other field ignored.
type sseReader struct {
	br *bufio.Reader
}

func newSSEReader(r io.Reader) *sseReader {
	return &sseReader{br: bufio.NewReader(r)}
}

// next returns the data of the next event, or io.EOF once the stream ends.
// Multiple data fields of one event are joined with a newline.
func (s *sseReader) next() ([]byte, error) {
	var data []byte
	for {
		line, err := s.br.ReadString('\n')
		// The last line of a body may arrive without its newline.
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			if data != nil {
				return data, nil
			}
			if err != nil {
				return nil, io.EOF
			}
			continue
		}
		if field, value, ok := strings.Cut(line, ":"); ok && field == "data" {
			value = strings.TrimPrefix(value, " ")
			if value == "" {
				// An event with no payload carries nothing to dispatch.
				continue
			}
			if data == nil {
				data = []byte(value)
			} else {
				data = append(data, '\n')
				data = append(data, value...)
			}
		}
		if err != nil {
			if data != nil {
				return data, nil
			}
			return nil, io.EOF
		}
	}
}
