//go:build !linux

package main

import (
	"fmt"
	"os/exec"
)

func requirePrivateRootFile(string) error {
	return fmt.Errorf("authenticated self-update requires Linux")
}
func dropUpdatePrivileges(*exec.Cmd) error { return nil }
func prepareUnprivilegedDirectory(string, string) error {
	return fmt.Errorf("self-update requires Linux")
}

func validatePrivilegedHome(string) error { return nil }
