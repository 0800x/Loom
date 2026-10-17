package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestUpdateEnvironmentRejectsInheritedExecutableControls(t *testing.T) {
	for _, key := range []string{"BASH_ENV", "ENV", "LD_PRELOAD", "LD_LIBRARY_PATH", "PYTHONPATH", "GIT_CONFIG_COUNT", "GIT_SSH_COMMAND", "PATH", "HOME"} {
		t.Setenv(key, "attacker")
	}
	updateGitHubHeader = ""
	env := strings.Join(cleanUpdateEnvironment(false), "\n")
	if strings.Contains(env, "attacker") || strings.Contains(env, "BASH_ENV") {
		t.Fatal(env)
	}
}

func TestUpdateGitDisablesUnexpectedHooks(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "executed")
	run := func(args ...string) {
		t.Helper()
		out, err := runUpdateCommand(5*time.Second, dir, "git", args...)
		if err != nil {
			t.Fatal(err, out)
		}
	}
	run("init", "--quiet")
	hooks := filepath.Join(dir, "evil-hooks")
	if err := os.Mkdir(hooks, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(hooks, "post-checkout"), []byte("#!/bin/sh\ntouch '"+marker+"'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	run("config", "core.hooksPath", hooks)
	run("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "--allow-empty", "-m", "first")
	selected, err := runUpdateCommand(time.Second, dir, "git", "rev-parse", "HEAD")
	if err != nil {
		t.Fatal(err)
	}
	run("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "--allow-empty", "-m", "branch moved")
	run("checkout", "--detach", selected)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("unexpected hook executed")
	}
	head, err := runUpdateCommand(time.Second, dir, "git", "rev-parse", "HEAD")
	if err != nil || head != selected {
		t.Fatal("selected commit moved", head, err)
	}
}

func TestInstallerCannotRunInheritedShellInit(t *testing.T) {
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skip("requires bash")
	}
	dir := t.TempDir()
	marker := filepath.Join(dir, "executed")
	init := filepath.Join(dir, "init")
	if err := os.WriteFile(init, []byte("touch '"+marker+"'"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BASH_ENV", init)
	t.Setenv("ENV", init)
	cmd := updateCommand(context.Background(), "bash", "-c", "exit 0")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("shell init executed")
	}
}

func TestApprovalIsRequiredAndRevisionMustBeFullSHA(t *testing.T) {
	for _, sha := range []string{"main", strings.Repeat("a", 39), strings.Repeat("a", 40) + ";id"} {
		if validCommit(sha) {
			t.Fatal("unsafe SHA", sha)
		}
	}
	if _, err := approvedReleaseDigest(filepath.Join(t.TempDir(), "missing"), defaultUpdateRepository, strings.Repeat("a", 40)); err == nil {
		t.Fatal("missing approval accepted")
	}
	if matchingRunningRevision(strings.Repeat("a", 40), strings.Repeat("b", 40), strings.Repeat("a", 40)) {
		t.Fatal("mismatched runtime accepted")
	}
}

func TestReleaseArchiveMustMatchIndependentDigest(t *testing.T) {
	archive := []byte("release content")
	digest := fmt.Sprintf("%x", sha256.Sum256(archive))
	if !verifyApprovedArchive(archive, digest) {
		t.Fatal("correct release refused")
	}
	if verifyApprovedArchive([]byte("substituted content"), digest) {
		t.Fatal("substituted release accepted")
	}
	if verifyApprovedArchive(archive, "branch-name") {
		t.Fatal("unvalidated digest accepted")
	}
}
