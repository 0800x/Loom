//go:build linux

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNetworkWorkerDropsRootPrivileges(t *testing.T) {
	cmd := updateCommand(context.Background(), "/usr/bin/id", "-u")
	if err := dropUpdatePrivileges(cmd); err != nil {
		t.Fatal(err)
	}
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	if os.Geteuid() == 0 && strings.TrimSpace(string(out)) != "65534" {
		t.Fatal("worker retained root")
	}
}
func TestAuthenticatedReleaseApprovalPermissions(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("root ownership test")
	}
	root := t.TempDir()
	dir := filepath.Join(root, "policy")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "approved-releases")
	sha := strings.Repeat("a", 40)
	digest := strings.Repeat("b", 64)
	if err := os.WriteFile(path, []byte(defaultUpdateRepository+" "+sha+" "+digest+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if got, err := approvedReleaseDigest(path, defaultUpdateRepository, sha); err != nil || got != digest {
		t.Fatal(got, err)
	}
	if err := os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if _, err := approvedReleaseDigest(path, defaultUpdateRepository, sha); err == nil {
		t.Fatal("writable approval trusted")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc/passwd", path); err != nil {
		t.Fatal(err)
	}
	if _, err := approvedReleaseDigest(path, defaultUpdateRepository, sha); err == nil {
		t.Fatal("symlink approval trusted")
	}
}
