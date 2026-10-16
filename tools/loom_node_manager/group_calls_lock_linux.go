//go:build linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

func (m manager) lockGroupCallsSetup() (func(), error) {
	paths := []string{filepath.Join(m.home, ".group-calls-setup.lock")}
	if os.Geteuid() == 0 && m.home == "/opt/loom-node" {
		paths = append(paths, "/run/lock/loom-node-update.lock")
	}
	var files []*os.File
	release := func() {
		for _, f := range files {
			_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
			_ = f.Close()
		}
	}
	for _, path := range paths {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
		if err != nil {
			release()
			return nil, fmt.Errorf("Cannot acquire operation lock")
		}
		if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			_ = f.Close()
			release()
			return nil, fmt.Errorf("Another setup or update is running; try again when it finishes")
		}
		files = append(files, f)
	}
	return release, nil
}
