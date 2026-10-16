package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

type updateProgress struct {
	Percent int
	Stage   string
}

func reportUpdateProgress(report func(updateProgress), percent int, stage string) {
	if report == nil {
		return
	}
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	report(updateProgress{Percent: percent, Stage: stage})
}

type updateOutputTracker struct {
	mu      sync.Mutex
	output  strings.Builder
	pending string
	report  func(updateProgress)
}

func (w *updateOutputTracker) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	text := string(p)
	w.output.WriteString(text)
	w.pending += text
	for {
		index := strings.IndexByte(w.pending, '\n')
		if index < 0 {
			break
		}
		line := strings.TrimSpace(w.pending[:index])
		w.pending = w.pending[index+1:]
		w.consume(line)
	}
	return len(p), nil
}

func (w *updateOutputTracker) consume(line string) {
	if line == "" {
		return
	}
	switch {
	case strings.Contains(line, "[1/7]"):
		reportUpdateProgress(w.report, 62, "Checking runtime prerequisites")
	case strings.Contains(line, "[2/7]"):
		reportUpdateProgress(w.report, 66, "Selecting reverse proxy")
	case strings.Contains(line, "[3/7]"):
		reportUpdateProgress(w.report, 71, "Installing updated Node bundle and Manager")
	case strings.Contains(line, "[4/7]"):
		reportUpdateProgress(w.report, 76, "Preserving production configuration")
	case strings.Contains(line, "[5/7]"):
		reportUpdateProgress(w.report, 80, "Checking network configuration")
	case strings.Contains(line, "[6/7]"):
		reportUpdateProgress(w.report, 85, "Building and starting updated Loom Node")
	case strings.Contains(line, "[7/7]"):
		reportUpdateProgress(w.report, 93, "Verifying HTTPS and Node readiness")
	case strings.Contains(line, "Installation complete"):
		reportUpdateProgress(w.report, 96, "Production installer completed")
	}
}

func (w *updateOutputTracker) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	if strings.TrimSpace(w.pending) != "" {
		w.consume(w.pending)
		w.pending = ""
	}
	return strings.TrimSpace(w.output.String())
}

func runUpdateInstallerWithProgress(timeout time.Duration, dir, installer string, report func(updateProgress), args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmdArgs := append([]string{installer}, args...)
	cmd := updateCommand(ctx, "bash", cmdArgs...)
	cmd.Dir = dir

	tracker := &updateOutputTracker{report: report}
	cmd.Stdout = tracker
	cmd.Stderr = tracker
	err := cmd.Run()
	output := tracker.String()
	if ctx.Err() == context.DeadlineExceeded {
		return output, fmt.Errorf("command timed out")
	}
	if err != nil {
		if output == "" {
			return output, err
		}
		return output, fmt.Errorf("%w: %s", err, output)
	}
	return output, nil
}

func applyNodeUpdateWithProgress(mgr manager, report func(updateProgress)) (updateStatus, string, error) {
	reportUpdateProgress(report, 5, "Checking repository and installed revision")
	status := checkNodeUpdate(mgr)
	if status.State != "update_available" {
		return status, "", fmt.Errorf("no update is available")
	}
	if runtime.GOOS != "linux" {
		return status, "", fmt.Errorf("self-update is currently available on Linux nodes")
	}

	if !validCommit(status.AvailableCommit) {
		return status, "", fmt.Errorf("invalid selected update commit")
	}
	reportUpdateProgress(report, 15, "Preparing isolated update workspace")
	tempRoot, err := os.MkdirTemp("", "loom-node-update-")
	if err != nil {
		return status, "", err
	}
	defer os.RemoveAll(tempRoot)
	digest, err := approvedReleaseDigest("/etc/loom/approved-releases", status.Repository, status.AvailableCommit)
	if err != nil {
		return status, "", err
	}
	reportUpdateProgress(report, 30, "Fetching and verifying immutable approved release")
	checkout, err := prepareApprovedUpdate(tempRoot, status.Repository, status.AvailableCommit, digest)
	if err != nil {
		return status, "", err
	}

	reportUpdateProgress(report, 48, "Validating production installer")
	installer := filepath.Join(checkout, "services", "loom_server", "scripts", "linux", "install-production.sh")
	if _, err := os.Stat(installer); err != nil {
		return status, "", fmt.Errorf("update source does not contain the production installer")
	}
	if scripts, _ := filepath.Glob(filepath.Join(checkout, "services", "loom_server", "scripts", "linux", "*.sh")); len(scripts) > 0 {
		for _, script := range scripts {
			if _, err := runUpdateCommand(15*time.Second, checkout, "bash", "-n", script); err != nil {
				return status, "", fmt.Errorf("update script validation failed: %w", err)
			}
		}
	}

	reportUpdateProgress(report, 58, "Starting production installer")
	output, err := runUpdateInstallerWithProgress(
		20*time.Minute,
		checkout,
		installer,
		report,
		"--install-dir", mgr.home,
		"--update-branch", status.Branch,
		"--update-repository", status.Repository,
		"--update-source-dir", "",
		"--proxy", "auto",
		"--skip-dns-check",
		"--tls-wait", "45",
		"--no-tui",
	)
	if err != nil {
		return status, output, fmt.Errorf("production update failed: %w", err)
	}

	reportUpdateProgress(report, 97, "Verifying running Node revision")
	diagnostics, probeErr := mgr.readDiagnostics()
	if probeErr != nil {
		return status, output, fmt.Errorf("update installed but runtime verification failed: %w", probeErr)
	}
	if !diagnostics.Ready || !strings.EqualFold(diagnostics.Runtime.BuildCommit, status.AvailableCommit) {
		return status, output, fmt.Errorf("runtime revision mismatch: wanted %s, running %s; installation is not confirmed", shortCommit(status.AvailableCommit), shortCommit(diagnostics.Runtime.BuildCommit))
	}
	status.InstalledCommit = status.AvailableCommit
	if status.AvailableVersion != "" {
		status.InstalledVersion = status.AvailableVersion
	}
	status.State = "up_to_date"
	status.AvailableCommit = status.InstalledCommit
	status.AvailableVersion = status.InstalledVersion

	reportUpdateProgress(report, 99, "Persisting update state")
	if err := writeUpdateState(mgr, status); err != nil {
		return status, output, fmt.Errorf("update installed but state persistence failed: %w", err)
	}
	reportUpdateProgress(report, 100, "Update installed successfully")
	return status, output, nil
}
