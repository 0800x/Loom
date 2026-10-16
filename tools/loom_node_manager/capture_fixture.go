package main

import (
	"encoding/json"
	"strings"

	tea "charm.land/bubbletea/v2"
)

// A separate Tea model, not a production manager with fake command results.
// It only forwards resize and navigation; no dashboard command can execute.
type captureFixture struct{ dashboard dashboardModel }

func newCaptureFixture() captureFixture {
	d := new(nodeDiagnostics)
	if err := json.Unmarshal([]byte(`{"schemaVersion":1,"ready":true,"overallStatus":"ready","node":{"name":"Loom Example Node","domain":"node.example.org","endpoint":"https://node.example.org","nodeId":"fictional-node","serverVersion":"0.10.9","registration":"open","federationMode":"verified"},"runtime":{"uptimeSeconds":86400,"mode":"fixture"},"storage":{"database":{"ready":true,"backend":"PostgreSQL","latencyMs":3},"attachments":{"ready":true,"backend":"S3-compatible","latencyMs":8}},"network":{"publicDomain":"node.example.org","publicBaseUrl":"https://node.example.org","tlsExpected":true,"lanDiscovery":true},"registration":{"policy":"open","acceptingRegistrations":true},"calls":{"enabled":true,"voiceEnabled":true,"videoEnabled":true,"rtcReady":true,"turnConfigured":true,"groupCallsEnabled":true,"groupCallMaximum":8},"security":{"nodeIdentityReady":true,"adminTokenConfigured":true}}`), d); err != nil {
		panic(err) // Static fixture, contains no credentials or identity material.
	}
	m := model{width: 120, height: 40, focus: focusSidebar,
		message: "READ-ONLY CAPTURE FIXTURE • fictional status • actions disabled",
		snapshot: snapshot{Diagnostics: d, DockerInstalled: true, DockerReady: true, ComposeReady: true, ConfigPresent: true,
			Services: "NAME                 STATUS\nloom-node            Up (healthy)\npostgres             Up (healthy)\nattachment-store     Up (healthy)\nturn                 Up\ngroup-media          Up"},
		update: updateStatus{State: "unavailable", InstalledVersion: version, Repository: "0800x/Loom", Branch: "main", Detail: "Read-only fixture: no remote update check performed"},
	}
	return captureFixture{dashboard: dashboardModel{inner: m}}
}

func (m captureFixture) Init() tea.Cmd { return nil }
func (m captureFixture) View() tea.View {
	dashboard := m.dashboard
	dashboard.inner.height = max(1, dashboard.inner.height-1)
	view := dashboard.View()
	view.Content = "READ-ONLY FIXTURE • fictional status • production actions disabled\n" + view.Content
	return view
}
func (m captureFixture) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch v := msg.(type) {
	case tea.WindowSizeMsg:
		m.dashboard.inner.width, m.dashboard.inner.height = v.Width, v.Height
	case tea.KeyPressMsg:
		switch v.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "down", "j":
			m.dashboard.inner.page = (m.dashboard.inner.page + 1) % len(pages)
			m.dashboard.scroll = 0
		case "up", "k":
			m.dashboard.inner.page = (m.dashboard.inner.page + len(pages) - 1) % len(pages)
			m.dashboard.scroll = 0
		case "]", "pgdown":
			m.dashboard.scroll += 8
		case "[", "pgup":
			m.dashboard.scroll -= 8
		case "home":
			m.dashboard.scroll = 0
		case "end":
			m.dashboard.scroll = m.dashboard.maxScroll()
		default:
			// Includes Enter, confirmations, refresh and update hotkeys.
			if strings.TrimSpace(v.String()) != "" {
				m.dashboard.inner.message = "READ-ONLY CAPTURE FIXTURE • actions disabled"
			}
		}
	}
	m.dashboard.clampScroll()
	return m, nil
}
