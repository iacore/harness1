package chat

import (
	"strings"
	"testing"

	"github.com/iacore/harness1/api/deepseek"
)

func TestValidate(t *testing.T) {
	user := &UserMessage{Content: Text("hi")}
	assistant := &AssistantMessage{Content: Text("hello")}
	call := ToolCall{ID: "c1", Type: ToolTypeFunction, Function: FunctionCall{Name: "f", Arguments: "{}"}}
	tool := []Tool{{Function: Function{Name: "f"}}}

	cases := []struct {
		name    string
		request Request
		want    string // "" means the request is valid
	}{
		{
			name:    "minimal",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}},
		},
		{
			name:    "tool call turn",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user, &AssistantMessage{ToolCalls: []ToolCall{call}}, ToolResult("c1", "ok")}},
		},
		{
			name:    "prefix on the last assistant message",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user, &AssistantMessage{Content: Text("```python\n"), Prefix: true}}},
		},
		{
			name:    "thinking disabled allows required tool choice",
			request: Request{Model: deepseek.ModelFlash, Thinking: DisableThinking(), Messages: []Message{user}, Tools: tool, ToolChoice: new(RequiredToolChoice())},
		},
		{
			name:    "assistant tool call replayed with reasoning is allowed",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user, &AssistantMessage{ToolCalls: []ToolCall{call}, ReasoningContent: "why"}, ToolResult("c1", "ok")}, Tools: tool},
		},
		{
			name:    "non-thinking requests need no reasoning",
			request: Request{Model: deepseek.ModelFlash, Thinking: DisableThinking(), Messages: []Message{user, &AssistantMessage{ToolCalls: []ToolCall{call}}, ToolResult("c1", "ok")}, Tools: tool},
		},
		{
			name:    "missing model",
			request: Request{Messages: []Message{user}},
			want:    "model is required",
		},
		{
			name:    "no messages",
			request: Request{Model: deepseek.ModelFlash},
			want:    "at least one message",
		},
		{
			name:    "nil message",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{nil}},
			want:    "messages[0]: message is required",
		},
		{
			name:    "user message without content",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{}}},
			want:    "messages[0]: content is required",
		},
		{
			name:    "system message without content",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&SystemMessage{}}},
			want:    "messages[0]: content is required",
		},
		{
			name:    "tool message without tool_call_id",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user, &ToolMessage{Content: "ok"}}},
			want:    "messages[1]: tool_call_id is required",
		},
		{
			name:    "tool message with an unknown tool_call_id",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user, &AssistantMessage{ToolCalls: []ToolCall{call}}, ToolResult("other", "ok")}},
			want:    "does not match an earlier assistant tool call",
		},
		{
			name:    "duplicate tool call ids",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user, &AssistantMessage{ToolCalls: []ToolCall{call, call}}}},
			want:    "is used more than once",
		},
		{
			name:    "image in an assistant message",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&AssistantMessage{Content: Content{ImageURLPart("https://e.com/a.png", "")}}}},
			want:    "only allowed in user messages",
		},
		{
			name:    "image without a url",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{Content: Content{ImageURLPart("", "")}}}},
			want:    "image_url.url is required",
		},
		{
			name:    "over-long image url",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{Content: Content{ImageURLPart(strings.Repeat("a", MaxImageURLLen+1), "")}}}},
			want:    "at most 8192 characters",
		},
		{
			name:    "unknown image detail",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{Content: Content{ImageURLPart("https://e.com/a.png", "huge")}}}},
			want:    "detail \"huge\" is not supported",
		},
		{
			name:    "file part with both id and data",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{Content: Content{{Type: PartFile, FileID: "file-api-1", FileData: "data:image/png;base64,AA"}}}}},
			want:    "exactly one of file_id and file_data",
		},
		{
			name:    "file part with neither id nor data",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{Content: Content{{Type: PartFile}}}}},
			want:    "exactly one of file_id and file_data",
		},
		{
			name:    "filename without file_data",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{Content: Content{{Type: PartFile, FileID: "file-api-1", Filename: "a.png"}}}}},
			want:    "filename is only valid together with file_data",
		},
		{
			name:    "missing text of a text part",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{Content: Content{TextPart("")}}}},
			want:    "text is required",
		},
		{
			name:    "max_tokens above the ceiling",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, MaxTokens: new(MaxOutputTokens + 1)},
			want:    "max_tokens must be between",
		},
		{
			name:    "max_tokens zero",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, MaxTokens: new(0)},
			want:    "max_tokens must be between",
		},
		{
			name:    "temperature out of range",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, Temperature: new(2.5)},
			want:    "temperature must be between 0 and 2",
		},
		{
			name:    "top_p out of range",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, TopP: new(0.0)},
			want:    "top_p must be greater than 0",
		},
		{
			name:    "top_logprobs above the ceiling",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, Logprobs: new(true), TopLogprobs: new(MaxTopLogprobs + 1)},
			want:    "top_logprobs must be between",
		},
		{
			name:    "top_logprobs without logprobs",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, TopLogprobs: new(1)},
			want:    "logprobs must be true",
		},
		{
			name:    "too many stop sequences",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, Stop: make(deepseek.StopSequences, MaxStopSequences+1)},
			want:    "at most 16 sequences",
		},
		{
			name:    "stream_options without stream",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, StreamOptions: &deepseek.StreamOptions{IncludeUsage: true}},
			want:    "stream_options requires stream",
		},
		{
			name:    "unknown response_format",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, ResponseFormat: &ResponseFormat{typ: "json_schema"}},
			want:    "response_format type \"json_schema\" is not supported",
		},
		{
			name:    "unknown thinking type",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, Thinking: &Thinking{typ: "on"}},
			want:    "thinking type \"on\" is not supported",
		},
		{
			name:    "unknown reasoning_effort",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, ReasoningEffort: "turbo"},
			want:    "reasoning_effort \"turbo\" is not supported",
		},
		{
			name:    "tool without a name",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, Tools: []Tool{{}}},
			want:    "tools[0].function.name is required",
		},
		{
			name:    "tool with a bad name",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, Tools: []Tool{{Function: Function{Name: "get weather"}}}},
			want:    "must be at most 128 characters",
		},
		{
			name:    "duplicate tool names",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, Tools: []Tool{{Function: Function{Name: "f"}}, {Function: Function{Name: "f"}}}},
			want:    "used more than once",
		},
		{
			name:    "required tool choice in thinking mode",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, Tools: tool, ToolChoice: new(RequiredToolChoice())},
			want:    "not supported in thinking mode",
		},
		{
			name:    "named tool choice in thinking mode",
			request: Request{Model: deepseek.ModelFlash, ReasoningEffort: EffortHigh, Messages: []Message{user}, ToolChoice: new(FunctionToolChoice("f"))},
			want:    "not supported in thinking mode",
		},
		{
			name:    "unknown tool choice mode",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, ToolChoice: new(ToolChoice{})},
			want:    "tool_choice \"\" is not supported",
		},
		{
			name:    "tool calling turn needs reasoning when tools are present",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user, &AssistantMessage{ToolCalls: []ToolCall{call}}, ToolResult("c1", "ok")}, Tools: tool},
			want:    "reasoning_content is required",
		},
		{
			name:    "bad user_id",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user}, UserID: "has space"},
			want:    "user_id must be at most",
		},
		{
			name:    "prefix on a message that is not last",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&AssistantMessage{Content: Text("Once"), Prefix: true}, user}},
			want:    "prefix is only allowed on the last message",
		},
		{
			name:    "prefix without content",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user, &AssistantMessage{Prefix: true}}},
			want:    "prefix requires content",
		},
		{
			name:    "assistant without a content string is allowed",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{assistant, &AssistantMessage{}}},
		},
		{
			name:    "empty tool result is allowed",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{user, &AssistantMessage{ToolCalls: []ToolCall{call}}, ToolResult("c1", "")}},
		},
		{
			name:    "empty user content is not",
			request: Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{Content: Text("")}}},
			want:    "content is required",
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

// ChatStream validates against the response it is about to request, so
// stream_options is allowed there and not in Chat.
func TestValidateStreamMode(t *testing.T) {
	req := &Request{Model: deepseek.ModelFlash, Messages: []Message{&UserMessage{Content: Text("hi")}}, StreamOptions: &deepseek.StreamOptions{IncludeUsage: true}}
	if err := req.Validate(); err == nil {
		t.Fatal("Validate accepted stream_options on a non-streaming request")
	}
	if err := req.validate(true); err != nil {
		t.Fatalf("validate(stream=true) = %v, want nil", err)
	}
}
