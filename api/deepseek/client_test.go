package deepseek

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

// roundTripperFunc stands in for the network, so the resolved URL of a request
// can be asserted without a server.
type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// newTestClient returns a client whose HTTP layer is the given function.
func newTestClient(t *testing.T, transport roundTripperFunc) *Client {
	t.Helper()
	client, err := NewClient("test-key", WithHTTPClient(&http.Client{Transport: transport}))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return client
}

func TestClientBaseURL(t *testing.T) {
	cases := []struct {
		name string
		opts []Option
		want string
	}{
		{"default", nil, "https://api.deepseek.com/completions"},
		{"beta", []Option{WithBeta()}, "https://api.deepseek.com/beta/completions"},
		{"custom", []Option{WithBaseURL("http://proxy.test/api/")}, "http://proxy.test/api/completions"},
		{"custom beta", []Option{WithBaseURL("http://proxy.test/api"), WithBeta()}, "http://proxy.test/api/beta/completions"},
		{"custom beta reversed order", []Option{WithBeta(), WithBaseURL("http://proxy.test/api")}, "http://proxy.test/api/beta/completions"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var gotURL string
			httpClient := &http.Client{Transport: roundTripperFunc(func(r *http.Request) (*http.Response, error) {
				gotURL = r.URL.String()
				return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("{}"))}, nil
			})}
			client, err := NewClient("test-key", append(tc.opts, WithHTTPClient(httpClient))...)
			if err != nil {
				t.Fatalf("NewClient: %v", err)
			}
			if !reflect.DeepEqual(client.Beta(), strings.Contains(tc.want, "/beta/")) {
				t.Errorf("Beta() = %v, want the url %s to say", client.Beta(), tc.want)
			}
			resp, err := client.Post(context.Background(), "/completions", struct{}{}, false)
			if err != nil {
				t.Fatalf("Post: %v", err)
			}
			resp.Body.Close()
			if gotURL != tc.want {
				t.Errorf("request url = %s, want %s", gotURL, tc.want)
			}
		})
	}
}

func TestClientPostHeaders(t *testing.T) {
	var got *http.Request
	client := newTestClient(t, func(r *http.Request) (*http.Response, error) {
		got = r
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("{}"))}, nil
	})

	resp, err := client.Post(context.Background(), "/chat/completions", map[string]any{"model": "m"}, true)
	if err != nil {
		t.Fatalf("Post: %v", err)
	}
	resp.Body.Close()
	if got.Method != http.MethodPost {
		t.Errorf("method = %s, want POST", got.Method)
	}
	if auth := got.Header.Get("Authorization"); auth != "Bearer test-key" {
		t.Errorf("Authorization = %q, want %q", auth, "Bearer test-key")
	}
	if ct := got.Header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
	if accept := got.Header.Get("Accept"); accept != "text/event-stream" {
		t.Errorf("Accept = %q, want text/event-stream", accept)
	}
}

func TestClientErrors(t *testing.T) {
	t.Run("error envelope", func(t *testing.T) {
		client := newTestClient(t, func(r *http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusTooManyRequests,
				Body:       io.NopCloser(strings.NewReader(`{"error":{"message":"Rate limit reached","type":"rate_limit_error","param":null,"code":429001}}`)),
			}, nil
		})
		_, err := client.Post(context.Background(), "/chat/completions", struct{}{}, false)
		var apiErr *APIError
		if !errors.As(err, &apiErr) {
			t.Fatalf("err = %v, want *APIError", err)
		}
		// The API reports error codes as strings or as numbers.
		if apiErr.StatusCode != http.StatusTooManyRequests || apiErr.Type != "rate_limit_error" || apiErr.Code != "429001" || apiErr.Message != "Rate limit reached" {
			t.Errorf("APIError = %+v", apiErr)
		}
		if want := "deepseek: HTTP 429 rate_limit_error/429001: Rate limit reached"; apiErr.Error() != want {
			t.Errorf("Error() = %q, want %q", apiErr.Error(), want)
		}
	})

	t.Run("non-json body", func(t *testing.T) {
		client := newTestClient(t, func(r *http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusBadGateway,
				Body:       io.NopCloser(strings.NewReader("<html>bad gateway</html>")),
			}, nil
		})
		_, err := client.Post(context.Background(), "/chat/completions", struct{}{}, false)
		var apiErr *APIError
		if !errors.As(err, &apiErr) || apiErr.StatusCode != http.StatusBadGateway || apiErr.Message != "<html>bad gateway</html>" {
			t.Fatalf("err = %v", err)
		}
	})

	t.Run("without api key", func(t *testing.T) {
		if _, err := NewClient("  "); err == nil {
			t.Fatal("NewClient accepted an empty key")
		}
	})
}

// testChunk is a minimal streamed chunk, since the endpoints define their own.
type testChunk struct {
	Text  string `json:"text"`
	Usage *Usage `json:"usage,omitempty"`
}

func testStream(events ...string) *Stream[testChunk] {
	body := io.NopCloser(strings.NewReader(strings.Join(events, "")))
	return NewStream[testChunk](body, func(c *testChunk) *Usage { return c.Usage })
}

func TestStreamDecoding(t *testing.T) {
	stream := testStream(
		": keep-alive\n\n",
		"data: {\"text\":\"Once \"}\n\n",
		"data: {\"text\":\"upon a time\"}\n\n",
		"data: {\"text\":\"\",\"usage\":{\"completion_tokens\":9,\"prompt_tokens\":17,\"total_tokens\":26,\"prompt_cache_hit_tokens\":1,\"prompt_cache_miss_tokens\":16}}\n\n",
		"data: [DONE]\n\n",
	)
	var text string
	chunks := 0
	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("Recv: %v", err)
		}
		chunks++
		text += chunk.Text
	}
	if chunks != 3 || text != "Once upon a time" {
		t.Errorf("read %d chunks spelling %q", chunks, text)
	}
	if usage := stream.Usage(); usage == nil || usage.TotalTokens != 26 || usage.PromptCacheMissTokens != 16 {
		t.Errorf("Usage() = %+v", usage)
	}
	// The sentinel ends the stream, and it stays ended.
	if _, err := stream.Recv(); !errors.Is(err, io.EOF) {
		t.Errorf("Recv after [DONE] = %v, want io.EOF", err)
	}
}

func TestStreamFailures(t *testing.T) {
	t.Run("truncated", func(t *testing.T) {
		stream := testStream("data: {\"text\":\"partial\"}\n\n")
		if _, err := stream.Recv(); err != nil {
			t.Fatalf("Recv: %v", err)
		}
		if _, err := stream.Recv(); !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Errorf("Recv = %v, want io.ErrUnexpectedEOF", err)
		}
		if _, err := stream.Recv(); !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Errorf("second Recv = %v, want the same error", err)
		}
	})

	t.Run("malformed chunk", func(t *testing.T) {
		stream := testStream("data: {not json}\n\n")
		if _, err := stream.Recv(); err == nil || !strings.Contains(err.Error(), "malformed stream chunk") {
			t.Errorf("Recv = %v, want a malformed chunk error", err)
		}
	})

	t.Run("closed early", func(t *testing.T) {
		stream := testStream("data: {\"text\":\"x\"}\n\n", "data: [DONE]\n\n")
		if _, err := stream.Recv(); err != nil {
			t.Fatalf("Recv: %v", err)
		}
		if err := stream.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
		if _, err := stream.Recv(); !errors.Is(err, io.EOF) {
			t.Errorf("Recv after Close = %v, want io.EOF", err)
		}
	})
}

func TestStopSequencesJSONForms(t *testing.T) {
	cases := []struct {
		in   StopSequences
		json string
	}{
		{StopSequences{"END"}, `"END"`},
		{StopSequences{"END", "STOP"}, `["END","STOP"]`},
		{nil, `null`},
	}
	for _, tc := range cases {
		encoded, err := json.Marshal(tc.in)
		if err != nil {
			t.Fatalf("Marshal(%v): %v", tc.in, err)
		}
		if string(encoded) != tc.json {
			t.Errorf("Marshal(%v) = %s, want %s", tc.in, encoded, tc.json)
		}
		var decoded StopSequences
		if err := json.Unmarshal([]byte(tc.json), &decoded); err != nil {
			t.Fatalf("Unmarshal(%s): %v", tc.json, err)
		}
		if !reflect.DeepEqual(decoded, tc.in) {
			t.Errorf("Unmarshal(%s) = %v, want %v", tc.json, decoded, tc.in)
		}
	}
}
