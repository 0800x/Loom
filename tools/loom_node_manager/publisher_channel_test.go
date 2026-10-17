package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPublisherMetadataIsBoundToLoomAndImmutableSource(t *testing.T) {
	valid := publisherRelease{Schema: 1, Repository: defaultUpdateRepository, Branch: "main", Revision: strings.Repeat("a", 40), SHA256: strings.Repeat("b", 64), Sequence: 2}
	body, _ := json.Marshal(valid)
	if _, err := parsePublisherRelease(body); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*publisherRelease){func(r *publisherRelease) { r.Repository = "other/Loom" }, func(r *publisherRelease) { r.Branch = "feature" }, func(r *publisherRelease) { r.Revision = "main" }, func(r *publisherRelease) { r.SHA256 = "unverified" }, func(r *publisherRelease) { r.Sequence = 0 }, func(r *publisherRelease) { r.Schema = 2 }} {
		invalid := valid
		change(&invalid)
		body, _ := json.Marshal(invalid)
		if _, err := parsePublisherRelease(body); err == nil {
			t.Fatalf("accepted invalid publisher identity: %+v", invalid)
		}
	}
	for _, invalid := range []string{string(body) + " {}", `{"schema":1,"url":"https://example.org/source"}`, strings.Repeat("a", 4097)} {
		if _, err := parsePublisherRelease([]byte(invalid)); err == nil {
			t.Fatal("accepted malformed metadata")
		}
	}
}
func TestPublisherRollbackAndSameSequenceReplacementAreRejected(t *testing.T) {
	installed := publisherInstall{Revision: strings.Repeat("a", 40), Sequence: 4}
	for _, release := range []publisherRelease{{Revision: installed.Revision, Sequence: 3}, {Revision: strings.Repeat("b", 40), Sequence: 4}} {
		if validatePublisherSelection(release, installed) == nil {
			t.Fatal("rollback/replacement was accepted")
		}
	}
	for _, release := range []publisherRelease{{Revision: installed.Revision, Sequence: 4}, {Revision: strings.Repeat("b", 40), Sequence: 5}} {
		if err := validatePublisherSelection(release, installed); err != nil {
			t.Fatal(err)
		}
	}
}
func TestPublisherPolicyFailsClosedWithoutChangingOperatorPolicy(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("root-protected policy fixture")
	}
	root := t.TempDir()
	dir := filepath.Join(root, "policy")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "update-policy")
	if enabled, err := publisherPolicyEnabled(path); err != nil || enabled {
		t.Fatal(enabled, err)
	}
	for _, item := range []struct {
		value   string
		enabled bool
		invalid bool
	}{{"publisher", true, false}, {"operator", false, false}, {"arbitrary", false, true}} {
		if err := os.WriteFile(path, []byte(item.value), 0600); err != nil {
			t.Fatal(err)
		}
		enabled, err := publisherPolicyEnabled(path)
		if (err != nil) != item.invalid || enabled != item.enabled {
			t.Fatal(item, enabled, err)
		}
	}
	if err := os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if _, err := publisherPolicyEnabled(path); err == nil {
		t.Fatal("writable policy was trusted")
	}
}
func TestPublisherInstallRecordsPreserveSequenceFloor(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("root-protected installation fixture")
	}
	home := filepath.Join(t.TempDir(), "node")
	if err := os.Mkdir(home, 0700); err != nil {
		t.Fatal(err)
	}
	a, b := strings.Repeat("a", 40), strings.Repeat("b", 40)
	if err := recordPublisherInstall(home, a, 4); err != nil {
		t.Fatal(err)
	}
	if err := recordPublisherInstall(home, b, 3); err != nil {
		t.Fatal(err)
	}
	record, err := readPublisherInstall(home)
	if err != nil || record.Revision != b || record.Sequence != 4 {
		t.Fatal(record, err)
	}
	path := filepath.Join(home, ".loom-publisher-state")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(home, "missing"), path); err != nil {
		t.Fatal(err)
	}
	if _, err := readPublisherInstall(home); err == nil {
		t.Fatal("symlinked rollback state was trusted")
	}
}
