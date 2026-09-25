// Package deepseek holds what the DeepSeek API endpoints share: the
// authenticated client and its options, the error envelope, the server-sent
// event reader, and the usage, stop-sequence and stream-option types.
//
// The endpoints themselves are separate packages:
//
//   - github.com/iacore/harness1/api/deepseek/chat, for POST /chat/completions
//   - github.com/iacore/harness1/api/deepseek/fim, for the Beta FIM completion
//     endpoint POST /completions
//
// One client serves both. Everything here uses the standard library.
package deepseek

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// DefaultBaseURL is the OpenAI-compatible API root. The Beta root, which the
// FIM endpoint always needs and the Chat Completions endpoint needs for prefix
// completion and strict tool calls, is this root with "/beta" appended and is
// selected with WithBeta.
const DefaultBaseURL = "https://api.deepseek.com"

// Client sends requests to the DeepSeek API. It is safe for concurrent use.
type Client struct {
	apiKey  string
	baseURL string
	beta    bool
	http    *http.Client
}

// Option configures a Client.
type Option func(*Client)

// WithBaseURL points the client at another API root, such as a proxy. A
// trailing slash is optional.
func WithBaseURL(baseURL string) Option {
	return func(c *Client) { c.baseURL = strings.TrimRight(baseURL, "/") }
}

// WithHTTPClient replaces the HTTP client. The default client sets no timeout,
// so the deadline of a call comes from its context.
func WithHTTPClient(hc *http.Client) Option {
	return func(c *Client) { c.http = hc }
}

// WithBeta routes requests through the Beta API root. The root is the
// configured base URL with the API's "/beta" path appended, so it composes with
// WithBaseURL in any order.
func WithBeta() Option {
	return func(c *Client) { c.beta = true }
}

// NewClient returns a client authenticated with apiKey.
func NewClient(apiKey string, opts ...Option) (*Client, error) {
	if strings.TrimSpace(apiKey) == "" {
		return nil, errors.New("deepseek: an API key is required")
	}
	c := &Client{apiKey: apiKey, http: &http.Client{}}
	for _, opt := range opts {
		opt(c)
	}
	if c.http == nil {
		c.http = &http.Client{}
	}
	if c.baseURL == "" {
		c.baseURL = DefaultBaseURL
	}
	if c.beta {
		c.baseURL += "/beta"
	}
	return c, nil
}

// Beta reports whether the client was built with WithBeta.
func (c *Client) Beta() bool { return c.beta }

// Post sends payload as JSON to path, which is relative to the API root, and
// returns the response of a 2xx status. Any other status is returned as an
// *APIError. The caller closes the response body.
func (c *Client) Post(ctx context.Context, path string, payload any, stream bool) (*http.Response, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("deepseek: encoding request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("Content-Type", "application/json")
	if stream {
		req.Header.Set("Accept", "text/event-stream")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("deepseek: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		defer resp.Body.Close()
		return nil, apiError(resp)
	}
	return resp, nil
}

// apiError reads the API's error envelope from a non-2xx response.
func apiError(resp *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrorBody))
	e := &APIError{StatusCode: resp.StatusCode}
	var decoded errorEnvelope
	if err := json.Unmarshal(body, &decoded); err == nil && decoded.Error.Message != "" {
		e.Message = decoded.Error.Message
		e.Type = decoded.Error.Type
		e.Param = decoded.Error.Param
		e.Code = rawString(decoded.Error.Code)
	} else {
		e.Message = strings.TrimSpace(string(body))
	}
	return e
}

// maxErrorBody bounds how much of a failed response is read for the message.
const maxErrorBody = 64 << 10

// errorEnvelope is the body of a failed request.
type errorEnvelope struct {
	Error struct {
		Message string          `json:"message"`
		Type    string          `json:"type"`
		Param   string          `json:"param"`
		Code    json.RawMessage `json:"code"`
	} `json:"error"`
}

// rawString renders a JSON value that may be a string or a number as a plain
// string, since the API uses both for error codes.
func rawString(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	return string(raw)
}

// APIError is an error response from the API.
type APIError struct {
	StatusCode int
	Message    string
	Type       string
	Code       string
	Param      string
}

func (e *APIError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "deepseek: HTTP %d", e.StatusCode)
	switch {
	case e.Type != "" && e.Code != "":
		fmt.Fprintf(&b, " %s/%s", e.Type, e.Code)
	case e.Type != "":
		b.WriteString(" " + e.Type)
	case e.Code != "":
		b.WriteString(" " + e.Code)
	}
	if e.Param != "" {
		fmt.Fprintf(&b, " (param %s)", e.Param)
	}
	if e.Message != "" {
		b.WriteString(": " + e.Message)
	}
	return b.String()
}
