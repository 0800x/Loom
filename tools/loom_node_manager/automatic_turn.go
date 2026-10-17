package main

import (
	tea "charm.land/bubbletea/v2"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

func (m manager) automaticTURNCommand() (*exec.Cmd, error) {
	if runtime.GOOS != "linux" || filepath.Clean(m.home) != "/opt/loom-node" {
		return nil, fmt.Errorf("Automatic local TURN requires the installed Linux Home Node")
	}
	if err := requirePrivateRootFile(filepath.Join(m.home, ".loom-install-owner")); err != nil {
		return nil, err
	}
	info, err := os.Lstat("/usr/local/bin/loom")
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 {
		return nil, fmt.Errorf("Installed Loom launcher is unavailable or unsafe")
	}
	cmd := exec.Command("/usr/local/bin/loom", "setup", "--calls-only", "--turn", "auto", "--yes", "--no-manager")
	cmd.Env = cleanUpdateEnvironment(false)
	return cmd, nil
}
func automaticTURNCmd(m manager) tea.Cmd {
	cmd, err := m.automaticTURNCommand()
	if err != nil {
		return func() tea.Msg { return terminalFinishedMsg{"Automatic TURN setup", err} }
	}
	return tea.ExecProcess(cmd, func(err error) tea.Msg { return terminalFinishedMsg{"Automatic TURN setup", err} })
}
