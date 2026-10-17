package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	tea "charm.land/bubbletea/v2"
)

const version = "0.8.6"

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
	setupGroups := flag.String("setup-group-calls", "", "Provision group media: on or off (requires root)")
	groupIP := flag.String("group-public-ip", "", "Public server IPv4 for group media")
	groupVideo := flag.String("group-video", "yes", "Allow video in group media: yes or no")
	installedSequence := flag.Uint64("record-installed-source-sequence", 0, "Record verified installation sequence (installer only)")
	flag.Parse()
	if *setupGroups != "" && (*setupGroups != "on" && *setupGroups != "off" || *groupVideo != "yes" && *groupVideo != "no") {
		fmt.Fprintln(os.Stderr, "Invalid group media options")
		os.Exit(2)
	}
	if *fixture {
		if *configureCalls || *setupGroups != "" || *installedSequence != 0 {
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
	if *installedSequence != 0 {
		if os.Geteuid() != 0 {
			fmt.Fprintln(os.Stderr, "Installation records require root")
			os.Exit(1)
		}
		if err := recordPublisherInstall(*home, knownBuildCommit(), *installedSequence); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if *setupGroups != "" {
		if os.Geteuid() != 0 {
			fmt.Fprintln(os.Stderr, "Group media setup requires root")
			os.Exit(1)
		}
		if err := mgr.applyGroupCalls(groupCallsSetup{IP: *groupIP, Limit: 16, Video: *groupVideo == "yes"}, *setupGroups == "on", mgr.mediaCommand); err != nil {
			fmt.Fprintln(os.Stderr, "Group media setup:", err)
			os.Exit(1)
		}
		fmt.Println("Group media configuration applied")
		return
	}
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
