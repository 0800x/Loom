package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

const githubUpdateAuthHeaderKey = "http.https://github.com/.extraheader"

func updateTokenPath(mgr manager) string {
	if configured := strings.TrimSpace(os.Getenv("LOOM_UPDATE_TOKEN_FILE")); configured != "" {
		return configured
	}
	return filepath.Join(mgr.home, ".loom-update-token")
}

func readGitHubUpdateToken(mgr manager) (string, error) {
	if token := strings.TrimSpace(os.Getenv("LOOM_UPDATE_GITHUB_TOKEN")); token != "" {
		return validateGitHubUpdateToken(token)
	}

	path := updateTokenPath(mgr)
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("stat update token file: %w", err)
	}
	if info.IsDir() {
		return "", fmt.Errorf("update token path is a directory: %s", path)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		return "", fmt.Errorf("update token file must not be readable by group/others: chmod 600 %s", path)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read update token file: %w", err)
	}
	return validateGitHubUpdateToken(strings.TrimSpace(string(body)))
}

func validateGitHubUpdateToken(token string) (string, error) {
	if token == "" {
		return "", nil
	}
	if len(token) < 20 || len(token) > 512 || strings.ContainsAny(token, "\r\n\x00") {
		return "", fmt.Errorf("invalid GitHub update token")
	}
	return token, nil
}

// configureGitHubUpdateAuth installs a process-local Git configuration header
// used by child git processes. The token is never written into the Node's
// deploy/.env, remote URL, update state, TUI output, or command arguments.
func configureGitHubUpdateAuth(mgr manager) error {
	updateGitHubHeader = ""
	token, err := readGitHubUpdateToken(mgr)
	if err != nil || token == "" {
		return err
	}

	updateGitHubHeader = "Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte("x-access-token:"+token))
	return nil
}
