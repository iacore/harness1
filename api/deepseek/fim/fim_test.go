package fim

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/iacore/harness1/api/deepseek"
)

func testClient(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	client, err := NewClient("test-key", deepseek.WithBaseURL(srv.URL))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return client
}

// checkRequest asserts the transport-level part of a request and returns its
// decoded body.
func checkRequest(t *testing.T, r *http.Request, wantPath string) map[string]any {
	t.Helper()
	if r.Method != http.MethodPost {
		t.Errorf("method = %s, want POST", r.Method)
	}
	if r.URL.Path != wantPath {
		t.Errorf("path = %s, want %s", r.URL.Path, wantPath)
	}
	if got := r.Header.Get("Authorization"); got != "Bearer test-key" {
		t.Errorf("Authorization = %q, want %q", got, "Bearer test-key")
	}
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		t.Fatalf("decoding request body: %v", err)
	}
	return body
}

func TestRequestWireFormat(t *testing.T) {
	var got map[string]any
	// FIM is a Beta endpoint: the client appends /beta to the base URL.
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		got = checkRequest(t, r, "/beta/completions")
		io.WriteString(w, `{"id":"x","object":"text_completion","choices":[]}`)
	})

	req := &Request{
		Model:       deepseek.ModelFlash,
		Prompt:      "def fib(a):",
		Suffix:      "    return fib(a-1) + fib(a-2)",
		MaxTokens:   new(128),
		Temperature: new(0.3),
		TopP:        new(0.9),
		Stop:        deepseek.StopSequences{"\n\n", "```"},
		Logprobs:    new(5),
	}
	if _, err := client.Complete(context.Background(), req); err != nil {
		t.Fatalf("Complete: %v", err)
	}

	want := map[string]any{
		"model":       "deepseek-flash",
		"prompt":      "def fib(a):",
		"suffix":      "    return fib(a-1) + fib(a-2)",
		"max_tokens":  float64(128),
		"temperature": 0.3,
		"top_p":       0.9,
		"stop":        []any{"\n\n", "```"},
		"logprobs":    float64(5),
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("request body mismatch\n got: %s\nwant: %s", jsonOf(t, got), jsonOf(t, want))
	}
}

func TestRequestOmitsUnsetParameters(t *testing.T) {
	var body []byte
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		body = json.RawMessage(jsonOf(t, checkRequest(t, r, "/beta/completions")))
		io.WriteString(w, `{"id":"x","choices":[]}`)
	})
	if _, err := client.Complete(context.Background(), &Request{Model: deepseek.ModelV4Pro, Prompt: "// "}); err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if want := `{"model":"deepseek-v4-pro","prompt":"// "}`; string(body) != want {
		t.Errorf("body = %s, want %s", body, want)
	}
}

func TestCompleteParsesResponse(t *testing.T) {
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{
			"id": "1f633d8b",
			"object": "text_completion",
			"created": 1718345013,
			"model": "deepseek-flash",
			"system_fingerprint": "fp_a49d71b8a1",
			"choices": [{
				"finish_reason": "stop",
				"index": 0,
				"text": "    if a < 2:\n        return a\n",
				"logprobs": {
					"text_offset": [12, 15],
					"token_logprobs": [-0.01, -0.2],
					"tokens": ["    if", " a"],
					"top_logprobs": [{"    if": -0.01}, {" a": -0.2}]
				}
			}],
			"usage": {
				"completion_tokens": 14,
				"prompt_tokens": 9,
				"total_tokens": 23,
				"prompt_cache_hit_tokens": 0,
				"prompt_cache_miss_tokens": 9,
				"prompt_tokens_details": {"cached_tokens": 0}
			}
		}`)
	})

	got, err := client.Complete(context.Background(), &Request{Model: deepseek.ModelFlash, Prompt: "def fib(a):"})
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if got.ID != "1f633d8b" || got.Object != ObjectTextCompletion || got.Created != 1718345013 || got.SystemFingerprint != "fp_a49d71b8a1" {
		t.Errorf("completion header = %+v", got)
	}
	if len(got.Choices) != 1 {
		t.Fatalf("choices = %d, want 1", len(got.Choices))
	}
	if text := got.Text(); text != "    if a < 2:\n        return a\n" {
		t.Errorf("Text() = %q", text)
	}
	choice := got.Choices[0]
	if choice.FinishReason != FinishStop || choice.Index != 0 {
		t.Errorf("choice = %+v", choice)
	}
	lp := choice.Logprobs
	if lp == nil || len(lp.Tokens) != 2 || lp.Tokens[0] != "    if" || lp.TextOffset[0] != 12 || lp.TokenLogprobs[1] != -0.2 ||
		lp.TopLogprobs[0]["    if"] != -0.01 || lp.TopLogprobs[1][" a"] != -0.2 {
		t.Errorf("logprobs = %+v", lp)
	}
	if got.Usage == nil || got.Usage.PromptTokens != 9 || got.Usage.PromptCacheMissTokens != 9 {
		t.Errorf("usage = %+v", got.Usage)
	}
}

// streamEvents is a canned response stream: a first chunk that opens the
// completion, two that extend its text, and a last one that carries the finish
// reason and the usage.
var streamEvents = []string{
	`{"id":"1f63","object":"text_completion","created":1718345013,"model":"deepseek-flash","system_fingerprint":"fp_a49","choices":[{"index":0,"text":"    if","finish_reason":null}]}`,
	`{"id":"1f63","object":"text_completion","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"text":" a < 2:","finish_reason":null,"logprobs":{"text_offset":[4],"token_logprobs":[-0.01],"tokens":[" a"],"top_logprobs":[{" a":-0.01}]}}]}`,
	`{"id":"1f63","object":"text_completion","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"text":"","finish_reason":"stop","logprobs":{"text_offset":[11],"token_logprobs":[-0.4],"tokens":[" <"],"top_logprobs":[{" <":-0.4}]}}],"usage":{"completion_tokens":3,"prompt_tokens":9,"total_tokens":12,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":9}}`,
	"[DONE]",
}

// serveStream answers with streamEvents, after checking the request and
// returning its body.
func serveStream(t *testing.T) (*Client, *map[string]any) {
	t.Helper()
	got := new(map[string]any)
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		*got = checkRequest(t, r, "/beta/completions")
		if accept := r.Header.Get("Accept"); accept != "text/event-stream" {
			t.Errorf("Accept = %q, want text/event-stream", accept)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, ": keep-alive\n\n")
		for _, event := range streamEvents {
			io.WriteString(w, "data: "+event+"\n\n")
		}
	})
	return client, got
}

func TestCompleteStreamRecv(t *testing.T) {
	client, got := serveStream(t)
	stream, err := client.CompleteStream(context.Background(), &Request{Model: deepseek.ModelFlash, Prompt: "def fib(a):"})
	if err != nil {
		t.Fatalf("CompleteStream: %v", err)
	}
	defer stream.Close()

	// The stream flag is set by the method, not by the caller.
	if (*got)["stream"] != true {
		t.Errorf("stream = %v, want true", (*got)["stream"])
	}

	first, err := stream.Recv()
	if err != nil {
		t.Fatalf("Recv: %v", err)
	}
	if first.Object != ObjectTextCompletion || first.ID != "1f63" || first.Choices[0].Text != "    if" {
		t.Errorf("first chunk = %+v", first)
	}
	if first.Choices[0].FinishReason != "" || first.Choices[0].Logprobs != nil {
		t.Errorf("first choice = %+v", first.Choices[0])
	}

	if chunk, err := stream.Recv(); err != nil {
		t.Fatalf("Recv: %v", err)
	} else if lp := chunk.Choices[0].Logprobs; lp == nil || len(lp.Tokens) != 1 || lp.Tokens[0] != " a" {
		t.Errorf("second chunk = %+v", chunk)
	}

	last, err := stream.Recv()
	if err != nil {
		t.Fatalf("Recv: %v", err)
	}
	if last.Choices[0].FinishReason != FinishStop {
		t.Errorf("finish_reason = %q, want %q", last.Choices[0].FinishReason, FinishStop)
	}
	if usage := last.Usage; usage == nil || usage.TotalTokens != 12 {
		t.Errorf("usage = %+v", usage)
	}
	if usage := stream.Usage(); usage == nil || usage.PromptTokens != 9 {
		t.Errorf("Usage() = %+v", usage)
	}
	if _, err := stream.Recv(); !errors.Is(err, io.EOF) {
		t.Errorf("Recv = %v, want io.EOF", err)
	}
}

func TestCompleteStreamCollect(t *testing.T) {
	client, _ := serveStream(t)
	stream, err := client.CompleteStream(context.Background(), &Request{Model: deepseek.ModelFlash, Prompt: "def fib(a):"})
	if err != nil {
		t.Fatalf("CompleteStream: %v", err)
	}
	defer stream.Close()

	completion, err := stream.Collect()
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if completion.Object != ObjectTextCompletion || completion.ID != "1f63" || completion.Model != deepseek.ModelFlash {
		t.Errorf("completion = %+v", completion)
	}
	if len(completion.Choices) != 1 {
		t.Fatalf("choices = %d, want 1", len(completion.Choices))
	}
	if text := completion.Text(); text != "    if a < 2:" {
		t.Errorf("Text() = %q", text)
	}
	choice := completion.Choices[0]
	if choice.FinishReason != FinishStop {
		t.Errorf("finish_reason = %q", choice.FinishReason)
	}
	lp := choice.Logprobs
	if lp == nil || len(lp.Tokens) != 2 || lp.Tokens[0] != " a" || lp.TextOffset[1] != 11 || lp.TokenLogprobs[1] != -0.4 {
		t.Errorf("logprobs = %+v", lp)
	}
	if completion.Usage == nil || completion.Usage.TotalTokens != 12 {
		t.Errorf("usage = %+v", completion.Usage)
	}
}

func TestCompleteRejectsStreamFlag(t *testing.T) {
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("no request expected")
	})
	_, err := client.Complete(context.Background(), &Request{Model: deepseek.ModelFlash, Prompt: "x", Stream: true})
	if err == nil || !strings.Contains(err.Error(), "use CompleteStream") {
		t.Fatalf("err = %v", err)
	}
}

// A client that is not bound to the Beta root cannot reach this endpoint.
func TestCompleteNeedsBetaClient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("no request expected")
	}))
	t.Cleanup(srv.Close)
	shared, err := deepseek.NewClient("test-key", deepseek.WithBaseURL(srv.URL))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	client := &Client{Client: shared}
	if _, err := client.Complete(context.Background(), &Request{Model: deepseek.ModelFlash, Prompt: "x"}); err == nil || !strings.Contains(err.Error(), "WithBeta") {
		t.Fatalf("err = %v", err)
	}
}

func TestValidate(t *testing.T) {
	cases := []struct {
		name    string
		request Request
		want    string // "" means the request is valid
	}{
		{
			name:    "minimal",
			request: Request{Model: deepseek.ModelFlash, Prompt: "def fib(a):"},
		},
		{
			name:    "echo alone",
			request: Request{Model: deepseek.ModelFlash, Prompt: "def fib(a):", Echo: new(true)},
		},
		{
			name:    "missing prompt",
			request: Request{Model: deepseek.ModelFlash},
			want:    "prompt is required",
		},
		{
			name:    "echo with suffix",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", Echo: new(true), Suffix: "y"},
			want:    "echo cannot be combined with suffix",
		},
		{
			name:    "echo with logprobs",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", Echo: new(true), Logprobs: new(1)},
			want:    "echo cannot be combined with logprobs",
		},
		{
			name:    "logprobs above the ceiling",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", Logprobs: new(MaxLogprobs + 1)},
			want:    "logprobs must be between",
		},
		{
			name:    "logprobs negative",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", Logprobs: new(-1)},
			want:    "logprobs must be between",
		},
		{
			name:    "max_tokens above the 4K ceiling",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", MaxTokens: new(MaxOutputTokens + 1)},
			want:    "max_tokens must be between 1 and 4096",
		},
		{
			name:    "max_tokens zero",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", MaxTokens: new(0)},
			want:    "max_tokens must be between",
		},
		{
			name:    "too many stop sequences",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", Stop: make(deepseek.StopSequences, MaxStopSequences+1)},
			want:    "at most 16 sequences",
		},
		{
			name:    "empty stop sequence",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", Stop: deepseek.StopSequences{""}},
			want:    "stop sequences must not be empty",
		},
		{
			name:    "temperature out of range",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", Temperature: new(2.5)},
			want:    "temperature must be between 0 and 2",
		},
		{
			name:    "top_p out of range",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", TopP: new(0.0)},
			want:    "top_p must be greater than 0",
		},
		{
			name:    "stream_options without stream",
			request: Request{Model: deepseek.ModelFlash, Prompt: "x", StreamOptions: &deepseek.StreamOptions{IncludeUsage: true}},
			want:    "stream_options requires stream",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.request.Validate()
			switch {
			case tc.want == "" && err != nil:
				t.Fatalf("Validate = %v, want nil", err)
			case tc.want != "" && err == nil:
				t.Fatalf("Validate = nil, want error containing %q", tc.want)
			case tc.want != "" && !strings.Contains(err.Error(), tc.want):
				t.Fatalf("Validate = %q, want error containing %q", err, tc.want)
			}
		})
	}
}

// CompleteStream validates against the response it is about to request, so
// stream_options is allowed there and not in Complete.
func TestValidateStreamMode(t *testing.T) {
	req := &Request{Model: deepseek.ModelFlash, Prompt: "x", StreamOptions: &deepseek.StreamOptions{IncludeUsage: true}}
	if err := req.Validate(); err == nil {
		t.Fatal("Validate accepted stream_options on a non-streaming request")
	}
	if err := req.validate(true); err != nil {
		t.Fatalf("validate(stream=true) = %v, want nil", err)
	}
}

func jsonOf(t *testing.T, v any) string {
	t.Helper()
	encoded, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	return string(encoded)
}
