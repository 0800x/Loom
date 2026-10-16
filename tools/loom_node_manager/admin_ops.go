package main

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var runtimeSettings = map[string]map[string]bool{
	"LOOM_PUBLIC_RESOURCE_METRICS": {"true": true, "false": true},
	"LOOM_CALLS_ENABLED": {"true": true, "false": true},
	"LOOM_VOICE_CALLS_ENABLED": {"true": true, "false": true},
	"LOOM_VIDEO_CALLS_ENABLED": {"true": true, "false": true},
	"LOOM_REGISTRATION_POLICY": {"open": true, "approval": true, "closed": true},
	"LOOM_FEDERATION_MODE":     {"disabled": true, "trusted": true, "open": true, "local": true, "hybrid": true},
	"LOOM_LAN_DISCOVERY":       {"true": true, "false": true},
}

func replaceEnvSetting(content, key, value string) string {
	lines := strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n")
	replaced := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, key+"=") {
			lines[i] = key + "=" + value
			replaced = true
		}
	}
	if !replaced {
		for len(lines) > 0 && lines[len(lines)-1] == "" {
			lines = lines[:len(lines)-1]
		}
		lines = append(lines, key+"="+value, "")
	}
	result := strings.Join(lines, "\n")
	if !strings.HasSuffix(result, "\n") {
		result += "\n"
	}
	return result
}

func writeFileAtomic(path string, body []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".loom-env-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(mode.Perm()); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(body); err != nil {
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
	return os.Rename(tmpPath, path)
}

func (m manager) reconcileNode() (string, error) {
	output, err := commandOutput("docker", m.composeArgs("up", "-d", "--no-deps", "--force-recreate", "loom-node")...)
	if err != nil {
		return output, err
	}
	deadline := time.Now().Add(35 * time.Second)
	for time.Now().Before(deadline) {
		if diagnostics, probeErr := m.readDiagnostics(); probeErr == nil && diagnostics != nil && diagnostics.Ready {
			return output, nil
		}
		time.Sleep(time.Second)
	}
	return output, fmt.Errorf("node was recreated but did not become ready within 35 seconds")
}

func (m manager) setRuntimeSetting(key, value string) (string, error) {
	if err := validateRuntimeSetting(key, value); err != nil {
		return "", err
	}
	if strings.ContainsAny(value, "\r\n") {
		return "", fmt.Errorf("invalid runtime setting value")
	}
	original, err := os.ReadFile(m.envPath)
	if err != nil {
		return "", fmt.Errorf("read production environment: %w", err)
	}
	info, err := os.Stat(m.envPath)
	if err != nil {
		return "", fmt.Errorf("stat production environment: %w", err)
	}
	if key == "LOOM_CALLS_ENABLED" && value == "true" && loadEnv(m.envPath)["LOOM_GROUP_CALLS_ENABLED"] != "true" {
		if err := validateCalling(loadEnv(m.envPath)); err != nil { return "", fmt.Errorf("configure TURN first: %w", err) }
	}
	current := loadEnv(m.envPath)[key]
	if current == value {
		return fmt.Sprintf("%s is already %s", key, value), nil
	}
	next := []byte(replaceEnvSetting(string(original), key, value))
	if err := writeFileAtomic(m.envPath, next, info.Mode()); err != nil {
		return "", fmt.Errorf("persist runtime setting: %w", err)
	}
	output, applyErr := m.reconcileNode()
	if applyErr == nil {
		return fmt.Sprintf("%s=%s\n%s", key, value, output), nil
	}

	rollbackErr := writeFileAtomic(m.envPath, original, info.Mode())
	rollbackOutput, restartErr := m.reconcileNode()
	if rollbackErr != nil || restartErr != nil {
		return output + "\nrollback: " + rollbackOutput, fmt.Errorf("apply failed: %v; rollback file error: %v; rollback restart error: %v", applyErr, rollbackErr, restartErr)
	}
	return output + "\nrollback completed", fmt.Errorf("apply failed and was rolled back: %w", applyErr)
}

func randomAdminToken() (string, error) {
	buffer := make([]byte, 32)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buffer), nil
}

func (m manager) rotateAdminToken() (string, error) {
	token, err := randomAdminToken()
	if err != nil {
		return "", err
	}
	original, err := os.ReadFile(m.envPath)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(m.envPath)
	if err != nil {
		return "", err
	}
	next := []byte(replaceEnvSetting(string(original), "LOOM_ADMIN_TOKEN", token))
	if err := writeFileAtomic(m.envPath, next, info.Mode()); err != nil {
		return "", err
	}
	output, applyErr := m.reconcileNode()
	if applyErr == nil {
		return "Admin token rotated. The token remains secret in the production .env.\n" + output, nil
	}
	_ = writeFileAtomic(m.envPath, original, info.Mode())
	_, _ = m.reconcileNode()
	return output, fmt.Errorf("token rotation failed and the previous token was restored: %w", applyErr)
}

func (m manager) cleanupExpiredSessions() (string, error) {
	query := `WITH removed AS (DELETE FROM sessions WHERE refresh_expires_at <= now() RETURNING 1) SELECT count(*) FROM removed;`
	output, err := commandOutput("docker", m.composeArgs("exec", "-T", "postgres", "psql", "-U", "loom", "-d", "loom", "-At", "-c", query)...)
	if err != nil {
		return output, err
	}
	return "Expired sessions removed: " + strings.TrimSpace(output), nil
}

func (m manager) postgresShellCommand() *exec.Cmd {
	return exec.Command("docker", m.composeArgs("exec", "postgres", "psql", "-U", "loom", "-d", "loom")...)
}

func validateRuntimeSetting(key, value string) error {
	if key == "LOOM_MAX_ATTACHMENT_BYTES" {
		n, err := strconv.ParseInt(value, 10, 64)
		if err != nil || n < 29 || n > 2*1024*1024*1024 || strconv.FormatInt(n, 10) != value {
			return fmt.Errorf("upload limit must be 29–2147483648 bytes")
		}
		return nil
	}
	if !runtimeSettings[key][value] { return fmt.Errorf("unsupported runtime setting") }
	return nil
}
