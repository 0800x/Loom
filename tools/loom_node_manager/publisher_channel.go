package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const publisherChannelURL = "https://raw.githubusercontent.com/0800x/Loom/main/release/node-channel.json"
const updatePolicyPath = "/etc/loom/update-policy"

type publisherRelease struct {
	Schema     int    `json:"schema"`
	Repository string `json:"repository"`
	Branch     string `json:"branch"`
	Revision   string `json:"revision"`
	SHA256     string `json:"sha256"`
	Sequence   uint64 `json:"sequence"`
}
type publisherInstall struct {
	Revision string `json:"revision"`
	Sequence uint64 `json:"sequence"`
}

func parsePublisherRelease(body []byte) (publisherRelease, error) {
	var release publisherRelease
	if len(body) > 4096 {
		return release, fmt.Errorf("publisher metadata exceeds the size limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&release); err != nil {
		return release, fmt.Errorf("invalid publisher metadata")
	}
	if decoder.Decode(&struct{}{}) != io.EOF || release.Schema != 1 || release.Repository != defaultUpdateRepository || release.Branch != defaultUpdateBranch || !regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(release.Revision) || !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(release.SHA256) || release.Sequence == 0 {
		return release, fmt.Errorf("publisher metadata does not identify an approved Loom source")
	}
	return release, nil
}

func publisherPolicyEnabled(path string) (bool, error) {
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return false, nil
	}
	if err := requirePrivateRootFile(path); err != nil {
		return false, err
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	switch strings.TrimSpace(string(body)) {
	case "publisher":
		return true, nil
	case "operator":
		return false, nil
	default:
		return false, fmt.Errorf("invalid protected update policy")
	}
}

func fetchPublisherRelease() (publisherRelease, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := updateCommand(ctx, "curl", "--proto", "=https", "--tlsv1.2", "--fail", "--silent", "--show-error", "--max-time", "15", "--max-filesize", "4096", "--max-redirs", "0", publisherChannelURL)
	cmd.Dir = "/"
	if err := dropUpdatePrivileges(cmd); err != nil {
		return publisherRelease{}, err
	}
	body, err := cmd.Output()
	if err != nil {
		return publisherRelease{}, fmt.Errorf("trusted publisher channel unavailable; no alternate source was selected")
	}
	return parsePublisherRelease(body)
}

func readPublisherInstall(home string) (publisherInstall, error) {
	var record publisherInstall
	path := filepath.Join(home, ".loom-publisher-state")
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return record, nil
	}
	if err := requirePrivateRootFile(path); err != nil {
		return record, err
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return record, err
	}
	if json.Unmarshal(body, &record) != nil || !validCommit(record.Revision) || record.Sequence == 0 {
		return record, fmt.Errorf("invalid protected publisher state")
	}
	return record, nil
}
func validatePublisherSelection(release publisherRelease, installed publisherInstall) error {
	if installed.Sequence > release.Sequence || (installed.Sequence == release.Sequence && installed.Revision != "" && installed.Revision != release.Revision) {
		return fmt.Errorf("publisher metadata is older than this installation; downgrade refused")
	}
	return nil
}
func recordPublisherInstall(home, revision string, sequence uint64) error {
	if !validCommit(revision) || sequence == 0 {
		return fmt.Errorf("invalid installed publisher revision")
	}
	previous, err := readPublisherInstall(home)
	if err != nil {
		return err
	}
	if previous.Sequence > sequence {
		sequence = previous.Sequence
	}
	body, _ := json.Marshal(publisherInstall{Revision: revision, Sequence: sequence})
	return writeFileAtomic(filepath.Join(home, ".loom-publisher-state"), append(body, '\n'), 0600)
}

func selectPublisherRelease(mgr manager, status updateStatus, release publisherRelease) (updateStatus, error) {
	installed, err := readPublisherInstall(mgr.home)
	if err != nil {
		return status, err
	}
	if err = validatePublisherSelection(release, installed); err != nil {
		return status, err
	}
	status.AvailableCommit = release.Revision
	status.SourceDigest = release.SHA256
	status.PublisherSequence = release.Sequence
	status.Detail = "Trusted publisher channel (HTTPS); installation requires your explicit action"
	return status, nil
}

func selectedUpdateDigest(mgr manager, status updateStatus) (string, error) {
	enabled, err := publisherPolicyEnabled(updatePolicyPath)
	if err != nil {
		return "", err
	}
	if !enabled {
		return approvedReleaseDigest("/etc/loom/approved-releases", status.Repository, status.AvailableCommit)
	}
	if status.Repository != defaultUpdateRepository || status.Branch != defaultUpdateBranch || status.PublisherSequence == 0 || !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(status.SourceDigest) {
		return "", fmt.Errorf("selected update lacks trusted publisher metadata")
	}
	release := publisherRelease{Revision: status.AvailableCommit, Sequence: status.PublisherSequence}
	installed, err := readPublisherInstall(mgr.home)
	if err != nil {
		return "", err
	}
	if err = validatePublisherSelection(release, installed); err != nil {
		return "", err
	}
	return status.SourceDigest, nil
}
