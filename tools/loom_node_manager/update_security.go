package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

// Populated only from the validated token reader, never inherited GIT_*.
var updateGitHubHeader string

func cleanUpdateEnvironment(git bool) []string {
	env := []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/nonexistent", "LANG=C", "GIT_TERMINAL_PROMPT=0", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"}
	if git && updateGitHubHeader != "" {
		env = append(env, "GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0="+githubUpdateAuthHeaderKey, "GIT_CONFIG_VALUE_0="+updateGitHubHeader)
	}
	return env
}

func updateCommand(ctx context.Context, name string, args ...string) *exec.Cmd {
	if name == "git" {
		args = append([]string{"-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "credential.helper=", "-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=never", "-c", "safe.directory=*"}, args...)
	}
	if runtime.GOOS == "linux" {
		switch name {
		case "git":
			name = "/usr/bin/git"
		case "bash":
			name = "/bin/bash"
		case "curl":
			name = "/usr/bin/curl"
		case "tar":
			name = "/bin/tar"
		}
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = cleanUpdateEnvironment(strings.HasSuffix(name, "git"))
	return cmd
}

func approvedReleaseDigest(path, repository, commit string) (string, error) {
	if repository != defaultUpdateRepository || !validCommit(commit) {
		return "", fmt.Errorf("unapproved update identity")
	}
	if err := requirePrivateRootFile(path); err != nil {
		return "", fmt.Errorf("trusted release metadata unavailable in %s; rerun the trusted Home Node installer to configure updates, or approve this exact source under the operator policy: %w", path, err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if len(content) > 1024*1024 {
		return "", fmt.Errorf("release approvals too large")
	}
	for _, line := range strings.Split(string(content), "\n") {
		f := strings.Fields(line)
		if len(f) == 3 && f[0] == repository && f[1] == strings.ToLower(commit) && regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(f[2]) {
			return f[2], nil
		}
	}
	return "", fmt.Errorf("selected revision has no authenticated operator approval in %s", path)
}

// Fetch an exact commit without checking out a mutable branch, as an
// unprivileged process. Validate a root-private copy of the complete archive
// against independently approved SHA256 metadata before executing ANY code.
func prepareApprovedUpdate(root, repository, commit, digest string) (string, error) {
	if repository != defaultUpdateRepository || !validCommit(commit) || !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(digest) {
		return "", fmt.Errorf("invalid release metadata")
	}
	download := filepath.Join(root, "download")
	if err := os.Mkdir(download, 0700); err != nil {
		return "", err
	}
	if err := prepareUnprivilegedDirectory(root, download); err != nil {
		return "", err
	}
	run := func(args ...string) ([]byte, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		cmd := updateCommand(ctx, "git", args...)
		cmd.Dir = download
		if err := dropUpdatePrivileges(cmd); err != nil {
			return nil, err
		}
		return cmd.Output()
	}
	if _, err := run("init", "--quiet", "."); err != nil {
		return "", err
	}
	if _, err := run("fetch", "--quiet", "--depth=1", "https://github.com/"+repository+".git", commit); err != nil {
		return "", fmt.Errorf("fetch selected commit: %w", err)
	}
	archive, err := run("archive", "--format=tar", commit)
	if err != nil {
		return "", err
	}
	if !verifyApprovedArchive(archive, digest) {
		return "", fmt.Errorf("approved release archive checksum mismatch")
	}
	archivePath := filepath.Join(root, "verified.tar")
	if err := os.WriteFile(archivePath, archive, 0600); err != nil {
		return "", err
	}
	checkout := filepath.Join(root, "verified-source")
	if err := os.Mkdir(checkout, 0700); err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := updateCommand(ctx, "tar", "--no-same-owner", "--no-same-permissions", "-xf", archivePath, "-C", checkout)
	if output, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("extract approved release: %w: %s", err, output)
	}
	if err := os.WriteFile(filepath.Join(checkout, ".loom-verified-source"), []byte(strings.ToLower(commit)+"\n"), 0600); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(checkout, ".loom-source-sha256"), []byte(digest+"\n"), 0600); err != nil {
		return "", err
	}
	return checkout, nil
}

func verifyApprovedArchive(archive []byte, digest string) bool {
	return regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(digest) && fmt.Sprintf("%x", sha256.Sum256(archive)) == digest
}
