package chat

import (
	"encoding/json"
	"fmt"
	"regexp"

	"github.com/iacore/harness1/api/deepseek"
)

// Roles of a request or response message.
const (
	RoleSystem    = "system"
	RoleUser      = "user"
	RoleAssistant = "assistant"
	RoleTool      = "tool"
)

// Object types of a completion and of a streamed chunk.
const (
	ObjectCompletion      = "chat.completion"
	ObjectCompletionChunk = "chat.completion.chunk"
)

// finish_reason values.
const (
	FinishStop                       = "stop"
	FinishLength                     = "length"
	FinishContentFilter              = "content_filter"
	FinishToolCalls                  = "tool_calls"
	FinishInsufficientSystemResource = "insufficient_system_resource"
	FinishAborted                    = "aborted"
)

// thinking.type values. Thinking mode is enabled by default.
const (
	ThinkingEnabled  = "enabled"
	ThinkingDisabled = "disabled"
)

// reasoning_effort values. minimal, medium, xhigh and ultra are accepted for
// compatibility with other clients and mapped by the API: minimal to low,
// medium and xhigh to high, ultra to max.
const (
	EffortNone    = "none"
	EffortMinimal = "minimal"
	EffortLow     = "low"
	EffortMedium  = "medium"
	EffortHigh    = "high"
	EffortXHigh   = "xhigh"
	EffortUltra   = "ultra"
	EffortMax     = "max"
)

// response_format types.
const (
	ResponseFormatText       = "text"
	ResponseFormatJSONObject = "json_object"
)

// Content part types.
const (
	PartText     = "text"
	PartImageURL = "image_url"
	PartFile     = "file"
)

// Tool type and tool_choice modes.
const (
	ToolTypeFunction       = "function"
	ToolChoiceModeNone     = "none"
	ToolChoiceModeAuto     = "auto"
	ToolChoiceModeRequired = "required"
)

// Image detail levels accepted in an image_url content part.
const (
	DetailLow      = "low"
	DetailHigh     = "high"
	DetailOriginal = "original"
	DetailAuto     = "auto"
)

// Documented request limits.
const (
	MaxOutputTokens  = 393216 // max_tokens, also the model's maximum output
	MaxStopSequences = 16
	MaxTopLogprobs   = 20
	MaxToolNameLen   = 128
	MaxUserIDLen     = 512
	MaxImageURLLen   = 8192
)

var (
	toolNamePattern = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)
	userIDPattern   = regexp.MustCompile(`^[a-zA-Z0-9\-_]+$`)
)

// Part is one block of a message body: text, an image referenced by URL or
// data URL, or an image file referenced by Files API id or inline data.
type Part struct {
	Type     string    `json:"type"`
	Text     string    `json:"text,omitempty"`
	ImageURL *ImageURL `json:"image_url,omitempty"`
	FileID   string    `json:"file_id,omitempty"`
	FileData string    `json:"file_data,omitempty"`
	Filename string    `json:"filename,omitempty"`
}

// ImageURL addresses an image by http(s) URL or base64 data URL.
type ImageURL struct {
	URL    string `json:"url"`
	Detail string `json:"detail,omitempty"`
}

// TextPart returns a text content part.
func TextPart(text string) Part { return Part{Type: PartText, Text: text} }

// ImageURLPart returns an image content part addressed by URL or data URL.
// detail may be empty for the API default.
func ImageURLPart(url, detail string) Part {
	return Part{Type: PartImageURL, ImageURL: &ImageURL{URL: url, Detail: detail}}
}

// FileIDPart returns an image content part naming a file uploaded with the
// Files API (an id of the form file-api-...).
func FileIDPart(fileID string) Part { return Part{Type: PartFile, FileID: fileID} }

// FileDataPart returns an image content part carrying the image inline as a
// data URL. filename may be empty.
func FileDataPart(fileData, filename string) Part {
	return Part{Type: PartFile, FileData: fileData, Filename: filename}
}

// Content is the body of a message: either plain text or a list of content
// parts. It marshals as a JSON string when it holds a single text part and as
// an array otherwise, and accepts both forms when decoding. The zero value
// marshals as an empty string, which is what the API expects for an assistant
// message that only carries tool calls.
type Content []Part

// Text returns text content, the common case. Empty text is no content at all,
// which is what the API expects for an assistant turn that only calls tools.
func Text(text string) Content {
	if text == "" {
		return nil
	}
	return Content{TextPart(text)}
}

// MarshalJSON encodes a single text part as a plain string.
func (c Content) MarshalJSON() ([]byte, error) {
	if len(c) == 1 && c[0].Type == PartText {
		return json.Marshal(c[0].Text)
	}
	if len(c) == 0 {
		return []byte(`""`), nil
	}
	return json.Marshal([]Part(c))
}

// UnmarshalJSON accepts a plain string or an array of content parts. An empty
// string decodes to the zero value, so that no content and empty content stay
// the same thing.
func (c *Content) UnmarshalJSON(data []byte) error {
	if len(data) > 0 && data[0] == '"' {
		var text string
		if err := json.Unmarshal(data, &text); err != nil {
			return err
		}
		if text == "" {
			*c = nil
		} else {
			*c = Text(text)
		}
		return nil
	}
	if string(data) == "null" {
		*c = nil
		return nil
	}
	var parts []Part
	if err := json.Unmarshal(data, &parts); err != nil {
		return err
	}
	*c = parts
	return nil
}

// Message is one entry of a conversation sent to the API. Which fields apply
// depends on Role: ToolCallID for RoleTool, ToolCalls and ReasoningContent for
// RoleAssistant.
type Message struct {
	Role    string  `json:"role"`
	Content Content `json:"content"`
	Name    string  `json:"name,omitempty"`

	// ToolCallID identifies the tool call a RoleTool message answers.
	ToolCallID string `json:"tool_call_id,omitempty"`

	// ToolCalls are the calls the model requested in a RoleAssistant message.
	ToolCalls []ToolCall `json:"tool_calls,omitempty"`

	// ReasoningContent returns the chain of thought to the API. It is required
	// on every previous assistant message when the request carries tools, and
	// it is the CoT input for a Beta Chat Prefix Completion.
	ReasoningContent string `json:"reasoning_content,omitempty"`

	// Prefix marks a Beta Chat Prefix Completion: the model must start its
	// answer with Content. Only valid on the last message, which must be from
	// the assistant, and requires the Beta API root.
	Prefix bool `json:"prefix,omitempty"`
}

// ToolResult returns a RoleTool message answering the tool call with the given
// id.
func ToolResult(toolCallID, content string) Message {
	return Message{Role: RoleTool, ToolCallID: toolCallID, Content: Text(content)}
}

// Tool describes a function the model may call.
type Tool struct {
	Type     string   `json:"type"`
	Function Function `json:"function"`
}

// Function is the declaration of a callable function. Parameters is a JSON
// Schema object; pass a json.RawMessage to keep it verbatim, or any value that
// marshals to the schema. Leaving it nil declares an empty parameter list.
type Function struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Parameters  any    `json:"parameters,omitempty"`

	// Strict enables Beta strict mode: the arguments must validate against
	// Parameters, which must set additionalProperties to false and list every
	// property as required. Requires the Beta API root.
	Strict bool `json:"strict,omitempty"`
}

// ToolChoice selects the tool the model must call. A zero value is invalid;
// build it with NoToolChoice, AutoToolChoice, RequiredToolChoice or
// FunctionToolChoice.
type ToolChoice struct {
	// Mode is one of the ToolChoiceMode values, and is ignored when Function
	// is set.
	Mode string

	// Function names a specific function to call.
	Function string
}

// NoToolChoice forbids tool calls.
func NoToolChoice() ToolChoice { return ToolChoice{Mode: ToolChoiceModeNone} }

// AutoToolChoice lets the model decide between answering and calling a tool.
func AutoToolChoice() ToolChoice { return ToolChoice{Mode: ToolChoiceModeAuto} }

// RequiredToolChoice forces the model to call one or more tools. Not supported
// in thinking mode.
func RequiredToolChoice() ToolChoice { return ToolChoice{Mode: ToolChoiceModeRequired} }

// FunctionToolChoice forces the model to call the named function. Not
// supported in thinking mode.
func FunctionToolChoice(name string) ToolChoice { return ToolChoice{Function: name} }

// MarshalJSON encodes a mode as a string and a named function as an object.
func (t ToolChoice) MarshalJSON() ([]byte, error) {
	if t.Function == "" {
		return json.Marshal(t.Mode)
	}
	return json.Marshal(struct {
		Type     string `json:"type"`
		Function struct {
			Name string `json:"name"`
		} `json:"function"`
	}{Type: ToolTypeFunction, Function: struct {
		Name string `json:"name"`
	}{Name: t.Function}})
}

// UnmarshalJSON accepts a mode string or a function object.
func (t *ToolChoice) UnmarshalJSON(data []byte) error {
	if len(data) > 0 && data[0] == '"' {
		return json.Unmarshal(data, &t.Mode)
	}
	var obj struct {
		Type     string `json:"type"`
		Function struct {
			Name string `json:"name"`
		} `json:"function"`
	}
	if err := json.Unmarshal(data, &obj); err != nil {
		return err
	}
	if obj.Type != ToolTypeFunction {
		return fmt.Errorf("deepseek: tool_choice type %q is not supported", obj.Type)
	}
	t.Function = obj.Function.Name
	return nil
}

// Thinking toggles the chain of thought. Thinking mode is on by default.
type Thinking struct {
	Type string `json:"type"`
}

// ResponseFormat asks for plain text or for a guaranteed-valid JSON object.
type ResponseFormat struct {
	Type string `json:"type"`
}

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

// Message returns the message of the first choice, or a zero message when the
// response carries no choice.
func (c *Completion) Message() AssistantMessage {
	if len(c.Choices) == 0 {
		return AssistantMessage{}
	}
	return c.Choices[0].Message
}

// Choice is one completed alternative.
type Choice struct {
	Index        int              `json:"index"`
	FinishReason string           `json:"finish_reason"`
	Message      AssistantMessage `json:"message"`
	Logprobs     *Logprobs        `json:"logprobs,omitempty"`
}

// AssistantMessage is a message generated by the model. Content is empty when
// the API answered with null or with an empty string.
type AssistantMessage struct {
	Role             string     `json:"role"`
	Content          string     `json:"content"`
	ReasoningContent string     `json:"reasoning_content,omitempty"`
	ToolCalls        []ToolCall `json:"tool_calls,omitempty"`
}

// Message converts the generated message into a request message, keeping the
// chain of thought and the tool calls, which the API requires to be sent back
// on every tool-calling turn.
func (m AssistantMessage) Message() Message {
	role := m.Role
	if role == "" {
		role = RoleAssistant
	}
	return Message{
		Role:             role,
		Content:          Text(m.Content),
		ReasoningContent: m.ReasoningContent,
		ToolCalls:        m.ToolCalls,
	}
}

// ToolCall is a function call requested by the model; in a streamed delta it is
// a fragment of one, identified by Index.
type ToolCall struct {
	ID       string       `json:"id,omitempty"`
	Type     string       `json:"type,omitempty"`
	Function FunctionCall `json:"function"`
	Index    *int         `json:"index,omitempty"`
}

// MarshalJSON writes the request form of a tool call. Index belongs to the
// streamed deltas it was decoded from, and is not part of a request.
func (t ToolCall) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		ID       string       `json:"id,omitempty"`
		Type     string       `json:"type,omitempty"`
		Function FunctionCall `json:"function"`
	}{ID: t.ID, Type: t.Type, Function: t.Function})
}

// FunctionCall is the name of a tool and its arguments, JSON-encoded as a
// string.
type FunctionCall struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

// Logprobs carries the log probabilities of the generated tokens. In thinking
// mode the chain of thought has its own list.
type Logprobs struct {
	Content          []TokenLogprob `json:"content"`
	ReasoningContent []TokenLogprob `json:"reasoning_content,omitempty"`
}

// TokenLogprob is the log probability of one generated token.
type TokenLogprob struct {
	Token       string       `json:"token"`
	Logprob     float64      `json:"logprob"`
	Bytes       []int        `json:"bytes"`
	TopLogprobs []TopLogprob `json:"top_logprobs"`
}

// TopLogprob is one of the most likely alternatives at a token position.
type TopLogprob struct {
	Token   string  `json:"token"`
	Logprob float64 `json:"logprob"`
	Bytes   []int   `json:"bytes"`
}
