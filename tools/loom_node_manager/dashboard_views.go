package main

import (
	"fmt"
	"math"
	"regexp"
	"time"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

func percent(used, total uint64) float64 {
	if total == 0 {
		return 0
	}
	value := float64(used) * 100 / float64(total)
	if value < 0 { return 0 }
	if value > 100 { return 100 }
	return value
}

func meter(value float64, width int) string {
	if width < 8 { width = 8 }
	if value < 0 { value = 0 }
	if value > 100 { value = 100 }
	filled := int(math.Round(value / 100 * float64(width)))
	if filled > width { filled = width }
	active := strings.Repeat("█", filled)
	inactive := strings.Repeat("░", width-filled)
	style := goodStyle
	if value >= 90 { style = badStyle } else if value >= 75 { style = warnStyle }
	return style.Render(active) + dimStyle.Render(inactive)
}

func resourceGauge(label string, value float64, detail string, width int) string {
	return fmt.Sprintf("%-10s [%s] %5.1f%%  %s\n", dimStyle.Render(label), meter(value, width), value, detail)
}

func updateVersionLabel(versionValue, commit string) string {
	versionValue = strings.TrimSpace(versionValue)
	commit = strings.TrimSpace(commit)
	if versionValue != "" && commit != "" {
		return versionValue + "  •  " + shortCommit(commit)
	}
	if versionValue != "" { return versionValue }
	if commit != "" { return shortCommit(commit) }
	return "—"
}

func updateStateLabel(state string) string {
	switch state {
	case "up_to_date":
		return goodStyle.Render("● Latest version installed")
	case "update_available":
		return warnStyle.Render("● New update available / repair needed")
	case "checking":
		return dimStyle.Render("Checking latest commit…")
	case "updating":
		return warnStyle.Render("Installing selected update")
	case "unavailable":
		return badStyle.Render("Update check unavailable")
	default:
		return firstNonEmpty(state, "unknown")
	}
}

func commitMatchLabel(installed, available string) string {
	installed = strings.TrimSpace(installed)
	available = strings.TrimSpace(available)
	if installed == "" || available == "" {
		return dimStyle.Render("unknown")
	}
	if strings.EqualFold(installed, available) {
		return goodStyle.Render("● exact match")
	}
	return warnStyle.Render("● newer commit available")
}

func (m dashboardModel) visualOverviewView() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render("Overview"))
	if m.inner.snapshot.Diagnostics == nil {
		b.WriteString("\n\n" + status(m.inner.snapshot.DockerReady, "DOCKER READY", "DOCKER UNAVAILABLE") + "  " + status(m.inner.snapshot.ComposeReady, "COMPOSE READY", "COMPOSE MISSING"))
		if m.inner.snapshot.DiagnosticError != "" {
			b.WriteString("\n\n" + badStyle.Render("Node diagnostics unavailable") + "\n" + dimStyle.Render(m.inner.snapshot.DiagnosticError))
		}
		return b.String()
	}

	d := m.inner.snapshot.Diagnostics
	b.WriteString(section("NODE"))
	b.WriteString(fact("Name", d.Node.Name))
	b.WriteString(fact("Domain", d.Node.Domain))
	b.WriteString(fact("Node ID", truncated(d.Node.NodeID, 54)))
	b.WriteString(fact("Version", d.Node.ServerVersion))
	b.WriteString(fact("Uptime", formatUptime(d.Runtime.UptimeSeconds)))
	b.WriteString(fact("Federation mode", currentFederation(m.inner)))

	b.WriteString(section("SYSTEM"))
	barWidth := 24
	if m.inner.width >= 150 { barWidth = 32 }
	cpuDetail := fmt.Sprintf("%d logical CPUs", m.inner.system.CPUs)
	if m.inner.system.LoadAverage != "" { cpuDetail += "  •  load " + m.inner.system.LoadAverage }
	b.WriteString(resourceGauge("CPU", m.inner.system.CPUUsage, cpuDetail, barWidth))
	b.WriteString(resourceGauge("Memory", percent(m.inner.system.MemoryUsed, m.inner.system.MemoryTotal), formatBytes(m.inner.system.MemoryUsed)+" / "+formatBytes(m.inner.system.MemoryTotal), barWidth))
	b.WriteString(resourceGauge("Disk /", percent(m.inner.system.DiskUsed, m.inner.system.DiskTotal), formatBytes(m.inner.system.DiskUsed)+" / "+formatBytes(m.inner.system.DiskTotal), barWidth))
	b.WriteString(dimStyle.Render("Live system gauges refresh every 2 seconds."))

	b.WriteString(section("SERVICES"))
	b.WriteString(fact("Node readiness", status(d.Ready, "HEALTHY", "DEGRADED")))
	b.WriteString(fact("PostgreSQL", status(d.Storage.Database.Ready, "HEALTHY", "DOWN")))
	b.WriteString(fact("Object storage", status(d.Storage.Attachments.Ready, "HEALTHY", "DOWN")))
	b.WriteString(fact("Public HTTPS", status(m.inner.snapshot.TLS.Ready, "VALID", "UNVERIFIED")))

	b.WriteString(section("USERS / MESSAGING"))
	b.WriteString(fact("Registered accounts", metric(d.Storage.Database.Stats, "accounts")))
	b.WriteString(fact("Devices", metric(d.Storage.Database.Stats, "devices")))
	b.WriteString(fact("Pending registrations", fmt.Sprintf("%d", d.Registration.PendingRequests)))
	b.WriteString(fact("Conversations", metric(d.Storage.Database.Stats, "conversations")))
	b.WriteString(fact("Messages", metric(d.Storage.Database.Stats, "messages")))
	b.WriteString(fact("Awaiting local routing", metric(d.Storage.Database.Stats, "pendingMessageRoutes")))
	if d.Messaging != nil {
		b.WriteString(fact("Live message streams", fmt.Sprintf("%d connected", d.Messaging.AccountStreams)))
		b.WriteString(fact("Stream sync errors", fmt.Sprintf("%d since restart", d.Messaging.SyncFailures)))
	} else {
		b.WriteString(fact("Live message streams", "Unknown — update the running Node"))
	}
	if d.Calls != nil {
		callState := "Disabled in Node configuration"
		if d.Calls.Enabled { callState = "Direct calls need TURN"; if d.Calls.GroupCallsEnabled { callState = "Group calls enabled; direct calls need TURN" }; if d.Calls.RTCReady { callState = "Direct calls ready";if d.Calls.GroupCallsEnabled{callState="Direct and group calls enabled"} } }
		b.WriteString(fact("Calls", callState))
	}

	b.WriteString(section("FEDERATION"))
	b.WriteString(fact("Discovered / healthy", fmt.Sprintf("%d / %d", m.inner.federation.DiscoveredNodes, m.inner.federation.HealthyNodes)))
	b.WriteString(fact("Active deliveries", fmt.Sprintf("%d / 4 workers", m.inner.federation.InFlightDeliveries)))
	if m.inner.federation.LastWorkerError != "" { b.WriteString(fact("Worker error", m.inner.federation.LastWorkerError)) }
	b.WriteString(fact("Pending / failed", fmt.Sprintf("%d / %d", m.inner.federation.PendingOutboundDeliveries, m.inner.federation.FailedDeliveries)))

	b.WriteString(section("NETWORK"))
	b.WriteString(fact("Public URL", d.Network.PublicBaseURL))
	b.WriteString(fact("TLS expiry", func() string { if m.inner.snapshot.TLS.ExpiresAt.IsZero() { return "—" }; return m.inner.snapshot.TLS.ExpiresAt.Format("2006-01-02") }()))
	b.WriteString(fact("DNS", func() string { if len(m.inner.snapshot.TLS.DNS) == 0 { return "—" }; return strings.Join(m.inner.snapshot.TLS.DNS, ", ") }()))
	return b.String()
}

func (m dashboardModel) visualUpdatesView() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render("Updates") + "\n\n")
	b.WriteString(fact("State", updateStateLabel(m.inner.update.State)))
	b.WriteString(fact("Manager", version))
	b.WriteString(fact("Manager build", shortCommit(knownBuildCommit())))
	b.WriteString(fact("Installed record", shortCommit(m.inner.update.InstalledCommit)))
	if d := m.inner.snapshot.Diagnostics; d != nil {
		b.WriteString(fact("Running Node", shortCommit(d.Runtime.BuildCommit)))
		if validCommit(d.Runtime.BuildCommit) && validCommit(m.inner.update.InstalledCommit) && !strings.EqualFold(d.Runtime.BuildCommit, m.inner.update.InstalledCommit) {
			b.WriteString(warnStyle.Render("Manager and Node revisions differ") + "\n")
		}
	}
	if m.inner.update.AvailableCommit != "" {
		b.WriteString(fact("Latest commit", shortCommit(m.inner.update.AvailableCommit)))
		b.WriteString(fact("Commit match", commitMatchLabel(m.inner.update.InstalledCommit, m.inner.update.AvailableCommit)))
	}
	if m.inner.update.AvailableVersion != "" {
		b.WriteString(fact("Latest manager", m.inner.update.AvailableVersion))
	}
	b.WriteString(fact("Repository", m.inner.update.Repository))
	b.WriteString(fact("Branch", m.inner.update.Branch))
	b.WriteString(fact("Installation path", m.inner.mgr.home))
	b.WriteString(fact("Source checkout", firstNonEmpty(m.inner.update.SourceDir, "Remote checkout on install")))
	b.WriteString(fact("Installation", "Install update (explicit action)"))

	if m.updateBusy && (m.inner.update.State == "checking" || m.inner.update.State == "updating") {
		progress := m.updateProgress
		if progress < 0 { progress = 0 }
		if progress > 100 { progress = 100 }
		b.WriteString(section("UPDATE PROGRESS"))
		b.WriteString(resourceGauge("Progress", float64(progress), firstNonEmpty(m.updateStage, "Working"), 30))
		b.WriteString(dimStyle.Render("Progress follows real updater milestones and installer steps; Docker rebuilds can still take the longest."))
	}
	if m.inner.update.Detail != "" { b.WriteString("\n\n" + dimStyle.Render(m.inner.update.Detail)) }
	b.WriteString("\n\n" + dimStyle.Render("Update status refreshes automatically every 60 seconds by comparing full commit SHAs. Nothing is installed until you explicitly choose Install update."))
	return b.String()
}

func clipLines(content string, height, scroll int) (string, bool, bool) {
	if height < 1 { height = 1 }
	lines := strings.Split(content, "\n")
	if len(lines) <= height { return content, false, false }
	maxScroll := len(lines) - height
	if scroll < 0 { scroll = 0 }
	if scroll > maxScroll { scroll = maxScroll }
	end := scroll + height
	if end > len(lines) { end = len(lines) }
	return strings.Join(lines[scroll:end], "\n"), scroll > 0, end < len(lines)
}

func (m dashboardModel) dashboardPageView() string {
	switch pages[m.inner.page] {
	case "Overview": return m.visualOverviewView()
	case "Updates": return m.visualUpdatesView()
	default: return m.inner.pageView()
	}
}

// Wrap before measuring, so a long path or error cannot grow the viewport after
// clipping. The same dimensions drive rendering, End, and keyboard scrolling.
func (m dashboardModel) dimensions() (width, height, sidebar, panelWidth, rows int) {
	width, height = m.inner.width, m.inner.height
	if width <= 0 { width = 100 }
	if height <= 0 { height = 30 }
	if width >= 96 && height >= 18 { sidebar = 27 }
	panelWidth = width
	if sidebar > 0 { panelWidth -= sidebar + 1 }
	rows = max(1, height-8)
	return
}

func (m dashboardModel) pageContent() string {
 if m.inner.groupCallsForm!=nil{content:=m.inner.groupCallsForm.view();if m.inner.busy{content+="\n\nSetting up media service… Please wait."};return content}
	if m.inner.confirm != nil {
		return warnStyle.Render("[y] confirm   [n/Esc] cancel") + "\n\n" + titleStyle.Render(m.inner.confirm.label) + "\n\n" + m.inner.confirm.hint
	}
	if m.inner.help { return m.inner.helpView() }
	content := m.dashboardPageView() + m.inner.actionsView()
	if strings.TrimSpace(m.inner.message) != "" && m.inner.update.State != "updating" {
		content += "\n" + section("LAST OPERATION") + m.inner.message
	}
	return content
}

func (m dashboardModel) wrappedContent() string {
	_, _, _, panelWidth, _ := m.dimensions()
	return lipgloss.NewStyle().Width(max(1, panelWidth-4)).Render(m.pageContent())
}

func (m dashboardModel) maxScroll() int {
	_, _, _, _, rows := m.dimensions()
	return max(0, lipgloss.Height(m.wrappedContent())-rows)
}

func (m *dashboardModel) clampScroll() { m.scroll = max(0, min(m.scroll, m.maxScroll())) }

var terminalColorPattern = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]`)

func (m *dashboardModel) revealSelection() {
	if m.inner.focus == focusSidebar || m.inner.confirm != nil || m.inner.help { m.scroll = 0; return }
	_, _, _, panelWidth, rows := m.dimensions()
	wrap := func(s string) string { return lipgloss.NewStyle().Width(max(1, panelWidth-4)).Render(s) }
	page := m.dashboardPageView()
	target := 0
	content := wrap(page)
	if m.inner.focus == focusActions {
		target = lipgloss.Height(wrap(page)) - 1
		content = wrap(m.inner.actionsView())
	}
	for index, line := range strings.Split(content, "\n") {
		if strings.HasPrefix(strings.TrimSpace(terminalColorPattern.ReplaceAllString(line, "")), "> ") {
			target += index
			if target < m.scroll { m.scroll = target }
			if target >= m.scroll+rows { m.scroll = target-rows+1 }
			return
		}
	}
}

func (m dashboardModel) compactNav(width, rows int) string {
	count := max(1, rows-1)
	start := max(0, min(m.inner.page-count/2, len(pages)-count))
	var lines []string
	lines = append(lines, dimStyle.Render("SECTIONS"))
	for i := start; i < min(len(pages), start+count); i++ {
		label := "  " + pages[i]
		if i == m.inner.page { label = selStyle.Render("> " + pages[i]) }
		lines = append(lines, label)
	}
	return navStyle.Margin(0).Padding(0, 1).Width(width).Height(rows+2).MaxWidth(width).MaxHeight(rows+2).Render(strings.Join(lines, "\n"))
}

func (m dashboardModel) dashboardView() tea.View {
	width, height, sidebar, panelWidth, rows := m.dimensions()
	if width < 30 || height < 9 {
		text := "Loom Node Manager\nResize terminal (30 × 9 minimum)"
		if m.inner.confirm != nil { text = "Confirm: " + m.inner.confirm.label + "\n[y] yes  [n/Esc] cancel" }
		v := tea.NewView(lipgloss.NewStyle().MaxWidth(width).MaxHeight(height).Render(text)); v.AltScreen = true; return v
	}
	clipped, above, below := clipLines(m.wrappedContent(), rows, m.scroll)
	body := contentStyle.Margin(0).Padding(0, 1).Width(panelWidth).Height(rows+2).MaxWidth(panelWidth).MaxHeight(rows+2).Render(clipped)
	if sidebar > 0 { body = lipgloss.JoinHorizontal(lipgloss.Top, m.compactNav(sidebar, rows), " ", body) }
	focus := map[int]string{focusSidebar:"sections", focusTable:"list", focusActions:"actions"}[m.inner.focus]
	header := titleStyle.Render("Loom Node Manager") + dimStyle.Render("  v"+version+"  /  "+pages[m.inner.page])
	subtitle := dimStyle.Render(m.inner.mgr.home + "  •  focus: " + focus)
	position := "Ctrl+←/→ sections  •  Tab focus"
	if above || below { position = fmt.Sprintf("Lines %d–%d / %d  •  PgUp/PgDn scroll", min(m.scroll,m.maxScroll())+1, min(m.scroll,m.maxScroll())+rows, lipgloss.Height(m.wrappedContent())) }
	freshness := "Waiting for Node diagnostics"
	if !m.lastRefreshed.IsZero() { freshness = fmt.Sprintf("Status %ds ago", max(0,int(time.Since(m.lastRefreshed).Seconds()))) }
	if m.refreshBusy { freshness += "  •  refreshing" }
	if m.inner.snapshot.DiagnosticError != "" { freshness += "  •  Node probe failed (details in Overview)" }
	if m.inner.update.State == "updating" { freshness = fmt.Sprintf("Installing %d%%  •  %s", m.updateProgress, m.updateStage) } else if m.inner.busy { freshness = "Working…" }
	if m.inner.confirm != nil { freshness = "[y] confirm  •  [n/Esc] cancel" }
	footer := "↑/↓ move  Enter select  r refresh  ? help  q quit"
	line := func(s string) string { return lipgloss.NewStyle().MaxWidth(width).MaxHeight(1).Render(s) }
	content := strings.Join([]string{line(header), line(subtitle), body, line(dimStyle.Render(position)), line(dimStyle.Render(freshness)), line(dimStyle.Render(footer))}, "\n")
	v := tea.NewView(lipgloss.NewStyle().MaxWidth(width).MaxHeight(height).Render(content))
	v.AltScreen = true
	return v
}
