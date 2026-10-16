package main

import (
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

const updateCheckInterval = time.Minute

type updateCheckMsg struct{ status updateStatus }
type updateApplyMsg struct { status updateStatus; output string; err error }
type updateProgressMsg struct { percent int; stage string }
type updateRestartMsg struct{}
type updateCheckTickMsg struct{}
type systemStatsTickMsg struct{}

type dashboardModel struct {
	inner model
	updateBusy bool
	refreshBusy bool
	tlsBusy bool
	statsBusy bool
	lastRefreshed time.Time
	restartRequested bool
	scroll int
	updateProgress int
	updateStage string
	updateEvents <-chan tea.Msg
}

func initialDashboardModel(mgr manager) dashboardModel { return dashboardModel{inner: initialModel(mgr), updateBusy: true, refreshBusy: true, tlsBusy: true, statsBusy: true, updateStage: "Checking for updates"} }
func checkUpdateCmd(mgr manager) tea.Cmd { return func() tea.Msg { return updateCheckMsg{status: checkNodeUpdate(mgr)} } }
func waitUpdateEventCmd(events <-chan tea.Msg) tea.Cmd { return func() tea.Msg { if events == nil { return nil }; msg, ok := <-events; if !ok { return nil }; return msg } }
func updateLabel(status updateStatus) string { if status.AvailableVersion != "" { return status.AvailableVersion + " • " + shortCommit(status.AvailableCommit) }; return shortCommit(status.AvailableCommit) }
func updateCheckTickCmd() tea.Cmd { return tea.Tick(updateCheckInterval, func(time.Time) tea.Msg { return updateCheckTickMsg{} }) }
func systemStatsTickCmd() tea.Cmd { return tea.Tick(2*time.Second, func(time.Time) tea.Msg { return systemStatsTickMsg{} }) }
func (m dashboardModel) Init() tea.Cmd { return tea.Batch(dashboardStatusCmd(m.inner.mgr, true, m.inner.groupsAfter), dashboardTLSCmd(m.inner.mgr), systemStatsCmd(), checkUpdateCmd(m.inner.mgr), updateCheckTickCmd(), systemStatsTickCmd(), dashboardStatusTickCmd(), dashboardTLSTickCmd()) }

func (m dashboardModel) startUpdate() (dashboardModel, tea.Cmd) {
	m.updateBusy = true
	m.updateProgress = 3
	m.updateStage = "Preparing validated update"
	m.inner.update.State = "updating"
	m.inner.message = "Applying validated Loom Node update…"
	events := make(chan tea.Msg, 24)
	m.updateEvents = events
	mgr := m.inner.mgr
	go func() {
		status, output, err := applyNodeUpdateWithProgress(mgr, func(progress updateProgress) {
			events <- updateProgressMsg{percent: progress.Percent, stage: progress.Stage}
		})
		events <- updateApplyMsg{status: status, output: output, err: err}
		close(events)
	}()
	return m, waitUpdateEventCmd(events)
}

func (m dashboardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case requestStatusRefreshMsg:
		if m.refreshBusy { return m, nil }
		m.refreshBusy = true
		return m, dashboardStatusCmd(m.inner.mgr, true, m.inner.groupsAfter)
	case dashboardStatusTickMsg:
		if m.refreshBusy || m.inner.busy || m.inner.update.State == "updating" {
			return m, dashboardStatusTickCmd()
		}
		m.refreshBusy = true
		return m, tea.Batch(dashboardStatusCmd(m.inner.mgr, pages[m.inner.page] == "Users", m.inner.groupsAfter), dashboardStatusTickCmd())
	case dashboardStatusMsg:
		m.refreshBusy = false
		busy, message, selectedID := m.inner.busy, m.inner.message, m.inner.selectedRowID()
		tls := m.inner.snapshot.TLS
		messages := []tea.Msg{refreshMsg(msg.snapshot), msg.federation, msg.queue}
		if msg.users != nil { messages = append(messages, *msg.users) }
  if msg.groups != nil { messages = append(messages,*msg.groups) }
		for _, value := range messages {
			updated, _ := m.inner.Update(value)
			m.inner = updated.(model)
		}
		m.inner.snapshot.TLS = tls
		m.inner.busy, m.inner.message = busy, message
		m.inner.restoreSelectedRow(selectedID)
		m.inner.actionCursor = min(m.inner.actionCursor, max(0, len(m.inner.actions())-1))
		if msg.snapshot.Diagnostics != nil { m.lastRefreshed = time.Now() }
		m.clampScroll()
		return m, nil
	case dashboardTLSTickMsg:
		if m.tlsBusy || m.inner.update.State == "updating" { return m, dashboardTLSTickCmd() }
		m.tlsBusy = true
		return m, tea.Batch(dashboardTLSCmd(m.inner.mgr), dashboardTLSTickCmd())
	case dashboardTLSMsg:
		m.tlsBusy = false
		m.inner.snapshot.TLS = tlsSnapshot(msg)
		return m, nil
	case systemStatsTickMsg:
		if m.statsBusy { return m, systemStatsTickCmd() }
		m.statsBusy = true
		return m, tea.Batch(systemStatsCmd(), systemStatsTickCmd())
	case systemStatsMsg:
		m.statsBusy = false
	case updateCheckTickMsg:
		if m.updateBusy {
			return m, updateCheckTickCmd()
		}
		m.updateBusy = true
		return m, tea.Batch(checkUpdateCmd(m.inner.mgr), updateCheckTickCmd())
	case requestUpdateCheckMsg:
		if m.updateBusy { m.inner.message = "Update check is already running."; return m, nil }
		m.updateBusy = true
		m.updateProgress = 5
		m.updateStage = "Checking repository"
		m.inner.update.State = "checking"
		m.inner.message = "Checking for updates…"
		return m, checkUpdateCmd(m.inner.mgr)
	case requestUpdateApplyMsg:
		if m.updateBusy || m.inner.busy { m.inner.message = "Wait for the current operation to finish."; return m, nil }
		if m.inner.update.State != "update_available" { m.inner.message = "No update is available."; return m, nil }
		updated, cmd := m.startUpdate()
		return updated, cmd
	case updateProgressMsg:
		m.updateProgress = msg.percent
		m.updateStage = msg.stage
		m.inner.message = msg.stage
		return m, waitUpdateEventCmd(m.updateEvents)
	case updateCheckMsg:
		m.updateBusy = false
		m.updateProgress = 0
		m.updateStage = ""
		m.inner.update = msg.status
		switch msg.status.State {
		case "update_available":
			m.inner.message = "Selected revision: " + updateLabel(msg.status) + ". Open Updates to install it manually or repair a mismatched Node."
		case "up_to_date":
			if pages[m.inner.page] == "Updates" {
				m.inner.message = "Latest version installed."
			}
		default:
			if msg.status.Detail != "" && pages[m.inner.page] == "Updates" { m.inner.message = "Update check unavailable: " + msg.status.Detail }
		}
		// Update checks are automatic; installation is always an explicit operator action.
		return m, nil
	case updateApplyMsg:
		m.updateBusy = false
		m.updateEvents = nil
		m.inner.update = msg.status
		if msg.err != nil {
			m.updateProgress = 0
			m.updateStage = ""
			m.inner.update.State = "unavailable"
			m.inner.message = "Update failed: " + msg.err.Error()
			if strings.TrimSpace(msg.output) != "" { m.inner.message += "\n" + strings.TrimSpace(msg.output) }
			return m, nil
		}
		m.updateProgress = 100
		m.updateStage = "Installed successfully — restarting manager"
		m.inner.message = "Update installed successfully. Restarting Loom Node Manager…"
		return m, tea.Tick(900*time.Millisecond, func(time.Time) tea.Msg { return updateRestartMsg{} })
	case updateRestartMsg:
		m.restartRequested = true
		return m, tea.Quit
	case tea.KeyPressMsg:
		// Dialog keys belong to the dialog, and install-time mutations must not
		// restart containers underneath the updater's readiness verification.
		if m.inner.update.State == "updating" && (msg.String() == "enter" || msg.String() == " " || msg.String() == "y" || msg.String() == "Y") {
			m.inner.message = "Installation is running. Navigation remains available."
			return m, nil
		}
		if m.inner.groupCallsForm != nil {
            switch msg.String() {case "pgup","ctrl+u":m.scroll=max(0,m.scroll-8);return m,nil;case "pgdown","ctrl+d":m.scroll+=8;m.clampScroll();return m,nil}
            break
        }
        if m.inner.confirm != nil || m.inner.help { break }
		m.clampScroll()
		switch msg.String() {
		case "ctrl+left", "ctrl+right":
			step := 1
			if msg.String() == "ctrl+left" { step = -1 }
			m.inner.movePage(step)
			m.scroll = 0
			return m, nil
		case "pgup", "ctrl+u", "shift+up", "[":
			m.scroll -= 8
			if m.scroll < 0 { m.scroll = 0 }
			return m, nil
		case "pgdown", "ctrl+d", "shift+down", "]":
			m.scroll += 8
			m.clampScroll()
			return m, nil
		case "home", "g":
			m.scroll = 0
			return m, nil
		case "end", "G":
			m.scroll = m.maxScroll()
			return m, nil
		}
	}

	hadDialog := m.inner.groupCallsForm != nil || m.inner.confirm != nil || m.inner.help
    previousReview:=m.inner.groupCallsForm!=nil&&m.inner.groupCallsForm.review
	previousPage, previousFocus, previousRow, previousAction := m.inner.page, m.inner.focus, m.inner.row, m.inner.actionCursor
	updated, cmd := m.inner.Update(msg)
	if inner, ok := updated.(model); ok { m.inner = inner }
	if m.inner.page != previousPage || (!hadDialog && (m.inner.groupCallsForm!=nil || m.inner.confirm != nil || m.inner.help)) || (m.inner.groupCallsForm!=nil&&m.inner.groupCallsForm.review!=previousReview) { m.scroll = 0 }
	if m.inner.focus != previousFocus || m.inner.row != previousRow || m.inner.actionCursor != previousAction {
		m.revealSelection()
	}
	m.clampScroll()
	return m, cmd
}

func (m dashboardModel) View() tea.View { return m.dashboardView() }
