package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseGitHubRepository(t *testing.T) {
	cases := map[string]string{
		"https://github.com/0800x/Loom.git":  "0800x/Loom",
		"https://github.com/0800x/Loom":      "0800x/Loom",
		"git@github.com:0800x/Loom.git":      "0800x/Loom",
		"https://example.com/0800x/Loom.git": "",
	}
	for input, want := range cases {
		if got := parseGitHubRepository(input); got != want {
			t.Fatalf("parseGitHubRepository(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestParseManagerVersion(t *testing.T) {
	input := "package main\n\nconst version = \"0.4.1\"\n"
	if got := parseManagerVersion(input); got != "0.4.1" {
		t.Fatalf("parseManagerVersion() = %q", got)
	}
}

func TestValidRepository(t *testing.T) {
	if !validRepository("0800x/Loom") {
		t.Fatal("expected repository slug to be valid")
	}
	for _, value := range []string{"0800x", "0800x/Loom/extra", "0800x/Bad Name", "0800x/Loom;rm"} {
		if validRepository(value) {
			t.Fatalf("expected %q to be rejected", value)
		}
	}
}

func TestValidBranch(t *testing.T) {
	for _, value := range []string{"main", "release/v0.4", "codex/node-admin-control-plane"} {
		if !validBranch(value) {
			t.Fatalf("expected %q to be valid", value)
		}
	}
	for _, value := range []string{"", "-main", "bad branch", "feature..name", "foo@{bar", "refs/heads/main.lock"} {
		if validBranch(value) {
			t.Fatalf("expected %q to be rejected", value)
		}
	}
}

func TestCurrentGitBranch(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is unavailable")
	}
	dir := t.TempDir()
	cmd := exec.Command("git", "init", "-q", "-b", "codex/node-admin-control-plane", dir)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git init failed: %v: %s", err, output)
	}
	if got := currentGitBranch(dir); got != "codex/node-admin-control-plane" {
		t.Fatalf("currentGitBranch() = %q", got)
	}
}

func TestShortCommit(t *testing.T) {
	if got := shortCommit("1234567890abcdef"); got != "1234567890" {
		t.Fatalf("unexpected short commit: %s", got)
	}
	if got := shortCommit(""); got != "unknown" {
		t.Fatalf("unexpected empty short commit: %s", got)
	}
}

func TestPersistedBranchSurvivesAnotherSourceBranch(t *testing.T) {
	for _, key := range []string{"LOOM_UPDATE_BRANCH", "LOOM_UPDATE_SOURCE_DIR", "LOOM_UPDATE_REPOSITORY"} {
		t.Setenv(key, "")
	}
	root := t.TempDir()
	source := filepath.Join(root, "source")
	for _, dir := range []string{"tools/loom_node_manager", "services/loom_server/scripts/linux"} {
		if err := os.MkdirAll(filepath.Join(source, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, file := range []string{"tools/loom_node_manager/go.mod", "services/loom_server/scripts/linux/install-production.sh"} {
		if err := os.WriteFile(filepath.Join(source, file), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if output, err := exec.Command("git", "init", "-q", "-b", "main", source).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, output)
	}
	mgr := newManager(filepath.Join(root, "node"))
	if err := writeUpdateState(mgr, updateStatus{Branch: "main", SourceDir: source, Repository: defaultUpdateRepository, InstalledCommit: strings.Repeat("a", 40)}); err != nil {
		t.Fatal(err)
	}
	if got := resolveUpdateStatus(mgr).Branch; got != "main" {
		t.Fatalf("channel changed to %q", got)
	}
	t.Setenv("LOOM_UPDATE_BRANCH", "release/test")
	if got := resolveUpdateStatus(mgr).Branch; got != "release/test" {
		t.Fatalf("explicit override ignored: %q", got)
	}
}

func TestUpdateRequiresMatchingManagerAndRunningNode(t *testing.T) {
	latest, old := strings.Repeat("a", 40), strings.Repeat("b", 40)
	if !matchingRunningRevision(latest, latest, latest) {
		t.Fatal("matching live builds should verify")
	}
	for _, pair := range [][2]string{{latest, old}, {old, latest}, {latest, ""}, {"", latest}, {latest[:10], latest}} {
		if matchingRunningRevision(pair[0], pair[1], latest) {
			t.Fatal("a partial or mismatched installation was reported current")
		}
	}
}

func TestLegacyInstallUsesArchitectureChannel(t *testing.T) {
	for _, key := range []string{"LOOM_UPDATE_BRANCH", "LOOM_UPDATE_SOURCE_DIR", "LOOM_UPDATE_REPOSITORY"} {
		t.Setenv(key, "")
	}
	previousBranch := buildBranch
	buildBranch = ""
	t.Cleanup(func() { buildBranch = previousBranch })
	if got := resolveUpdateStatus(newManager(t.TempDir())); got.Branch != "main" || got.Repository != defaultUpdateRepository {
		t.Fatalf("legacy metadata selected wrong update channel: %+v", got)
	}
}
