package main

import (
	"bufio"
	"context"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

const (
	defaultUpdateRepository = "0800x/Loom"
	defaultUpdateBranch     = "main"
)

type updateStatus struct {
	State             string
	InstalledVersion  string
	AvailableVersion  string
	InstalledCommit   string
	AvailableCommit   string
	Repository        string
	Branch            string
	SourceDir         string
	Detail            string
	SourceDigest      string
	PublisherSequence uint64
}

var managerVersionPattern = regexp.MustCompile(`const\s+version\s*=\s*"([^"]+)"`)

func parseManagerVersion(content string) string {
	match := managerVersionPattern.FindStringSubmatch(content)
	if len(match) != 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

func parseGitHubRepository(remote string) string {
	remote = strings.TrimSpace(remote)
	if remote == "" {
		return ""
	}
	if strings.HasPrefix(remote, "git@github.com:") {
		value := strings.TrimPrefix(remote, "git@github.com:")
		return strings.TrimSuffix(strings.Trim(value, "/"), ".git")
	}
	parsed, err := url.Parse(remote)
	if err != nil || !strings.EqualFold(parsed.Hostname(), "github.com") {
		return ""
	}
	value := strings.Trim(parsed.Path, "/")
	return strings.TrimSuffix(value, ".git")
}

func validRepository(value string) bool {
	parts := strings.Split(value, "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return false
	}
	for _, part := range parts {
		for _, r := range part {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' || r == '.' {
				continue
			}
			return false
		}
	}
	return true
}

func validBranch(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 255 || strings.HasPrefix(value, "-") || strings.HasPrefix(value, "/") || strings.HasSuffix(value, "/") || strings.HasSuffix(value, ".") || strings.Contains(value, "//") || strings.Contains(value, "..") || strings.Contains(value, "@{") || strings.HasSuffix(value, ".lock") {
		return false
	}
	return !strings.ContainsAny(value, " ~^:?*[\\\t\r\n")
}

func shortCommit(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 10 {
		return value[:10]
	}
	if value == "" {
		return "unknown"
	}
	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func updateStatePath(mgr manager) string {
	return filepath.Join(mgr.home, ".loom-update-state")
}

func readUpdateState(path string) map[string]string {
	values := map[string]string{}
	file, err := os.Open(path)
	if err != nil {
		return values
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		values[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	return values
}

func cleanStateValue(value string) string {
	value = strings.ReplaceAll(value, "\n", "")
	value = strings.ReplaceAll(value, "\r", "")
	return strings.TrimSpace(value)
}

func writeUpdateState(mgr manager, status updateStatus) error {
	path := updateStatePath(mgr)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	body := strings.Join([]string{
		"installed_version=" + cleanStateValue(status.InstalledVersion),
		"installed_commit=" + cleanStateValue(status.InstalledCommit),
		"repository=" + cleanStateValue(status.Repository),
		"branch=" + cleanStateValue(status.Branch),
		"source_dir=" + cleanStateValue(status.SourceDir),
		"",
	}, "\n")
	tmp, err := os.CreateTemp(filepath.Dir(path), ".loom-update-state-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.WriteString(body); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func runUpdateCommand(timeout time.Duration, dir string, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := updateCommand(ctx, name, args...)
	if dir != "" {
		cmd.Dir = dir
	}

	if name == "git" && len(args) > 0 && (args[0] == "ls-remote" || args[0] == "fetch" || args[0] == "clone") {
		_ = dropUpdatePrivileges(cmd)
	}
	output, err := cmd.CombinedOutput()
	text := strings.TrimSpace(string(output))
	if ctx.Err() == context.DeadlineExceeded {
		return text, fmt.Errorf("command timed out")
	}
	if err != nil {
		if text == "" {
			return text, err
		}
		return text, fmt.Errorf("%w: %s", err, text)
	}
	return text, nil
}

func gitRoot(candidate string) string {
	candidate = strings.TrimSpace(candidate)
	if candidate == "" {
		return ""
	}
	info, err := os.Stat(candidate)
	if err != nil {
		return ""
	}
	if !info.IsDir() {
		candidate = filepath.Dir(candidate)
	}
	output, err := runUpdateCommand(4*time.Second, candidate, "git", "rev-parse", "--show-toplevel")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(output)
}

func isLoomSource(root string) bool {
	if root == "" {
		return false
	}
	checks := []string{
		filepath.Join(root, "tools", "loom_node_manager", "go.mod"),
		filepath.Join(root, "services", "loom_server", "scripts", "linux", "install-production.sh"),
	}
	for _, path := range checks {
		if _, err := os.Stat(path); err != nil {
			return false
		}
	}
	return true
}

func currentGitBranch(root string) string {
	if root == "" {
		return ""
	}
	branch, err := runUpdateCommand(4*time.Second, root, "git", "symbolic-ref", "--quiet", "--short", "HEAD")
	if err != nil || !validBranch(branch) {
		return ""
	}
	return strings.TrimSpace(branch)
}

func discoverUpdateSource(mgr manager, repository string) string {
	env := loadEnv(mgr.envPath)
	candidates := []string{
		os.Getenv("LOOM_UPDATE_SOURCE_DIR"),
		env["LOOM_UPDATE_SOURCE_DIR"],
	}
	if cwd, err := os.Getwd(); err == nil {
		candidates = append(candidates, cwd)
	}
	candidates = append(candidates, os.Getenv("PWD"), mgr.home, "/opt/loom-src", filepath.Join(mgr.home, "source"), "/root/Loom")
	if homes, err := filepath.Glob("/home/*/Loom"); err == nil {
		candidates = append(candidates, homes...)
	}

	seen := map[string]bool{}
	for _, candidate := range candidates {
		root := gitRoot(candidate)
		if root == "" || seen[root] || !isLoomSource(root) {
			continue
		}
		seen[root] = true
		remote, err := runUpdateCommand(4*time.Second, root, "git", "remote", "get-url", "origin")
		if err != nil {
			continue
		}
		remoteRepo := parseGitHubRepository(remote)
		if repository != "" && !strings.EqualFold(repository, remoteRepo) {
			continue
		}
		return root
	}
	return ""
}

func remoteManagerVersion(sourceDir, branch string) string {
	refs := []string{
		"origin/" + branch + ":tools/loom_node_manager/main.go",
		"origin/" + branch + ":main.go",
	}
	for _, ref := range refs {
		content, err := runUpdateCommand(5*time.Second, sourceDir, "git", "show", ref)
		if err != nil {
			continue
		}
		if parsed := parseManagerVersion(content); parsed != "" {
			return parsed
		}
	}
	return ""
}

func resolveUpdateStatus(mgr manager) updateStatus {
	state := readUpdateState(updateStatePath(mgr))
	env := loadEnv(mgr.envPath)
	status := updateStatus{
		State:            "unavailable",
		InstalledVersion: version,
		InstalledCommit:  firstNonEmpty(state["installed_commit"], knownBuildCommit()),
		Repository:       firstNonEmpty(os.Getenv("LOOM_UPDATE_REPOSITORY"), env["LOOM_UPDATE_REPOSITORY"], state["repository"], buildRepository, defaultUpdateRepository),
	}
	status.SourceDir = firstNonEmpty(os.Getenv("LOOM_UPDATE_SOURCE_DIR"), env["LOOM_UPDATE_SOURCE_DIR"], state["source_dir"])
	if !isLoomSource(status.SourceDir) || gitRoot(status.SourceDir) == "" {
		status.SourceDir = discoverUpdateSource(mgr, status.Repository)
	}
	explicitBranch := firstNonEmpty(os.Getenv("LOOM_UPDATE_BRANCH"), env["LOOM_UPDATE_BRANCH"])
	// A discovered checkout can be on a feature branch. Only installation
	// metadata or an explicit operator choice may select a non-default channel.
	status.Branch = firstNonEmpty(explicitBranch, state["branch"], buildBranch, defaultUpdateBranch)
	return status
}

func checkNodeUpdate(mgr manager) updateStatus {
	status := resolveUpdateStatus(mgr)
	if runtime.GOOS != "linux" {
		status.Detail = "self-update is currently available on Linux nodes"
		return status
	}
	if _, err := exec.LookPath("git"); err != nil {
		status.Detail = "git is required for update checks"
		return status
	}
	if !validRepository(status.Repository) {
		status.Detail = "invalid update repository"
		return status
	}
	if !validBranch(status.Branch) {
		status.Detail = "invalid update branch"
		return status
	}

	enabled, policyErr := publisherPolicyEnabled(updatePolicyPath)
	if policyErr != nil {
		status.Detail = "Protected update policy is invalid; restore it before updating"
		return status
	}
	if enabled {
		if status.Repository != defaultUpdateRepository || status.Branch != defaultUpdateBranch {
			status.Detail = "Publisher updates require the protected Loom main channel"
			return status
		}
		release, err := fetchPublisherRelease()
		if err != nil {
			status.Detail = err.Error()
			return status
		}
		status, err = selectPublisherRelease(mgr, status, release)
		if err != nil {
			status.Detail = err.Error()
			return status
		}
		return finishUpdateCheck(mgr, status)
	}
	remoteURL := "https://github.com/" + status.Repository + ".git"
	output, err := runUpdateCommand(20*time.Second, "", "git", "ls-remote", remoteURL, "refs/heads/"+status.Branch)
	if err != nil {
		status.Detail = "remote update check failed: " + err.Error()
		return status
	}
	fields := strings.Fields(output)
	if len(fields) < 1 {
		status.Detail = "remote update branch was not found"
		return status
	}
	status.AvailableCommit = fields[0]
	status.Detail = "Remote repository"
	status = finishUpdateCheck(mgr, status)
	if status.State == "update_available" {
		if _, err := approvedReleaseDigest("/etc/loom/approved-releases", status.Repository, status.AvailableCommit); err != nil {
			status.State = "approval_required"
			status.Detail += "; operator approval is missing. Run the trusted Home Node installer once to configure publisher updates, or approve this revision under your manual policy."
		}
	}
	return status
}

func matchingRunningRevision(managerCommit, nodeCommit, selectedCommit string) bool {
	return validCommit(selectedCommit) && strings.EqualFold(managerCommit, selectedCommit) && strings.EqualFold(nodeCommit, selectedCommit)
}

func finishUpdateCheck(mgr manager, status updateStatus) updateStatus {
	if !validCommit(status.AvailableCommit) {
		status.State = "unavailable"
		status.Detail = "Remote branch did not resolve to a full commit SHA"
		return status
	}
	// Permit a repair install when just the Manager was upgraded, when an old
	// container is still running, or when legacy metadata cannot prove a build.
	status.State = "update_available"
	diagnostics, err := mgr.readDiagnostics()
	if err != nil {
		status.Detail += "; Node runtime is unavailable. Check Services and run loom doctor; an update does not establish database or storage recovery."
		return status
	}
	if diagnostics.Ready && matchingRunningRevision(knownBuildCommit(), diagnostics.Runtime.BuildCommit, status.AvailableCommit) {
		status.State = "up_to_date"
		status.InstalledCommit = status.AvailableCommit
		status.Detail += "; running Manager and Node match the selected branch."
		_ = writeUpdateState(mgr, status)
	} else {
		status.Detail += "; install to align the running Manager and Node with the selected branch."
	}
	return status
}

func autoUpdateEnabled(mgr manager, status updateStatus) bool {
	env := loadEnv(mgr.envPath)
	value := strings.ToLower(firstNonEmpty(os.Getenv("LOOM_AUTO_UPDATE"), env["LOOM_AUTO_UPDATE"]))
	switch value {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return status.Branch == "main" || strings.HasPrefix(status.Branch, "release/")
}

func applyNodeUpdate(mgr manager) (updateStatus, string, error) {
	return applyNodeUpdateWithProgress(mgr, nil)
}

func knownBuildCommit() string {
	if validCommit(buildCommit) {
		return strings.ToLower(buildCommit)
	}
	return ""
}

func validCommit(value string) bool {
	return regexp.MustCompile(`^[0-9a-fA-F]{40}$`).MatchString(value)
}
