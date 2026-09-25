package chat

import (
	"errors"
	"fmt"
	"strings"
)

// Validate reports whether the request satisfies the constraints the API
// documents for POST /chat/completions, so that a request the API would reject
// is caught before it is sent. Chat and ChatStream call it, with the streaming
// flag of the method they were called as, so callers rarely need it. Only
// documented constraints are checked; whether the model accepts a schema, for
// instance, is left to the server.
func (r *Request) Validate() error { return r.validate(r.Stream) }

func (r *Request) validate(stream bool) error {
	if strings.TrimSpace(r.Model) == "" {
		return errors.New("deepseek: model is required")
	}
	if len(r.Messages) == 0 {
		return errors.New("deepseek: at least one message is required")
	}
	last := len(r.Messages) - 1
	for i, m := range r.Messages {
		if err := validateMessage(m, i, last); err != nil {
			return err
		}
	}
	if r.MaxTokens != nil && (*r.MaxTokens < 1 || *r.MaxTokens > MaxOutputTokens) {
		return fmt.Errorf("deepseek: max_tokens must be between 1 and %d, got %d", MaxOutputTokens, *r.MaxTokens)
	}
	if r.Temperature != nil && !(*r.Temperature >= 0 && *r.Temperature <= 2) {
		return fmt.Errorf("deepseek: temperature must be between 0 and 2, got %v", *r.Temperature)
	}
	if r.TopP != nil && !(*r.TopP > 0 && *r.TopP <= 1) {
		return fmt.Errorf("deepseek: top_p must be greater than 0 and at most 1, got %v", *r.TopP)
	}
	if r.TopLogprobs != nil {
		if *r.TopLogprobs < 0 || *r.TopLogprobs > MaxTopLogprobs {
			return fmt.Errorf("deepseek: top_logprobs must be between 0 and %d, got %d", MaxTopLogprobs, *r.TopLogprobs)
		}
		if r.Logprobs == nil || !*r.Logprobs {
			return errors.New("deepseek: logprobs must be true when top_logprobs is set")
		}
	}
	if len(r.Stop) > MaxStopSequences {
		return fmt.Errorf("deepseek: stop accepts at most %d sequences, got %d", MaxStopSequences, len(r.Stop))
	}
	for _, stop := range r.Stop {
		if stop == "" {
			return errors.New("deepseek: stop sequences must not be empty")
		}
	}
	if r.StreamOptions != nil && !stream {
		return errors.New("deepseek: stream_options requires stream")
	}
	if r.ResponseFormat != nil {
		switch r.ResponseFormat.Type {
		case ResponseFormatText, ResponseFormatJSONObject:
		default:
			return fmt.Errorf("deepseek: response_format type %q is not supported", r.ResponseFormat.Type)
		}
	}
	if r.Thinking != nil {
		switch r.Thinking.Type {
		case ThinkingEnabled, ThinkingDisabled:
		default:
			return fmt.Errorf("deepseek: thinking type %q is not supported", r.Thinking.Type)
		}
	}
	switch r.ReasoningEffort {
	case "", EffortNone, EffortMinimal, EffortLow, EffortMedium, EffortHigh, EffortXHigh, EffortUltra, EffortMax:
	default:
		return fmt.Errorf("deepseek: reasoning_effort %q is not supported", r.ReasoningEffort)
	}
	if err := validateTools(r.Tools); err != nil {
		return err
	}
	if r.ToolChoice != nil {
		if err := validateToolChoice(*r.ToolChoice, r.thinking()); err != nil {
			return err
		}
	}
	if r.UserID != "" && (len(r.UserID) > MaxUserIDLen || !userIDPattern.MatchString(r.UserID)) {
		return fmt.Errorf("deepseek: user_id must be at most %d characters of %s", MaxUserIDLen, userIDPattern)
	}
	return nil
}

// thinking reports whether the request runs in thinking mode, which is the
// default and is turned off either by thinking.type or by reasoning_effort.
func (r *Request) thinking() bool {
	if r.Thinking != nil {
		return r.Thinking.Type != ThinkingDisabled
	}
	return r.ReasoningEffort != EffortNone
}

func validateMessage(m Message, index, last int) error {
	fail := func(format string, args ...any) error {
		return fmt.Errorf("deepseek: messages[%d]: %s", index, fmt.Sprintf(format, args...))
	}
	switch m.Role {
	case RoleSystem, RoleUser, RoleAssistant, RoleTool:
	default:
		return fail("role %q is not supported", m.Role)
	}
	// A system or user message without content is meaningless; an assistant
	// turn may only call tools, and a tool may return nothing.
	if (m.Role == RoleSystem || m.Role == RoleUser) && len(m.Content) == 0 {
		return fail("content is required")
	}
	for i, part := range m.Content {
		if err := validatePart(part, m.Role); err != nil {
			return fail("content[%d]: %s", i, err)
		}
	}
	if m.Prefix {
		if index != last {
			return fail("prefix is only allowed on the last message")
		}
		if m.Role != RoleAssistant {
			return fail("prefix requires the %s role", RoleAssistant)
		}
	}
	if m.Role == RoleTool && m.ToolCallID == "" {
		return fail("tool_call_id is required for %s messages", RoleTool)
	}
	for i, call := range m.ToolCalls {
		switch {
		case call.ID == "":
			return fail("tool_calls[%d].id is required", i)
		case call.Type != ToolTypeFunction:
			return fail("tool_calls[%d].type %q is not supported", i, call.Type)
		case call.Function.Name == "":
			return fail("tool_calls[%d].function.name is required", i)
		}
	}
	return nil
}

func validatePart(p Part, role string) error {
	switch p.Type {
	case PartText:
		if p.Text == "" {
			return errors.New("text is required for text parts")
		}
	case PartImageURL:
		if role != RoleUser {
			return fmt.Errorf("%s parts are only allowed in %s messages", PartImageURL, RoleUser)
		}
		if p.ImageURL == nil || p.ImageURL.URL == "" {
			return errors.New("image_url.url is required for image_url parts")
		}
		if len(p.ImageURL.URL) > MaxImageURLLen {
			return fmt.Errorf("image_url.url must be at most %d characters", MaxImageURLLen)
		}
		switch p.ImageURL.Detail {
		case "", DetailLow, DetailHigh, DetailOriginal, DetailAuto:
		default:
			return fmt.Errorf("image_url.detail %q is not supported", p.ImageURL.Detail)
		}
	case PartFile:
		if role != RoleUser {
			return fmt.Errorf("%s parts are only allowed in %s messages", PartFile, RoleUser)
		}
		if (p.FileID == "") == (p.FileData == "") {
			return errors.New("file parts need exactly one of file_id and file_data")
		}
		if p.Filename != "" && p.FileData == "" {
			return errors.New("filename is only valid together with file_data")
		}
	default:
		return fmt.Errorf("content part type %q is not supported", p.Type)
	}
	return nil
}

func validateTools(tools []Tool) error {
	seen := make(map[string]bool, len(tools))
	for i, tool := range tools {
		if tool.Type != ToolTypeFunction {
			return fmt.Errorf("deepseek: tools[%d].type %q is not supported; only %q is", i, tool.Type, ToolTypeFunction)
		}
		name := tool.Function.Name
		if name == "" {
			return fmt.Errorf("deepseek: tools[%d].function.name is required", i)
		}
		if len(name) > MaxToolNameLen || !toolNamePattern.MatchString(name) {
			return fmt.Errorf("deepseek: tools[%d].function.name %q must be at most %d characters of %s", i, name, MaxToolNameLen, toolNamePattern)
		}
		if seen[name] {
			return fmt.Errorf("deepseek: tools[%d].function.name %q is used more than once", i, name)
		}
		seen[name] = true
	}
	return nil
}

func validateToolChoice(choice ToolChoice, thinking bool) error {
	if choice.Function != "" {
		if len(choice.Function) > MaxToolNameLen || !toolNamePattern.MatchString(choice.Function) {
			return fmt.Errorf("deepseek: tool_choice function %q must be at most %d characters of %s", choice.Function, MaxToolNameLen, toolNamePattern)
		}
		if thinking {
			return errors.New("deepseek: naming a function in tool_choice is not supported in thinking mode")
		}
		return nil
	}
	switch choice.Mode {
	case ToolChoiceModeNone, ToolChoiceModeAuto:
		return nil
	case ToolChoiceModeRequired:
		if thinking {
			return errors.New("deepseek: tool_choice \"required\" is not supported in thinking mode")
		}
		return nil
	default:
		return fmt.Errorf("deepseek: tool_choice %q is not supported", choice.Mode)
	}
}
