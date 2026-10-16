//go:build !linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
)

func (m manager) lockGroupCallsSetup() (func(), error) {
	path := filepath.Join(m.home, ".group-calls-setup-lock")
	if err := os.Mkdir(path, 0o700); err != nil {
		return nil, fmt.Errorf("Another calling setup is running (or its lock needs recovery)")
	}
	return func() { _ = os.Remove(path) }, nil
}
