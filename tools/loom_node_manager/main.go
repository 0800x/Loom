package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	tea "charm.land/bubbletea/v2"
)

const version = "0.8.4"

// Set by the production installer. A checkout's HEAD is not proof that the
// running binary or container was built from that revision.
var buildCommit string
var buildBranch string
var buildRepository string

func main() {
	home := flag.String("home", defaultHome(), "Loom Node installation directory")
	showVersion := flag.Bool("version", false, "Print Manager build identity and exit")
	fixture := flag.Bool("capture-fixture", false, "Read-only fictional dashboard; no network, services or installation access")
	configureCalls := flag.Bool("configure-calls", false, "Configure TURN and enable voice/video calling")
	flag.Parse()
	if *fixture {
		if *configureCalls {
			fmt.Fprintln(os.Stderr, "Capture fixture cannot configure services")
			os.Exit(2)
		}
		if _, err := tea.NewProgram(newCaptureFixture()).Run(); err != nil {
			fmt.Fprintln(os.Stderr, "Capture fixture:", err)
			os.Exit(1)
		}
		return
	}
	if *showVersion {
		fmt.Printf("Loom Node Manager %s %s (%s)\n", version, shortCommit(knownBuildCommit()), firstNonEmpty(buildBranch, "unknown branch"))
		return
	}
	if err := validatePrivilegedHome(*home); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	mgr := newManager(*home)
	if *configureCalls {
		if err := mgr.configureCalls(); err != nil {
			fmt.Fprintln(os.Stderr, "Calling setup:", err)
			os.Exit(1)
		}
		return
	}
	if err := configureGitHubUpdateAuth(mgr); err != nil {
		fmt.Fprintln(os.Stderr, "loom-node-manager update auth:", err)
	}
	finalModel, err := tea.NewProgram(initialDashboardModel(mgr)).Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "loom-node-manager:", err)
		os.Exit(1)
	}

	restart := false
	switch model := finalModel.(type) {
	case dashboardModel:
		restart = model.restartRequested
	case *dashboardModel:
		restart = model.restartRequested
	}
	if !restart {
		return
	}

	cmd := exec.Command(filepath.Join(mgr.home, "bin", "loom-node-manager"), "--home", mgr.home)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "loom-node-manager restart:", err)
		os.Exit(1)
	}
}
