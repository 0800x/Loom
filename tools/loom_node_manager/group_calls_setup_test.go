package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func setupFixture(t *testing.T) manager {
	t.Helper()
	m := newManager(t.TempDir())
	if err := os.MkdirAll(m.deployDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.envPath, []byte("# Existing installation\nLOOM_ADMIN_TOKEN=unrelated-secret\nLOOM_VIDEO_CALLS_ENABLED=false\nDATABASE_URL=postgres://existing\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestGroupMediaFormAcceptsPasteInsideDashboard(t *testing.T) {
	m := initialDashboardModel(setupFixture(t))
	m.inner = m.inner.openGroupCallsForm()
	m.inner.groupCallsForm.setup.IP = ""
	updated, cmd := m.Update(tea.PasteMsg{Content: "8.8.4.4"})
	m = updated.(dashboardModel)
	if cmd != nil || m.inner.groupCallsForm.setup.IP != "8.8.4.4" {
		t.Fatal("paste was not routed to setup form")
	}
	if !strings.Contains(m.pageContent(), "Participant limit") {
		t.Fatal("dashboard hid setup form")
	}
}

func TestGroupMediaConfigurationPreservesQuotedTURNOnDisable(t *testing.T) {
	m := setupFixture(t)
	body := `LOOM_GROUP_CALLS_ENABLED=true
LOOM_CALLS_ENABLED=true
LOOM_TURN_URLS="turn:turn.example.org:3478"
LOOM_TURN_SHARED_SECRET='12345678901234567890123456789012'
`
	if err := os.WriteFile(m.envPath, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := m.applyGroupCalls(groupCallsSetup{}, false, func(...string) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if loadEnv(m.envPath)["LOOM_CALLS_ENABLED"] != "true" {
		t.Fatal("disabled configured direct calls")
	}
}
func TestGroupMediaAutomaticConfigurationPreservesSecretsAndOtherSettings(t *testing.T) {
	m := setupFixture(t)
	s := groupCallsSetup{"8.8.4.4", 16, false}
	var calls []string
	run := func(args ...string) error { calls = append(calls, strings.Join(args, " ")); return nil }
	if err := m.applyGroupCalls(s, true, run); err != nil {
		t.Fatal(err)
	}
	values := loadEnv(m.envPath)
	key, secret := values["LOOM_GROUP_CALLS_API_KEY"], values["LOOM_GROUP_CALLS_API_SECRET"]
	if !credentialValid(key, 8) || !credentialValid(secret, 32) || secret == values["LOOM_ADMIN_TOKEN"] {
		t.Fatal("missing independent credentials")
	}
	if values["DATABASE_URL"] != "postgres://existing" || values["LOOM_ADMIN_TOKEN"] != "unrelated-secret" || values["LOOM_VIDEO_CALLS_ENABLED"] != "false" {
		t.Fatal("unrelated or selected policy changed")
	}
	for _, name := range []string{".env", "livekit.yaml", "docker-compose.group-calls.yml"} {
		info, err := os.Stat(filepath.Join(m.deployDir, name))
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatal(name, info, err)
		}
	}
	if !strings.Contains(strings.Join(calls, "\n"), "verify-group-calls") {
		t.Fatal("did not verify running policy and API")
	}
	if err := m.applyGroupCalls(groupCallsSetup{s.IP, 20, true}, true, run); err != nil {
		t.Fatal(err)
	}
	next := loadEnv(m.envPath)
	if next["LOOM_GROUP_CALLS_API_KEY"] != key || next["LOOM_GROUP_CALLS_API_SECRET"] != secret {
		t.Fatal("setup rotated credentials")
	}
	if next["LOOM_GROUP_CALLS_MAX_PARTICIPANTS"] != "20" || next["LOOM_VIDEO_CALLS_ENABLED"] != "true" {
		t.Fatal("requested edits not applied")
	}
	overlay, _ := os.ReadFile(filepath.Join(m.deployDir, "docker-compose.group-calls.yml"))
	if strings.Contains(string(overlay), "7880:7880") {
		t.Fatal("private signaling exposed")
	}
}
func TestGroupMediaFailedFirstSetupRestoresFilesAndStopsNewService(t *testing.T) {
	for _, stage := range []string{"config --quiet", "up -d --no-deps --force-recreate livekit", "verify-group-calls"} {
		t.Run(stage, func(t *testing.T) {
			m := setupFixture(t)
			original, _ := os.ReadFile(m.envPath)
			var calls []string
			failed := false
			run := func(args ...string) error {
				call := strings.Join(args, " ")
				calls = append(calls, call)
				if call == stage && !failed {
					failed = true
					return errors.New("injected startup failure")
				}
				return nil
			}
			if err := m.applyGroupCalls(groupCallsSetup{"8.8.4.4", 16, true}, true, run); err == nil || !strings.Contains(err.Error(), "restored") {
				t.Fatal(err)
			}
			restored, _ := os.ReadFile(m.envPath)
			if string(original) != string(restored) {
				t.Fatal("environment not restored")
			}
			for _, file := range []string{"livekit.yaml", "docker-compose.group-calls.yml"} {
				if _, err := os.Stat(filepath.Join(m.deployDir, file)); !os.IsNotExist(err) {
					t.Fatal("new file left after rollback", file, err)
				}
			}
			if !strings.Contains(strings.Join(calls, "\n"), "stop livekit") {
				t.Fatal("new service not stopped")
			}
		})
	}
}
func TestGroupMediaRollbackRestartsExistingMediaWithPreviousSettings(t *testing.T) {
	m := setupFixture(t)
	s := groupCallsSetup{"8.8.4.4", 16, false}
	if err := m.applyGroupCalls(s, true, func(...string) error { return nil }); err != nil {
		t.Fatal(err)
	}
	original, _ := os.ReadFile(m.envPath)
	yaml, _ := os.ReadFile(filepath.Join(m.deployDir, "livekit.yaml"))
	var restored bool
	err := m.applyGroupCalls(groupCallsSetup{s.IP, 24, true}, true, func(args ...string) error {
		call := strings.Join(args, " ")
		if call == "verify-group-calls" {
			return errors.New("unreachable")
		}
		if call == "up -d --force-recreate livekit" {
			restored = true
		}
		return nil
	})
	if err == nil || !restored {
		t.Fatal("missing rollback/restart", err)
	}
	after, _ := os.ReadFile(m.envPath)
	afterYAML, _ := os.ReadFile(filepath.Join(m.deployDir, "livekit.yaml"))
	if string(after) != string(original) || string(afterYAML) != string(yaml) {
		t.Fatal("previous files changed")
	}
}
func TestGroupMediaDisableKeepsKeysAndDoesNotRequirePublicIP(t *testing.T) {
	m := setupFixture(t)
	if err := m.applyGroupCalls(groupCallsSetup{"8.8.4.4", 16, true}, true, func(...string) error { return nil }); err != nil {
		t.Fatal(err)
	}
	before := loadEnv(m.envPath)
	var calls []string
	if err := m.applyGroupCalls(groupCallsSetup{}, false, func(args ...string) error { calls = append(calls, strings.Join(args, " ")); return nil }); err != nil {
		t.Fatal(err)
	}
	after := loadEnv(m.envPath)
	if after["LOOM_GROUP_CALLS_ENABLED"] != "false" || after["LOOM_CALLS_ENABLED"] != "false" || after["LOOM_GROUP_CALLS_API_SECRET"] != before["LOOM_GROUP_CALLS_API_SECRET"] {
		t.Fatal("disable lost keys or left group-only calls enabled")
	}
	if strings.Contains(strings.Join(calls, "\n"), "up -d --no-deps --force-recreate livekit") || !strings.Contains(strings.Join(calls, "\n"), "stop livekit") {
		t.Fatal(calls)
	}
}
func TestGroupMediaInputRejectionLeavesConfigurationUntouched(t *testing.T) {
	for _, ip := range []string{"127.0.0.1", "10.0.0.1", "100.64.0.2", "203.0.113.1", "224.0.0.1", "::1", "8.8.4.4\nBAD=true"} {
		m := setupFixture(t)
		before, _ := os.ReadFile(m.envPath)
		if err := m.applyGroupCalls(groupCallsSetup{ip, 16, true}, true, func(...string) error { t.Fatal("invalid input ran Docker"); return nil }); err == nil {
			t.Fatal("accepted", ip)
		}
		after, _ := os.ReadFile(m.envPath)
		if string(before) != string(after) {
			t.Fatal("rejected input changed settings")
		}
	}
	m := setupFixture(t)
	target := filepath.Join(m.home, "secret")
	if err := os.Symlink(target, filepath.Join(m.deployDir, "livekit.yaml")); err != nil {
		t.Fatal(err)
	}
	if err := m.applyGroupCalls(groupCallsSetup{"8.8.4.4", 16, true}, true, func(...string) error { return nil }); err == nil {
		t.Fatal("followed configuration symlink")
	}
}
func TestGroupMediaFormRequiresReviewAndBlocksQuitDuringApply(t *testing.T) {
	m := initialModel(setupFixture(t)).openGroupCallsForm()
	m.groupCallsForm.setup.IP = "8.8.4.4"
	m.groupCallsForm.field = 3
	updated, cmd := m.updateGroupCallsForm("enter")
	m = updated.(model)
	if cmd != nil || !m.groupCallsForm.review || m.busy {
		t.Fatal("applied before review")
	}
	if strings.Contains(m.groupCallsForm.view(), "LOOM_GROUP_CALLS_API_SECRET") {
		t.Fatal("form exposes secret field")
	}
	updated, cmd = m.updateGroupCallsForm("enter")
	m = updated.(model)
	if cmd == nil || !m.busy {
		t.Fatal("review did not start apply")
	}
	_, quit := m.updateGroupCallsForm("ctrl+c")
	if quit != nil {
		t.Fatal("quit abandoned running setup")
	}
}

func TestGroupMediaFailureNeverIncludesRawDockerOutput(t *testing.T) {
	for _, code := range []string{"CONFIG", "SDK", "AUTH", "DNS", "TIMEOUT", "UNAVAILABLE", "UNKNOWN"} {
		result := groupMediaFailure([]byte("secret-token=do-not-display\nLOOM_MEDIA_" + code + "\nprivate URL and secret"))
		if strings.Contains(result, "do-not-display") || strings.Contains(result, "private URL") || result == "" {
			t.Fatalf("unsafe or empty diagnostic for %s: %q", code, result)
		}
	}
}

func TestGroupMediaSetupAlwaysRestartsMediaAfterWritingConfiguration(t *testing.T) {
	m := setupFixture(t)
	var calls []string
	if err := m.applyGroupCalls(groupCallsSetup{"8.8.4.4", 16, true}, true, func(args ...string) error {
		calls = append(calls, strings.Join(args, " "))
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(calls, "\n"), "up -d --no-deps --force-recreate livekit") {
		t.Fatal("bind-mounted media configuration was not reloaded")
	}
}
