package main

import (
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/term"
)

func validateICEList(value string, turn bool) error {
	if value == "" { if turn { return fmt.Errorf("at least one TURN URL is required") }; return nil }
	parts := strings.Split(value, ",")
	if len(parts) > 16 { return fmt.Errorf("too many ICE endpoints") }
	for _, raw := range parts {
		scheme, rest, found := strings.Cut(strings.TrimSpace(raw), ":")
		if !found || (turn && scheme != "turn" && scheme != "turns") || (!turn && scheme != "stun") {
			return fmt.Errorf("use stun:host:port or turn[s]:host:port URLs")
		}
		if strings.ContainsAny(rest, "\r\n\t /#@\"'$") { return fmt.Errorf("invalid ICE endpoint") }
		hostPort, query, _ := strings.Cut(rest, "?")
		if query != "" && query != "transport=udp" && query != "transport=tcp" { return fmt.Errorf("invalid ICE transport") }
		parsed, err := url.Parse("https://" + hostPort)
		if err != nil || parsed.Hostname() == "" { return fmt.Errorf("invalid ICE host") }
		if port := parsed.Port(); port != "" {
			p, e := strconv.Atoi(port); if e != nil || p < 1 || p > 65535 { return fmt.Errorf("invalid ICE port") }
		}
		if strings.Contains(parsed.Hostname(), ":") && net.ParseIP(parsed.Hostname()) == nil { return fmt.Errorf("invalid ICE address") }
	}
	return nil
}

func validateCalling(values map[string]string) error {
	if err := validateICEList(values["LOOM_TURN_URLS"], true); err != nil { return err }
	if err := validateICEList(values["LOOM_STUN_URLS"], false); err != nil { return err }
	secret := values["LOOM_TURN_SHARED_SECRET"]
	if len(secret) < 32 || len(secret) > 512 || strings.ContainsAny(secret, "\r\n\t\x00$#\"'` ") {
		return fmt.Errorf("TURN secret must be 32–512 characters, without whitespace or environment expansion characters")
	}
	return nil
}

func callsSetupCmd(mgr manager) tea.Cmd {
	path, err := os.Executable()
	if err != nil { return func() tea.Msg { return terminalFinishedMsg{"Calling setup", err} } }
	return tea.ExecProcess(exec.Command(path, "--home", mgr.home, "--configure-calls"),
		func(err error) tea.Msg { return terminalFinishedMsg{"Calling setup", err} })
}

// Read only through newline: a buffered reader must not prefetch the subsequent
// hidden secret entry and accidentally consume it before ReadPassword runs.
func terminalLine() (string, error) {
	var line []byte
	one := make([]byte, 1)
	for len(line) < 8192 {
		n, err := os.Stdin.Read(one)
		if err != nil { return "", err }
		if n == 0 { return "", io.EOF }
		if one[0] == '\n' { return strings.TrimSpace(string(line)), nil }
		line = append(line, one[0])
	}
	return "", fmt.Errorf("input is too long")
}

func (m manager) configureCalls() error {
	if !term.IsTerminal(os.Stdin.Fd()) { return fmt.Errorf("calling setup requires an interactive terminal") }
	values := loadEnv(m.envPath)
	fmt.Println("Loom · Voice and video calling")
	fmt.Println("Manual TURN configuration for an existing coturn service.")
	fmt.Println("For automatic local coturn install, secret generation, firewall rules and ICE URLs, run: loom setup --turn auto")
	fmt.Println("Enter keeps the current value. The Node is recreated only after confirmation.")
	for _, key := range []string{"LOOM_TURN_URLS", "LOOM_STUN_URLS"} {
		fmt.Printf("%s [%s]: ", key, values[key])
		value, err := terminalLine(); if err != nil { return err }
		if value != "" { values[key] = value }
	}
	fmt.Print("TURN shared secret (hidden; Enter keeps existing): ")
	secret, err := term.ReadPassword(os.Stdin.Fd())
	fmt.Println()
	if err != nil { return err }
	if len(secret) > 0 { values["LOOM_TURN_SHARED_SECRET"] = string(secret) }
	for i := range secret { secret[i] = 0 }
	if err := validateCalling(values); err != nil { return err }
	fmt.Printf("\nTURN: %s\nSTUN: %s\nSecret: configured (hidden)\nVoice: on · Video: on\n", values["LOOM_TURN_URLS"], values["LOOM_STUN_URLS"])
	fmt.Print("Apply and recreate only the Node? [y/N]: ")
	answer, err := terminalLine(); if err != nil { return err }
	if !strings.EqualFold(answer, "y") { fmt.Println("Cancelled."); return nil }
	original, err := os.ReadFile(m.envPath); if err != nil { return err }
	next := string(original)
	values["LOOM_CALLS_ENABLED"] = "true"
	values["LOOM_VOICE_CALLS_ENABLED"] = "true"
	values["LOOM_VIDEO_CALLS_ENABLED"] = "true"
	for _, key := range []string{"LOOM_TURN_URLS", "LOOM_STUN_URLS", "LOOM_TURN_SHARED_SECRET", "LOOM_CALLS_ENABLED", "LOOM_VOICE_CALLS_ENABLED", "LOOM_VIDEO_CALLS_ENABLED"} {
		next = replaceEnvSetting(next, key, values[key])
	}
	if err := writeFileAtomic(m.envPath, []byte(next), 0o600); err != nil { return err }
	_, err = m.reconcileNode()
	if err == nil {
		d, checkErr := m.readDiagnostics()
		if checkErr != nil || d == nil || d.Calls == nil || !d.Calls.RTCReady { err = fmt.Errorf("running Node did not report RTC configuration ready") }
	}
	if err != nil {
		restoreErr := writeFileAtomic(m.envPath, original, 0o600)
		if restoreErr != nil { return fmt.Errorf("calling setup failed; restoring configuration failed: %w", restoreErr) }
		_, restartErr := m.reconcileNode()
		if restartErr != nil { return fmt.Errorf("configuration restored; Node restart needs attention: %w", restartErr) }
		return fmt.Errorf("calling setup failed and was rolled back: %w", err)
	}
	fmt.Println("Calling configured. Test both audio and video from two phones on different networks; RTC configuration readiness is not a TURN connectivity test.")
	return nil
}

func (m model) callsView() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render("Voice & video calls") + "\n\n")
	d := m.snapshot.Diagnostics
	if d == nil || d.Calls == nil { return b.String() + "No call diagnostics. Refresh or update the Node. Group setup is available below." }
	c := d.Calls
	b.WriteString(fact("Calling", status(c.Enabled, "Enabled", "Disabled")))
	b.WriteString(fact("Voice policy", status(c.VoiceEnabled, "Allowed", "Disabled")))
	b.WriteString(fact("Video policy", status(c.VideoEnabled, "Allowed", "Disabled")))
	b.WriteString(fact("Direct-call RTC", status(c.RTCReady, "Ready", "Needs TURN setup")))
	b.WriteString(fact("Group calling", status(c.GroupCallsEnabled, "Enabled", "Not configured / disabled")))
    if c.GroupCallsEnabled { b.WriteString(fact("Group participant limit", strconv.Itoa(c.GroupCallMaximum))) }
	b.WriteString(fact("TURN credentials", status(c.TURNConfigured, "Configured", "Missing")))
	b.WriteString(fact("Connected devices", strconv.Itoa(c.RealtimeDevices)))
	b.WriteString(fact("Pending calls", strconv.Itoa(c.PendingCalls)))
	b.WriteString(fact("Federation failures", strconv.FormatInt(c.FederationFailures, 10)))
	b.WriteString(fact("Background push", status(c.BackgroundPushReady, "Ready", "Not configured")))
	b.WriteString("\nGroup calls use the private media service; direct calls require TURN.\nConfiguration readiness is not a connectivity test. Check the required firewall/relay ports.\nWebRTC media is not queued through Nearby/DTN.\n")
	return b.String()
}
