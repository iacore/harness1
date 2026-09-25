// Command cmd1 sends one chat message to the DeepSeek Chat Completions API and
// prints the model's answer.
//
// The message is the command's arguments. The API key is read from
// DEEPSEEK_API_KEY, or, when that is unset, from the credential store of omp
// ("oh-my-pi"):
//
//	go run ./cmd/cmd1 "why is the sky blue?"
//	DEEPSEEK_API_KEY=sk-... go run ./cmd/cmd1 "why is the sky blue?"
//
// The chain of thought, when the model produces one, is printed first.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"

	"github.com/iacore/harness1/api/deepseek"
	"github.com/iacore/harness1/api/deepseek/chat"
	omp "github.com/iacore/harness1/env/oh-my-pi"
)

const (
	// envKey names the environment variable that holds the API key.
	envKey = "DEEPSEEK_API_KEY"

	// provider names DeepSeek in the omp credential store.
	provider = "deepseek"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := run(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "cmd1:", err)
		os.Exit(1)
	}
}

// apiKey returns the key to authenticate with: the one DEEPSEEK_API_KEY holds
// when it is set, and the omp credential store's DeepSeek credential
// otherwise.
func apiKey() (string, error) {
	if key := os.Getenv(envKey); key != "" {
		return key, nil
	}
	key, err := storedKey()
	if err != nil {
		return "", fmt.Errorf("%s is not set: %w", envKey, err)
	}
	return key, nil
}

// storedKey returns the DeepSeek credential of the omp credential store.
func storedKey() (string, error) {
	store, err := omp.Load()
	if err != nil {
		return "", err
	}
	return store.Key(provider)
}

func run(ctx context.Context) error {
	key, err := apiKey()
	if err != nil {
		return err
	}
	prompt := strings.Join(os.Args[1:], " ")
	if strings.TrimSpace(prompt) == "" {
		return errors.New(`usage: cmd1 <message>`)
	}

	client, err := chat.NewClient(key)
	if err != nil {
		return err
	}
	completion, err := client.Chat(ctx, &chat.Request{
		Model:    deepseek.ModelFlash,
		Messages: []chat.Message{&chat.UserMessage{Content: chat.Text(prompt)}},
	})
	if err != nil {
		return err
	}

	answer := completion.Message()
	if answer.ReasoningContent != "" {
		fmt.Println(answer.ReasoningContent)
	}
	fmt.Println(answer.Content)
	return nil
}
