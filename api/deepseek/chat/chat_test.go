package chat

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

func testClient(t *testing.T, handler http.HandlerFunc, opts ...deepseek.Option) *Client {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	client, err := NewClient("test-key", append([]deepseek.Option{deepseek.WithBaseURL(srv.URL)}, opts...)...)
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
	if got := r.Header.Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got)
	}
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		t.Fatalf("decoding request body: %v", err)
	}
	return body
}

func TestChatRequestWireFormat(t *testing.T) {
	var got map[string]any
	// A strict tool needs the Beta root, which appends /beta to the base URL.
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		got = checkRequest(t, r, "/beta/chat/completions")
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"id":"x","object":"chat.completion","choices":[]}`)
	}, deepseek.WithBeta())

	req := &Request{
		Model:           deepseek.ModelFlash,
		Messages:        []Message{&SystemMessage{Text: "be brief"}, &UserMessage{Content: Text("hi")}},
		Thinking:        EnableThinking(),
		ReasoningEffort: EffortMax,
		MaxTokens:       new(512),
		ResponseFormat:  JSONResponseFormat(),
		Stop:            deepseek.StopSequences{"END"},
		Temperature:     new(0.2),
		TopP:            new(0.99),
		Tools: []Tool{{
			Function: Function{
				Name:        "get_weather",
				Description: "Get the weather.",
				Parameters:  json.RawMessage(`{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}`),
				Strict:      true,
			},
		}},
		ToolChoice:  new(AutoToolChoice()),
		Logprobs:    new(true),
		TopLogprobs: new(3),
		UserID:      "user-1",
	}

	if _, err := client.Chat(context.Background(), req); err != nil {
		t.Fatalf("Chat: %v", err)
	}

	want := map[string]any{
		"model": "deepseek-flash",
		"messages": []any{
			map[string]any{"role": "system", "content": "be brief"},
			map[string]any{"role": "user", "content": "hi"},
		},
		"thinking":         map[string]any{"type": "enabled"},
		"reasoning_effort": "max",
		"max_tokens":       float64(512),
		"response_format":  map[string]any{"type": "json_object"},
		"stop":             "END",
		"temperature":      0.2,
		"top_p":            0.99,
		"tools": []any{map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        "get_weather",
				"description": "Get the weather.",
				"parameters": map[string]any{
					"type":                 "object",
					"properties":           map[string]any{"city": map[string]any{"type": "string"}},
					"required":             []any{"city"},
					"additionalProperties": false,
				},
				"strict": true,
			},
		}},
		"tool_choice":  "auto",
		"logprobs":     true,
		"top_logprobs": float64(3),
		"user_id":      "user-1",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("request body mismatch\n got: %s\nwant: %s", jsonOf(t, got), jsonOf(t, want))
	}
}

func TestChatOmitsUnsetParameters(t *testing.T) {
	var body []byte
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		body = json.RawMessage(jsonOf(t, checkRequest(t, r, "/chat/completions")))
		io.WriteString(w, `{"id":"x","object":"chat.completion","choices":[]}`)
	})
	if _, err := client.Chat(context.Background(), &Request{
		Model:    deepseek.ModelV4Pro,
		Messages: []Message{&UserMessage{Content: Text("hi")}},
	}); err != nil {
		t.Fatalf("Chat: %v", err)
	}
	want := `{"messages":[{"content":"hi","role":"user"}],"model":"deepseek-v4-pro"}`
	if string(body) != want {
		t.Errorf("body = %s, want %s", body, want)
	}
}

func TestChatMessageVariantsWireFormat(t *testing.T) {
	var got map[string]any
	// The prefix message makes this a Beta request: the root gains /beta.
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		got = checkRequest(t, r, "/beta/chat/completions")
		io.WriteString(w, `{"id":"x","choices":[]}`)
	}, deepseek.WithBeta())

	if _, err := client.Chat(context.Background(), &Request{
		Model: deepseek.ModelFlash,
		Messages: []Message{
			&UserMessage{Content: Content{TextPart("what is this?"), ImageURLPart("https://example.com/a.png", DetailLow)}},
			&AssistantMessage{ToolCalls: []ToolCall{{
				ID:       "call_1",
				Type:     ToolTypeFunction,
				Function: FunctionCall{Name: "get_weather", Arguments: `{"city":"Hangzhou"}`},
				Index:    new(0),
			}}},
			ToolResult("call_1", "24C"),
			&AssistantMessage{Content: Text("It is "), Prefix: true, ReasoningContent: "thinking"},
		},
		ToolChoice: new(NoToolChoice()),
	}); err != nil {
		t.Fatalf("Chat: %v", err)
	}

	want := []any{
		map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "text", "text": "what is this?"},
			map[string]any{"type": "image_url", "image_url": map[string]any{"url": "https://example.com/a.png", "detail": "low"}},
		}},
		// An assistant turn that only calls a tool sends content as an empty
		// string, and a streamed chunk's index never leaks into a request.
		map[string]any{"role": "assistant", "content": "", "tool_calls": []any{map[string]any{
			"id":   "call_1",
			"type": "function",
			"function": map[string]any{
				"name":      "get_weather",
				"arguments": `{"city":"Hangzhou"}`,
			},
		}}},
		map[string]any{"role": "tool", "content": "24C", "tool_call_id": "call_1"},
		map[string]any{"role": "assistant", "content": "It is ", "prefix": true, "reasoning_content": "thinking"},
	}
	if !reflect.DeepEqual(got["messages"], want) {
		t.Errorf("messages mismatch\n got: %s\nwant: %s", jsonOf(t, got["messages"]), jsonOf(t, want))
	}
	if got["tool_choice"] != "none" {
		t.Errorf("tool_choice = %v, want none", got["tool_choice"])
	}
}

func TestChatParsesResponse(t *testing.T) {
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{
			"id": "930c60df",
			"object": "chat.completion",
			"created": 1705651092,
			"model": "deepseek-flash",
			"system_fingerprint": "fp_7a09fdf9c2",
			"choices": [{
				"index": 0,
				"finish_reason": "tool_calls",
				"message": {
					"role": "assistant",
					"content": "",
					"reasoning_content": "I should check the weather.",
					"tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\":\"Hangzhou\"}"}}]
				},
				"logprobs": {"content": [{"token": "The", "logprob": -0.1, "bytes": [84], "top_logprobs": [{"token": "The", "logprob": -0.1, "bytes": [84]}]}]}
			}],
			"usage": {
				"completion_tokens": 43,
				"prompt_tokens": 17,
				"total_tokens": 60,
				"prompt_cache_hit_tokens": 1,
				"prompt_cache_miss_tokens": 16,
				"prompt_tokens_details": {"cached_tokens": 1},
				"completion_tokens_details": {"reasoning_tokens": 30}
			}
		}`)
	})

	got, err := client.Chat(context.Background(), &Request{
		Model:    deepseek.ModelFlash,
		Messages: []Message{&UserMessage{Content: Text("weather?")}},
	})
	if err != nil {
		t.Fatalf("Chat: %v", err)
	}
	if got.ID != "930c60df" || got.Created != 1705651092 || got.Model != deepseek.ModelFlash || got.SystemFingerprint != "fp_7a09fdf9c2" {
		t.Errorf("completion header = %+v", got)
	}
	if len(got.Choices) != 1 {
		t.Fatalf("choices = %d, want 1", len(got.Choices))
	}
	choice := got.Choices[0]
	if choice.FinishReason != FinishToolCalls || choice.Index != 0 {
		t.Errorf("choice = %+v", choice)
	}
	if choice.Message.ReasoningContent != "I should check the weather." {
		t.Errorf("reasoning_content = %q", choice.Message.ReasoningContent)
	}
	if len(choice.Message.ToolCalls) != 1 || choice.Message.ToolCalls[0].Function.Arguments != `{"city":"Hangzhou"}` {
		t.Errorf("tool_calls = %+v", choice.Message.ToolCalls)
	}
	if choice.Logprobs == nil || len(choice.Logprobs.Content) != 1 || choice.Logprobs.Content[0].Bytes[0] != 84 {
		t.Errorf("logprobs = %+v", choice.Logprobs)
	}
	if got.Usage == nil || got.Usage.TotalTokens != 60 || got.Usage.PromptTokens != got.Usage.PromptCacheHitTokens+got.Usage.PromptCacheMissTokens {
		t.Errorf("usage = %+v", got.Usage)
	}
	if got.Usage.PromptTokensDetails.CachedTokens != 1 || got.Usage.CompletionTokensDetails.ReasoningTokens != 30 {
		t.Errorf("usage details = %+v %+v", got.Usage.PromptTokensDetails, got.Usage.CompletionTokensDetails)
	}

	// The assistant message replays into the next request with its chain of
	// thought and tool calls intact.
	replay := got.Message().Message()
	if replay.Role() != RoleAssistant || len(replay.Content) != 0 || replay.ReasoningContent != "I should check the weather." {
		t.Errorf("replayed message = %+v", replay)
	}
	if len(replay.ToolCalls) != 1 || replay.ToolCalls[0].ID != "call_1" {
		t.Errorf("replayed tool calls = %+v", replay.ToolCalls)
	}
}

// A tool-calling conversation replays the model's turn verbatim, chain of
// thought and tool calls included, which the API requires when the request
// carries tools.
func TestToolCallReplayRoundTrip(t *testing.T) {
	round := 0
	var bodies []string
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		body := checkRequest(t, r, "/chat/completions")
		bodies = append(bodies, jsonOf(t, body["messages"]))
		round++
		if round == 1 {
			io.WriteString(w, `{
				"id": "1", "object": "chat.completion", "choices": [{
					"index": 0, "finish_reason": "tool_calls",
					"message": {
						"role": "assistant", "content": "", "reasoning_content": "check the weather",
						"tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\":\"Hangzhou\"}"}}]
					}
				}]
			}`)
			return
		}
		io.WriteString(w, `{"id": "2", "object": "chat.completion", "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "Cloudy."}}]}`)
	})

	tools := []Tool{{Function: Function{Name: "get_weather"}}}
	messages := []Message{&UserMessage{Content: Text("weather?")}}
	first, err := client.Chat(context.Background(), &Request{Model: deepseek.ModelFlash, Messages: messages, Tools: tools})
	if err != nil {
		t.Fatalf("first Chat: %v", err)
	}
	messages = append(messages, first.Message().Message(), ToolResult(first.Message().ToolCalls[0].ID, ""))

	second, err := client.Chat(context.Background(), &Request{Model: deepseek.ModelFlash, Messages: messages, Tools: tools})
	if err != nil {
		t.Fatalf("second Chat: %v", err)
	}
	if second.Message().Content != "Cloudy." {
		t.Errorf("second answer = %q", second.Message().Content)
	}

	want := `[{"content":"weather?","role":"user"},` +
		`{"content":"","reasoning_content":"check the weather","role":"assistant","tool_calls":[{"function":{"arguments":"{\"city\":\"Hangzhou\"}","name":"get_weather"},"id":"call_1","type":"function"}]},` +
		`{"content":"","role":"tool","tool_call_id":"call_1"}]`
	if bodies[1] != want {
		t.Errorf("replayed conversation = %s\nwant %s", bodies[1], want)
	}
}

func TestChatRejectsStreamFlag(t *testing.T) {
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("no request expected")
	})
	_, err := client.Chat(context.Background(), &Request{
		Model:    deepseek.ModelFlash,
		Stream:   true,
		Messages: []Message{&UserMessage{Content: Text("hi")}},
	})
	if err == nil || !strings.Contains(err.Error(), "use ChatStream") {
		t.Fatalf("err = %v", err)
	}
}

func TestChatWithoutAPIKey(t *testing.T) {
	if _, err := NewClient("  "); err == nil {
		t.Fatal("NewClient accepted an empty key")
	}
}

// streamEvents is a canned response stream: a keep-alive comment, an opening
// chunk, content and reasoning deltas, two tool calls whose arguments arrive in
// fragments, and a last chunk that carries the finish reason and the usage.
var streamEvents = []string{
	`{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","system_fingerprint":"fp_a49","choices":[{"index":0,"delta":{"content":"","role":"assistant"},"finish_reason":null,"logprobs":null}]}`,
	`{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"delta":{"content":"The answer is ","reasoning_content":"2+2"},"finish_reason":null}]}`,
	`{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"ci"}}]},"finish_reason":null}]}`,
	`{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_2","type":"function","function":{"name":"get_date","arguments":"{}"}}]},"finish_reason":null}]}`,
	`{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\":\"Hangzhou\"}"}}]},"finish_reason":null}]}`,
	`{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"delta":{"content":""},"finish_reason":"tool_calls","logprobs":{"content":[{"token":"4","logprob":-0.5,"bytes":[52],"top_logprobs":null}]}}],"usage":{"completion_tokens":9,"prompt_tokens":17,"total_tokens":26,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":17}}`,
	"[DONE]",
}

// serveStream answers with streamEvents, after checking the request and
// returning its body.
func serveStream(t *testing.T, wantPath string) (*Client, *map[string]any) {
	t.Helper()
	got := new(map[string]any)
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		*got = checkRequest(t, r, wantPath)
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

func streamRequest() *Request {
	return &Request{
		Model:    deepseek.ModelFlash,
		Messages: []Message{&UserMessage{Content: Text("weather and date?")}},
		Tools:    []Tool{{Function: Function{Name: "get_weather"}}},
	}
}

// Recv yields the chunks one by one, as an agent that renders tokens does.
func TestChatStreamRecv(t *testing.T) {
	client, got := serveStream(t, "/chat/completions")
	stream, err := client.ChatStream(context.Background(), streamRequest())
	if err != nil {
		t.Fatalf("ChatStream: %v", err)
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
	if first.Object != ObjectCompletionChunk || first.ID != "1f63" || first.Created != 1718345013 {
		t.Errorf("first chunk = %+v", first)
	}
	if delta := first.Choices[0].Delta; delta.Role != RoleAssistant || delta.Content != "" {
		t.Errorf("first delta = %+v", delta)
	}
	if first.Choices[0].FinishReason != "" || first.Choices[0].Logprobs != nil {
		t.Errorf("first choice = %+v", first.Choices[0])
	}

	if chunk, err := stream.Recv(); err != nil {
		t.Fatalf("Recv: %v", err)
	} else if delta := chunk.Choices[0].Delta; delta.Content != "The answer is " || delta.ReasoningContent != "2+2" {
		t.Errorf("second delta = %+v", delta)
	}

	// The first fragment of a tool call carries its id, type and name.
	if chunk, err := stream.Recv(); err != nil {
		t.Fatalf("Recv: %v", err)
	} else {
		call := chunk.Choices[0].Delta.ToolCalls[0]
		if call.Index == nil || *call.Index != 0 || call.ID != "call_1" || call.Type != ToolTypeFunction || call.Function.Name != "get_weather" || call.Function.Arguments != `{"ci` {
			t.Errorf("first tool fragment = %+v", call)
		}
	}

	// A second call opens with its own fragment.
	if chunk, err := stream.Recv(); err != nil {
		t.Fatalf("Recv: %v", err)
	} else {
		call := chunk.Choices[0].Delta.ToolCalls[0]
		if call.Index == nil || *call.Index != 1 || call.ID != "call_2" || call.Function.Name != "get_date" || call.Function.Arguments != "{}" {
			t.Errorf("second tool fragment = %+v", call)
		}
	}

	// Later fragments of a call only extend its arguments.
	if chunk, err := stream.Recv(); err != nil {
		t.Fatalf("Recv: %v", err)
	} else {
		call := chunk.Choices[0].Delta.ToolCalls[0]
		if call.ID != "" || call.Function.Name != "" || call.Function.Arguments != `ty":"Hangzhou"}` {
			t.Errorf("continuation fragment = %+v", call)
		}
	}

	// The last chunk closes the choice and carries the usage of the request.
	chunk, err := stream.Recv()
	if err != nil {
		t.Fatalf("Recv: %v", err)
	}
	if chunk.Choices[0].FinishReason != FinishToolCalls {
		t.Errorf("finish_reason = %q, want %q", chunk.Choices[0].FinishReason, FinishToolCalls)
	}
	if usage := chunk.Usage; usage == nil || usage.TotalTokens != 26 || usage.CompletionTokensDetails != nil {
		t.Errorf("usage = %+v", usage)
	}
	if lp := chunk.Choices[0].Logprobs; lp == nil || len(lp.Content) != 1 || lp.Content[0].Token != "4" {
		t.Errorf("logprobs = %+v", lp)
	}
	if usage := stream.Usage(); usage == nil || usage.PromptCacheMissTokens != 17 {
		t.Errorf("Usage() = %+v", usage)
	}

	// The sentinel ends the stream, and it stays ended.
	if _, err := stream.Recv(); !errors.Is(err, io.EOF) {
		t.Errorf("Recv = %v, want io.EOF", err)
	}
	if _, err := stream.Recv(); !errors.Is(err, io.EOF) {
		t.Errorf("Recv after [DONE] = %v, want io.EOF", err)
	}
}

// Collect assembles the whole stream into the same shape Chat returns.
func TestChatStreamCollect(t *testing.T) {
	client, _ := serveStream(t, "/chat/completions")
	stream, err := client.ChatStream(context.Background(), streamRequest())
	if err != nil {
		t.Fatalf("ChatStream: %v", err)
	}
	defer stream.Close()

	completion, err := stream.Collect()
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if completion.Object != ObjectCompletion || completion.ID != "1f63" || completion.Created != 1718345013 || completion.Model != deepseek.ModelFlash {
		t.Errorf("completion = %+v", completion)
	}
	if len(completion.Choices) != 1 {
		t.Fatalf("choices = %d, want 1", len(completion.Choices))
	}
	choice := completion.Choices[0]
	if choice.Index != 0 || choice.FinishReason != FinishToolCalls {
		t.Errorf("choice = %+v", choice)
	}
	if message := choice.Message; message.Role != RoleAssistant || message.Content != "The answer is " || message.ReasoningContent != "2+2" {
		t.Errorf("message = %+v", message)
	}
	if len(choice.Message.ToolCalls) != 2 {
		t.Fatalf("tool calls = %+v", choice.Message.ToolCalls)
	}
	if first := choice.Message.ToolCalls[0]; first.ID != "call_1" || first.Function.Name != "get_weather" || first.Function.Arguments != `{"city":"Hangzhou"}` {
		t.Errorf("first tool call = %+v", first)
	}
	if second := choice.Message.ToolCalls[1]; second.ID != "call_2" || second.Function.Name != "get_date" || second.Function.Arguments != "{}" {
		t.Errorf("second tool call = %+v", second)
	}
	if lp := choice.Logprobs; lp == nil || len(lp.Content) != 1 || lp.Content[0].Logprob != -0.5 {
		t.Errorf("logprobs = %+v", lp)
	}
	if completion.Usage == nil || completion.Usage.PromptTokens != 17 {
		t.Errorf("usage = %+v", completion.Usage)
	}
}

func TestChatStreamReportsAPIError(t *testing.T) {
	client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, `{"error":{"message":"reasoning_content is missing","type":"invalid_request_error","code":"invalid_request_error"}}`)
	})
	_, err := client.ChatStream(context.Background(), streamRequest())
	var apiErr *deepseek.APIError
	if !errors.As(err, &apiErr) || apiErr.StatusCode != http.StatusBadRequest || apiErr.Message != "reasoning_content is missing" {
		t.Fatalf("err = %v", err)
	}
}

func TestChatBetaRequirements(t *testing.T) {
	strictTool := []Tool{{Function: Function{Name: "f", Strict: true}}}
	prefix := []Message{&UserMessage{Content: Text("hi")}, &AssistantMessage{Content: Text("Once"), Prefix: true}}

	t.Run("strict tools need the beta root", func(t *testing.T) {
		client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			t.Error("no request expected")
		})
		_, err := client.Chat(context.Background(), &Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{Content: Text("hi")}}, Tools: strictTool})
		if err == nil || !strings.Contains(err.Error(), "WithBeta") {
			t.Fatalf("err = %v", err)
		}
	})

	t.Run("prefix completion needs the beta root", func(t *testing.T) {
		client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			t.Error("no request expected")
		})
		_, err := client.Chat(context.Background(), &Request{Model: deepseek.ModelFlash, Messages: prefix})
		if err == nil || !strings.Contains(err.Error(), "WithBeta") {
			t.Fatalf("err = %v", err)
		}
	})

	t.Run("beta root is used", func(t *testing.T) {
		var path string
		client := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			path = r.URL.Path
			io.WriteString(w, `{"id":"x","choices":[]}`)
		}, deepseek.WithBeta())
		if _, err := client.Chat(context.Background(), &Request{Model: deepseek.ModelFlash, Messages: prefix, Tools: strictTool}); err != nil {
			t.Fatalf("Chat: %v", err)
		}
		if path != "/beta/chat/completions" {
			t.Errorf("path = %q, want /beta/chat/completions", path)
		}
	})
}

func TestMessageRoles(t *testing.T) {
	cases := []struct {
		m    Message
		role string
	}{
		{&SystemMessage{Text: "x"}, RoleSystem},
		{&UserMessage{Content: Text("x")}, RoleUser},
		{&AssistantMessage{}, RoleAssistant},
		{&ToolMessage{}, RoleTool},
	}
	for _, tc := range cases {
		if got := tc.m.Role(); got != tc.role {
			t.Errorf("Role() = %q, want %q", got, tc.role)
		}
	}
}

func TestContentJSONForms(t *testing.T) {
	cases := []struct {
		name string
		in   Content
		json string
	}{
		{"empty", nil, `""`},
		{"text", Text("hi"), `"hi"`},
		{"parts", Content{TextPart("hi"), ImageURLPart("https://e.com/a.png", "")},
			`[{"type":"text","text":"hi"},{"type":"image_url","image_url":{"url":"https://e.com/a.png"}}]`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			encoded, err := json.Marshal(tc.in)
			if err != nil {
				t.Fatalf("Marshal: %v", err)
			}
			if string(encoded) != tc.json {
				t.Errorf("Marshal = %s, want %s", encoded, tc.json)
			}
			var decoded Content
			if err := json.Unmarshal([]byte(tc.json), &decoded); err != nil {
				t.Fatalf("Unmarshal: %v", err)
			}
			if got := jsonOf(t, decoded); got != tc.json {
				t.Errorf("Unmarshal(%s) re-encodes as %s", tc.json, got)
			}
		})
	}
}

func TestToolChoiceJSONForms(t *testing.T) {
	cases := []struct {
		in   ToolChoice
		json string
	}{
		{AutoToolChoice(), `"auto"`},
		{RequiredToolChoice(), `"required"`},
		{FunctionToolChoice("get_weather"), `{"type":"function","function":{"name":"get_weather"}}`},
	}
	for _, tc := range cases {
		encoded, err := json.Marshal(tc.in)
		if err != nil {
			t.Fatalf("Marshal: %v", err)
		}
		if string(encoded) != tc.json {
			t.Errorf("Marshal(%+v) = %s, want %s", tc.in, encoded, tc.json)
		}
		var decoded ToolChoice
		if err := json.Unmarshal([]byte(tc.json), &decoded); err != nil {
			t.Fatalf("Unmarshal(%s): %v", tc.json, err)
		}
		if !reflect.DeepEqual(decoded, tc.in) {
			t.Errorf("Unmarshal(%s) = %+v, want %+v", tc.json, decoded, tc.in)
		}
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
