package main

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// writeStore writes a credential database holding the given rows and returns
// its path.
func writeStore(t *testing.T, values string) string {
	t.Helper()
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 is not on PATH")
	}
	path := filepath.Join(t.TempDir(), "agent.db")
	script := `CREATE TABLE auth_credentials (
		id INTEGER PRIMARY KEY,
		provider TEXT NOT NULL,
		credential_type TEXT NOT NULL,
		data TEXT,
		disabled_cause TEXT,
		identity_key TEXT); ` + values
	if out, err := exec.Command("sqlite3", path, script).CombinedOutput(); err != nil {
		t.Fatalf("creating %s: %v: %s", path, err, out)
	}
	return path
}

func TestAPIKey(t *testing.T) {
	store := writeStore(t, `INSERT INTO auth_credentials (provider, credential_type, data)
		VALUES ('deepseek', 'api_key', '{"key":"from-store"}');`)

	tests := []struct {
		name    string
		env     string
		db      string
		want    string
		wantErr string
	}{
		{
			name: "environment variable",
			env:  "from-env",
			db:   store,
			want: "from-env",
		},
		{
			name: "credential store when the variable is empty",
			env:  "",
			db:   store,
			want: "from-store",
		},
		{
			name: "no credential for the provider",
			env:  "",
			db: writeStore(t, `INSERT INTO auth_credentials (provider, credential_type, data)
				VALUES ('openrouter', 'api_key', '{"key":"other"}');`),
			wantErr: `no credential for "deepseek"`,
		},
		{
			name:    "no credential database",
			env:     "",
			db:      filepath.Join(t.TempDir(), "absent.db"),
			wantErr: "credential database",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv(envKey, tt.env)
			t.Setenv("OMP_DB", tt.db)

			got, err := apiKey()
			switch {
			case tt.wantErr == "" && err != nil:
				t.Fatalf("apiKey: %v", err)
			case tt.wantErr != "" && err == nil:
				t.Fatalf("apiKey = %q, want an error mentioning %q", got, tt.wantErr)
			case tt.wantErr != "":
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("apiKey error = %q, want it to mention %q", err, tt.wantErr)
				}
				if !strings.Contains(err.Error(), envKey) {
					t.Fatalf("apiKey error = %q, want it to mention %s", err, envKey)
				}
			case got != tt.want:
				t.Fatalf("apiKey = %q, want %q", got, tt.want)
			}
		})
	}
}
