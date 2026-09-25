// Package omp loads API credentials from omp ("oh-my-pi"), the agent that
// keeps its credential store in ~/.omp/agent/agent.db.
//
// The credentials live in the auth_credentials table of that SQLite database.
// An api_key credential carries its secret, as JSON in the data column, under
// "key"; an oauth credential carries an access token under "access", a refresh
// token under "refresh" and an expiry in milliseconds under "expires". Load
// reads the database through the sqlite3 command, so the standard library is
// enough and no driver has to be linked in. The database only has to exist;
// the sqlite3 binary must be on PATH.
//
// Keys returns the secrets keyed by provider, which is what an endpoint client
// needs:
//
//	store, err := omp.Load()
//	if err != nil {
//		return err
//	}
//	key, err := store.Key("deepseek")
//	if err != nil {
//		return err
//	}
//	client, err := chat.NewClient(key)
package omp

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Credential types recorded in the credential store.
const (
	CredTypeAPIKey = "api_key"
	CredTypeOAuth  = "oauth"
)

// EnvDBPath names the environment variable that overrides the credential
// database Load reads. When it is unset, DefaultPath applies.
const EnvDBPath = "OMP_DB"

// sqliteCommand is the binary used to read the database. It is a variable so
// tests can point at another executable.
var sqliteCommand = "sqlite3"

// credentialsQuery reads every credential of the store. The table and its
// columns are fixed, so the statement carries no caller input.
const credentialsQuery = `SELECT provider, credential_type, data, disabled_cause, identity_key ` +
	`FROM auth_credentials ORDER BY provider, id`

// Credential is one entry of the credential store.
type Credential struct {
	// Provider names the service the credential authenticates with, such as
	// "deepseek" or "openrouter".
	Provider string

	// Type is CredTypeAPIKey or CredTypeOAuth.
	Type string

	// Secret is the value to authenticate with: the API key of an api_key
	// credential, or the access token of an oauth credential. It is empty if
	// the store held neither.
	Secret string

	// IdentityKey distinguishes several credentials of one provider, and is
	// empty when the store did not record one.
	IdentityKey string

	// Disabled reports whether the store marked the credential unusable.
	Disabled bool

	// DisabledCause explains a disabled credential, and is empty otherwise.
	DisabledCause string

	// RefreshToken renews an oauth access token, and is empty for an api_key.
	RefreshToken string

	// ExpiresAt is when an oauth access token stops being valid, and is the
	// zero time when the store recorded no expiry.
	ExpiresAt time.Time

	// AccountID identifies the oauth account, and is empty when the store did
	// not record one.
	AccountID string
}

// DefaultPath returns the credential database Load reads when EnvDBPath is
// unset: $HOME/.omp/agent/agent.db.
func DefaultPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".omp", "agent", "agent.db")
	}
	return filepath.Join(home, ".omp", "agent", "agent.db")
}

// Store is a snapshot of a credential database.
type Store struct {
	path        string
	credentials []Credential
}

// Load reads the credential database the environment selects: EnvDBPath when
// it is set, DefaultPath otherwise.
func Load() (*Store, error) {
	if path := os.Getenv(EnvDBPath); path != "" {
		return LoadFrom(path)
	}
	return LoadFrom(DefaultPath())
}

// LoadFrom reads the credential database at path.
func LoadFrom(path string) (*Store, error) {
	rows, err := query(path)
	if err != nil {
		return nil, err
	}
	credentials := make([]Credential, 0, len(rows))
	for _, r := range rows {
		credentials = append(credentials, r.credential())
	}
	return &Store{path: path, credentials: credentials}, nil
}

// Path returns the database the store was read from.
func (s *Store) Path() string { return s.path }

// Credentials returns the stored credentials in the store's order.
func (s *Store) Credentials() []Credential {
	return append([]Credential(nil), s.credentials...)
}

// Key returns the secret to authenticate with provider. An api_key credential
// is preferred over an oauth one, and a disabled credential is never returned.
// It fails when the store holds no usable credential for provider.
func (s *Store) Key(provider string) (string, error) {
	var first string
	var disabled bool
	for _, c := range s.credentials {
		if c.Provider != provider {
			continue
		}
		if c.Disabled {
			disabled = true
			continue
		}
		if c.Secret == "" {
			continue
		}
		if c.Type == CredTypeAPIKey {
			return c.Secret, nil
		}
		if first == "" {
			first = c.Secret
		}
	}
	if first != "" {
		return first, nil
	}
	if disabled {
		return "", fmt.Errorf("omp: the credential for %q in %s is disabled", provider, s.path)
	}
	return "", fmt.Errorf("omp: no credential for %q in %s", provider, s.path)
}

// Keys returns every provider's secret, one entry per provider. A disabled
// credential is left out, and an api_key credential takes precedence over an
// oauth one.
func (s *Store) Keys() map[string]string {
	keys := make(map[string]string)
	for _, c := range s.credentials {
		if c.Disabled || c.Secret == "" {
			continue
		}
		if _, ok := keys[c.Provider]; ok && c.Type != CredTypeAPIKey {
			continue
		}
		keys[c.Provider] = c.Secret
	}
	return keys
}

// row is one result row of the credentials query, matching the JSON that
// sqlite3 -json emits. The nullable columns are pointers.
type row struct {
	Provider      string  `json:"provider"`
	Type          string  `json:"credential_type"`
	Data          string  `json:"data"`
	DisabledCause *string `json:"disabled_cause"`
	IdentityKey   *string `json:"identity_key"`
}

// credential converts a row into a Credential, decoding the data column into
// the fields the store documents.
func (r row) credential() Credential {
	d := parseData(r.Data)
	c := Credential{
		Provider:     r.Provider,
		Type:         r.Type,
		Secret:       d.Key,
		RefreshToken: d.Refresh,
		AccountID:    d.AccountID,
	}
	if c.Secret == "" {
		c.Secret = d.Access
	}
	if r.DisabledCause != nil {
		c.Disabled = true
		c.DisabledCause = *r.DisabledCause
	}
	if r.IdentityKey != nil {
		c.IdentityKey = *r.IdentityKey
	}
	if d.Expires > 0 {
		c.ExpiresAt = time.UnixMilli(d.Expires)
	}
	return c
}

// secretData is the JSON the data column holds. api_key credentials use Key,
// oauth credentials use the rest, and unknown fields are ignored.
type secretData struct {
	Key       string `json:"key"`
	Access    string `json:"access"`
	Refresh   string `json:"refresh"`
	Expires   int64  `json:"expires"`
	AccountID string `json:"accountId"`
}

// parseData decodes the data column. A value that is not the documented JSON
// object is kept as the secret itself, since older stores held it verbatim.
func parseData(raw string) secretData {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return secretData{}
	}
	var d secretData
	if err := json.Unmarshal([]byte(trimmed), &d); err == nil {
		return d
	}
	var s string
	if err := json.Unmarshal([]byte(trimmed), &s); err == nil {
		return secretData{Key: s}
	}
	return secretData{Key: trimmed}
}

// query runs the credentials query against the database at path and decodes
// the sqlite3 JSON output.
func query(path string) ([]row, error) {
	if _, err := exec.LookPath(sqliteCommand); err != nil {
		return nil, errors.New("omp: the sqlite3 command is required to read the credential database")
	}
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("omp: credential database: %w", err)
	}
	cmd := exec.Command(sqliteCommand, "-readonly", "-json", path, credentialsQuery)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return nil, fmt.Errorf("omp: reading %s: %s", path, message)
	}
	// sqlite3 prints nothing at all when the query returns no row.
	out := bytes.TrimSpace(stdout.Bytes())
	if len(out) == 0 {
		return nil, nil
	}
	var rows []row
	if err := json.Unmarshal(out, &rows); err != nil {
		return nil, fmt.Errorf("omp: decoding sqlite3 output: %w", err)
	}
	return rows, nil
}
