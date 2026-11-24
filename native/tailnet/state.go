package main

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"tailscale.com/atomicfile"
	"tailscale.com/ipn"
)

// The wrapping key lives in the phone's secure storage. tsnet writes each
// update durably before returning, including updates while Dart is suspended.
type encryptedStore struct {
	mu     sync.Mutex
	path   string
	aead   cipher.AEAD
	values map[ipn.StateKey][]byte
}

func openStore(dir string, key []byte) (*encryptedStore, error) {
	if len(key) != 32 {
		return nil, errors.New("invalid storage key")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCMWithRandomNonce(block)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	s := &encryptedStore{path: filepath.Join(dir, "identity"), aead: aead, values: make(map[ipn.StateKey][]byte)}
	b, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	plain, err := aead.Open(nil, nil, b, nil)
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(plain, &s.values); err != nil {
		return nil, err
	}
	return s, nil
}
func (s *encryptedStore) ReadState(k ipn.StateKey) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.values[k]
	if !ok {
		return nil, ipn.ErrStateNotExist
	}
	return append([]byte(nil), b...), nil
}
func (s *encryptedStore) WriteState(k ipn.StateKey, b []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	old, exists := s.values[k]
	if b == nil {
		delete(s.values, k)
	} else {
		s.values[k] = append([]byte{}, b...)
	}
	raw, err := json.Marshal(s.values)
	if err == nil {
		err = atomicfile.WriteFile(s.path, s.aead.Seal(nil, nil, raw, nil), 0600)
	}
	if err != nil {
		if exists {
			s.values[k] = old
		} else {
			delete(s.values, k)
		}
	}
	return err
}
