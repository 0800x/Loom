package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

type groupCallsSetup struct {
	IP    string
	Limit int
	Video bool
}
type groupCallsForm struct {
	setup  groupCallsSetup
	field  int
	review bool
	err    string
}
type groupCallsAppliedMsg struct {
	err     error
	enabled bool
}

const groupCallsOverlay = `services:
  livekit:
    image: livekit/livekit-server:v1.13.9
    restart: unless-stopped
    command: ["--config", "/etc/livekit.yaml", "--node-ip", "${LOOM_GROUP_CALLS_PUBLIC_IP:?set server public IPv4}"]
    volumes:
      - ./livekit.yaml:/etc/livekit.yaml:ro
    ports:
      - "7881:7881/tcp"
      - "50000-50100:50000-50100/udp"
    expose:
      - "7880"
`

func (s groupCallsSetup) validate() error {
	ip, err := netip.ParseAddr(s.IP)
	if err != nil || !ip.Is4() || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.String() == "0.0.0.0" {
		return fmt.Errorf("Enter this server's reachable public IPv4")
	}
	for _, block := range []string{"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4"} {
		if netip.MustParsePrefix(block).Contains(ip) {
			return fmt.Errorf("Use a public, routable IPv4")
		}
	}
	if s.Limit < 2 || s.Limit > 32 {
		return fmt.Errorf("Participant limit must be 2–32")
	}
	return nil
}

func credentialValid(s string, minimum int) bool {
	if len(s) < minimum || len(s) > 512 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func randomCredential(size int) (string, error) {
	b := make([]byte, size)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func groupCallsEnv(path string) map[string]string {
	values := loadEnv(path)
	for k, v := range values {
		if len(v) >= 2 && ((v[0] == 34 && v[len(v)-1] == 34) || (v[0] == 39 && v[len(v)-1] == 39)) {
			values[k] = v[1 : len(v)-1]
		}
	}
	return values
}

func groupCallsConfig(original string, values map[string]string, s groupCallsSetup) (string, string, error) {
	if err := s.validate(); err != nil {
		return "", "", err
	}
	key, secret := strings.Trim(values["LOOM_GROUP_CALLS_API_KEY"], "\"'"), strings.Trim(values["LOOM_GROUP_CALLS_API_SECRET"], "\"'")
	var err error
	if key == "" {
		key, err = randomCredential(12)
		if err != nil {
			return "", "", err
		}
		key = "gc_" + key
	}
	if secret == "" {
		secret, err = randomCredential(32)
		if err != nil {
			return "", "", err
		}
	}
	if !credentialValid(key, 8) || !credentialValid(secret, 32) {
		return "", "", fmt.Errorf("Existing media credentials are invalid; no settings changed")
	}
	for _, name := range []string{"LOOM_ADMIN_TOKEN", "LOOM_TURN_SHARED_SECRET", "LOOM_S3_SECRET_ACCESS_KEY"} {
		if secret == strings.Trim(values[name], "\"'") {
			return "", "", fmt.Errorf("Media credentials must be independent of other service secrets")
		}
	}
	settings := []struct{ k, v string }{
		{"LOOM_CALLS_ENABLED", "true"}, {"LOOM_VOICE_CALLS_ENABLED", "true"}, {"LOOM_VIDEO_CALLS_ENABLED", strconv.FormatBool(s.Video)},
		{"LOOM_GROUP_CALLS_ENABLED", "true"}, {"LOOM_GROUP_CALLS_API_URL", "http://livekit:7880"}, {"LOOM_GROUP_CALLS_API_KEY", key}, {"LOOM_GROUP_CALLS_API_SECRET", secret},
		{"LOOM_GROUP_CALLS_MAX_PARTICIPANTS", strconv.Itoa(s.Limit)}, {"LOOM_GROUP_CALLS_PUBLIC_IP", s.IP},
	}
	for _, setting := range settings {
		original = replaceEnvSetting(original, setting.k, setting.v)
	}
	config := fmt.Sprintf("port: 7880\nrtc:\n  tcp_port: 7881\n  port_range_start: 50000\n  port_range_end: 50100\n  use_external_ip: false\nkeys:\n  %s: %s\nwebhook:\n  api_key: %s\n  urls:\n    - http://loom-node:7483/api/v1/group-calls/webhook\nlogging:\n  level: warn\n", strconv.Quote(key), strconv.Quote(secret), strconv.Quote(key))
	return original, config, nil
}

type mediaCommand func(args ...string) error

func (m manager) mediaCommand(args ...string) error {
	if len(args) == 1 && args[0] == "verify-group-calls" {
		d, err := m.readDiagnostics()
		if err != nil || d == nil || d.Calls == nil || !d.Calls.GroupCallsEnabled {
			return fmt.Errorf("Running Node did not enable group calls; update Node before setup")
		}
		args = []string{"exec", "-T", "loom-node", "node", "--input-type=module", "-e", groupMediaProbe}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "docker", m.composeArgs(args...)...)
	// Do not echo Docker output: configuration errors can contain secrets.
	if output, err := cmd.CombinedOutput(); err != nil {
		if len(args) > 0 && args[0] == "exec" {
			return fmt.Errorf("%s", groupMediaFailure(output))
		}
		return fmt.Errorf("Media service operation failed (%s); inspect service status", strings.Join(args[:min(2, len(args))], " "))
	}
	return nil
}

func (m manager) applyGroupCalls(s groupCallsSetup, enabled bool, run mediaCommand) error {
	release, err := m.lockGroupCallsSetup()
	if err != nil {
		return err
	}
	defer release()
	info, err := os.Lstat(m.deployDir)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 {
		return fmt.Errorf("Installation configuration directory is unsafe")
	}
	paths := []string{m.envPath, filepath.Join(m.deployDir, "livekit.yaml"), filepath.Join(m.deployDir, "docker-compose.group-calls.yml")}
	originals := make([][]byte, len(paths))
	present := make([]bool, len(paths))
	for i, path := range paths {
		info, err := os.Lstat(path)
		if os.IsNotExist(err) && i > 0 {
			continue
		}
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("Configuration must be a regular file: %s", filepath.Base(path))
		}
		originals[i], err = os.ReadFile(path)
		if err != nil {
			return err
		}
		present[i] = true
	}
	next, config := string(originals[0]), ""
	if enabled {
		next, config, err = groupCallsConfig(next, groupCallsEnv(m.envPath), s)
		if err != nil {
			return err
		}
	} else {
		next = replaceEnvSetting(next, "LOOM_GROUP_CALLS_ENABLED", "false")
		if validateCalling(groupCallsEnv(m.envPath)) != nil {
			next = replaceEnvSetting(next, "LOOM_CALLS_ENABLED", "false")
		}
	}
	backup, err := os.MkdirTemp(m.home, "group-calls-backup-")
	if err != nil {
		return err
	}
	if err = os.Chmod(backup, 0o700); err != nil {
		return err
	}
	for i, path := range paths {
		if present[i] {
			if err = writeFileAtomic(filepath.Join(backup, filepath.Base(path)), originals[i], 0o600); err != nil {
				return err
			}
		}
	}
	rollback := func(cause error) error {
		var restoreErr error
		if enabled && !present[2] {
			_ = run("stop", "livekit")
		}
		for i, path := range paths {
			var e error
			if present[i] {
				e = writeFileAtomic(path, originals[i], 0o600)
			} else {
				e = os.Remove(path)
				if os.IsNotExist(e) {
					e = nil
				}
			}
			if e != nil {
				restoreErr = e
			}
		}
		if restoreErr != nil {
			return fmt.Errorf("Setup failed; restoration needs attention. Backup: %s", backup)
		}
		if present[2] && present[1] && groupCallsEnv(m.envPath)["LOOM_GROUP_CALLS_ENABLED"] == "true" {
			if e := run("up", "-d", "--force-recreate", "livekit"); e != nil {
				restoreErr = e
			}
		}
		if restoreErr != nil {
			return fmt.Errorf("Settings restored; media restart needs attention. Backup: %s", backup)
		}
		if e := run("up", "-d", "--no-deps", "--force-recreate", "--wait", "--wait-timeout", "120", "loom-node"); e != nil {
			return fmt.Errorf("Settings restored; Node restart needs attention. Backup: %s", backup)
		}
		return fmt.Errorf("%w; previous settings restored. Backup: %s", cause, backup)
	}
	bodies := [][]byte{[]byte(next), []byte(config), []byte(groupCallsOverlay)}
	for i, path := range paths {
		if !enabled && i > 0 {
			continue
		}
		if err = writeFileAtomic(path, bodies[i], 0o600); err != nil {
			return rollback(err)
		}
	}
	for _, args := range [][]string{{"config", "--quiet"}, {"up", "-d", "--no-deps", "--force-recreate", "livekit"}, {"up", "-d", "--no-deps", "--force-recreate", "--wait", "--wait-timeout", "120", "loom-node"}} {
		if !enabled && len(args) > 0 && args[len(args)-1] == "livekit" {
			continue
		}
		if err = run(args...); err != nil {
			return rollback(err)
		}
	}
	if enabled {
		if err = run("verify-group-calls"); err != nil {
			return rollback(err)
		}
	}
	if !enabled && present[2] {
		if err = run("stop", "livekit"); err != nil {
			return fmt.Errorf("Group calls disabled; media service stop needs attention")
		}
	}
	return nil
}

func groupCallsApplyCmd(mgr manager, s groupCallsSetup, enabled bool) tea.Cmd {
	return func() tea.Msg {
		return groupCallsAppliedMsg{mgr.applyGroupCalls(s, enabled, mgr.mediaCommand), enabled}
	}
}

func (m model) openGroupCallsForm() model {
	values := groupCallsEnv(m.mgr.envPath)
	limit, _ := strconv.Atoi(values["LOOM_GROUP_CALLS_MAX_PARTICIPANTS"])
	if limit < 2 || limit > 32 {
		limit = 16
	}
	ip := values["LOOM_GROUP_CALLS_PUBLIC_IP"]
	if ip == "" {
		if addresses, err := net.InterfaceAddrs(); err == nil {
			for _, address := range addresses {
				prefix, e := netip.ParsePrefix(address.String())
				if e == nil {
					candidate := groupCallsSetup{prefix.Addr().String(), limit, true}
					if candidate.validate() == nil {
						ip = candidate.IP
						break
					}
				}
			}
		}
	}
	m.groupCallsForm = &groupCallsForm{setup: groupCallsSetup{ip, limit, values["LOOM_VIDEO_CALLS_ENABLED"] != "false"}}
	return m
}

func (f groupCallsForm) view() string {
	if f.review {
		return titleStyle.Render("Review group calling setup") + fmt.Sprintf("\n\nServer IP: %s\nParticipants: %d\nVideo: %t\n\nMedia credentials: generated automatically or preserved (hidden).\nSettings backed up; only Node and media service are restarted.\nActive calls will end. Video policy also applies to direct calls.\nAllow TCP 7881 and UDP 50000–50100 in your provider firewall.\nTCP 7880 stays private. Provider firewall rules cannot be changed here.\n\nEnter: apply   Esc: edit   PgUp/PgDn: scroll\n%s", f.setup.IP, f.setup.Limit, f.setup.Video, f.err)
	}
	cursor := ""
	if f.field == 0 {
		cursor = "▏"
	}
	fields := []string{"Public server IPv4: " + f.setup.IP + cursor, "Participant limit: " + strconv.Itoa(f.setup.Limit), "Video: " + status(f.setup.Video, "Allowed", "Disabled"), "Review and apply"}
	for i := range fields {
		if i == f.field {
			fields[i] = "› " + fields[i]
		} else {
			fields[i] = "  " + fields[i]
		}
	}
	return titleStyle.Render("Set up group voice & video") + "\n\n" + strings.Join(fields, "\n\n") + "\n\nTab/↑/↓: select   ←/→/Space: change   Enter: next\nEsc: cancel   Type IPv4 in first field   PgUp/PgDn: scroll\n\n" + f.err
}

func (m model) updateGroupCallsForm(key string) (tea.Model, tea.Cmd) {
	f := m.groupCallsForm
	if m.busy {
		return m, nil
	}
	if key == "ctrl+c" {
		return m, tea.Quit
	}
	if key == "esc" {
		if f.review {
			f.review = false
		} else {
			m.groupCallsForm = nil
		}
		return m, nil
	}
	f.err = ""
	if f.review {
		if key == "enter" {
			m.busy = true
			return m, groupCallsApplyCmd(m.mgr, f.setup, true)
		}
		return m, nil
	}
	switch key {
	case "tab", "down":
		f.field = (f.field + 1) % 4
	case "shift+tab", "up":
		f.field = (f.field + 3) % 4
	case "left", "right", " ":
		if f.field == 1 {
			delta := 1
			if key == "left" {
				delta = -1
			}
			f.setup.Limit = max(2, min(32, f.setup.Limit+delta))
		}
		if f.field == 2 {
			f.setup.Video = !f.setup.Video
		}
	case "backspace":
		if f.field == 0 && len(f.setup.IP) > 0 {
			f.setup.IP = f.setup.IP[:len(f.setup.IP)-1]
		}
	case "enter":
		if f.field < 3 {
			f.field++
		} else if err := f.setup.validate(); err != nil {
			f.err = err.Error()
		} else {
			f.review = true
		}
	default:
		if f.field == 0 && len(f.setup.IP)+len(key) <= 15 {
			valid := true
			for _, c := range key {
				if !(c >= '0' && c <= '9' || c == '.') {
					valid = false
				}
			}
			if valid {
				f.setup.IP += key
			}
		}
	}
	return m, nil
}
