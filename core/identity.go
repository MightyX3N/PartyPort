package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode"
)

var b64 = base64.RawURLEncoding

// Identity is this device's Ed25519 key pair and the display name.
// The public key (base64url) is the member's identity in every party.
type Identity struct {
	mu   sync.Mutex
	path string
	priv ed25519.PrivateKey
	Key  string
	Name string
}

type identityFile struct {
	Seed string `json:"seed"`
	Name string `json:"name"`
}

func loadIdentity(dir string) (*Identity, error) {
	path := filepath.Join(dir, "identity.json")
	id := &Identity{path: path}
	data, err := os.ReadFile(path)
	if err == nil {
		var f identityFile
		if err := json.Unmarshal(data, &f); err != nil {
			return nil, err
		}
		seed, err := b64.DecodeString(f.Seed)
		if err != nil || len(seed) != ed25519.SeedSize {
			return nil, errors.New("identity.json has a bad key")
		}
		id.priv = ed25519.NewKeyFromSeed(seed)
		id.Name = f.Name
	} else if errors.Is(err, os.ErrNotExist) {
		_, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return nil, err
		}
		id.priv = priv
		if err := id.save(); err != nil {
			return nil, err
		}
	} else {
		return nil, err
	}
	id.Key = b64.EncodeToString(id.priv.Public().(ed25519.PublicKey))
	return id, nil
}

func (id *Identity) save() error {
	f := identityFile{Seed: b64.EncodeToString(id.priv.Seed()), Name: id.Name}
	data, _ := json.MarshalIndent(f, "", "  ")
	return writeFileAtomic(id.path, data, 0o600)
}

func (id *Identity) Sign(msg []byte) string {
	return b64.EncodeToString(ed25519.Sign(id.priv, msg))
}

func (id *Identity) GetName() string {
	id.mu.Lock()
	defer id.mu.Unlock()
	return id.Name
}

func (id *Identity) SetName(name string) error {
	id.mu.Lock()
	defer id.mu.Unlock()
	id.Name = name
	return id.save()
}

// cleanName mirrors the service's rules: no control characters, single
// spaces, trimmed, capped length.
func cleanName(s string, max int) string {
	var b strings.Builder
	space := false
	for _, r := range s {
		if unicode.IsControl(r) {
			continue
		}
		if unicode.IsSpace(r) {
			space = true
			continue
		}
		if space && b.Len() > 0 {
			b.WriteRune(' ')
		}
		space = false
		b.WriteRune(r)
	}
	out := []rune(b.String())
	if len(out) > max {
		out = out[:max]
	}
	return strings.TrimSpace(string(out))
}

func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
