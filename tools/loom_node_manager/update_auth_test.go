package main

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const testUpdateToken = "github_pat_1234567890abcdefghijklmnopqrstuvwxyz"

func TestReadGitHubUpdateTokenFromPrivateFile(t *testing.T) {
	mgr := newManager(t.TempDir())
	path := filepath.Join(mgr.home, ".loom-update-token")
	if err := os.WriteFile(path, []byte(testUpdateToken+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(path, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("LOOM_UPDATE_GITHUB_TOKEN", "")
	t.Setenv("LOOM_UPDATE_TOKEN_FILE", "")

	token, err := readGitHubUpdateToken(mgr)
	if err != nil {
		t.Fatal(err)
	}
	if token != testUpdateToken {
		t.Fatalf("unexpected token: %q", token)
	}
}

func TestConfigureGitHubUpdateAuthUsesBasicHeader(t *testing.T) {
	mgr := newManager(t.TempDir())
	t.Setenv("LOOM_UPDATE_GITHUB_TOKEN", testUpdateToken)
	t.Setenv("GIT_CONFIG_COUNT", "0")
	t.Setenv("GIT_CONFIG_KEY_0", "")
	t.Setenv("GIT_CONFIG_VALUE_0", "")

	if err := configureGitHubUpdateAuth(mgr); err != nil {
		t.Fatal(err)
	}
	if got := os.Getenv("GIT_CONFIG_COUNT"); got != "0" {
		t.Fatal("auth must not mutate inherited Git config")
	}
	header := updateGitHubHeader
	t.Cleanup(func() { updateGitHubHeader = "" })
	const prefix = "Authorization: Basic "
	if !strings.HasPrefix(header, prefix) {
		t.Fatalf("unexpected auth header prefix")
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(header, prefix))
	if err != nil {
		t.Fatal(err)
	}
	if got := string(decoded); got != "x-access-token:"+testUpdateToken {
		t.Fatalf("unexpected decoded credential")
	}
}
