package main

import (
	"sync"
	"time"

	tea "charm.land/bubbletea/v2"
)

type requestStatusRefreshMsg struct{}
type dashboardStatusTickMsg struct{}
type dashboardTLSTickMsg struct{}
type dashboardTLSMsg tlsSnapshot
type dashboardStatusMsg struct {
	snapshot snapshot
	federation federationStatusMsg
	queue federationQueueMsg
	users *usersMsg
 groups *groupsMsg
}

func dashboardStatusTickCmd() tea.Cmd {
	return tea.Tick(5*time.Second, func(time.Time) tea.Msg { return dashboardStatusTickMsg{} })
}
func dashboardTLSTickCmd() tea.Cmd {
	return tea.Tick(30*time.Second, func(time.Time) tea.Msg { return dashboardTLSTickMsg{} })
}
func dashboardTLSCmd(mgr manager) tea.Cmd {
	return func() tea.Msg { return dashboardTLSMsg(mgr.inspectTLS()) }
}
func requestStatusRefreshCmd() tea.Cmd {
	return func() tea.Msg { return requestStatusRefreshMsg{} }
}

func dashboardStatusCmd(mgr manager, includeUsers bool, groupAfter ...string) tea.Cmd {
	return func() tea.Msg {
		var result dashboardStatusMsg
		var pending sync.WaitGroup
		pending.Add(4)
  after:="";if len(groupAfter)>0 { after=groupAfter[0] }
  go func() { defer pending.Done(); v,err:=mgr.readGroups(after);result.groups=&groupsMsg{v,after,err} }()
		go func() { defer pending.Done(); result.snapshot = mgr.inspectLocal() }()
		go func() { defer pending.Done(); v, err := mgr.readFederationStatus(); result.federation = federationStatusMsg{v, err} }()
		go func() { defer pending.Done(); v, err := mgr.readFederationQueue(); result.queue = federationQueueMsg{v, err} }()
		if includeUsers {
			pending.Add(1)
			go func() { defer pending.Done(); v, err := mgr.readAdminUsers(); result.users = &usersMsg{v, err} }()
		}
		pending.Wait()
		return result
	}
}

func (m model) selectedRowID() string {
	switch pages[m.page] {
	case "Groups": if v := m.selectedGroup(); v != nil { return v.ID }
 case "Users": if v := m.selectedUser(); v != nil { return v.AccountID }
	case "Federation": if v := m.selectedNode(); v != nil { return v.NodeID }
	case "Federation Queue": if v := m.selectedDelivery(); v != nil { return v.DeliveryID }
	case "Registration": if v := m.selectedRegistration(); v != nil { return v.RequestID }
	}
	return ""
}

func (m *model) restoreSelectedRow(id string) {
	if id == "" { return }
	previous := m.row
	for i := 0; i < m.rowCount(); i++ {
		m.row = i
		if m.selectedRowID() == id { return }
	}
	m.row = min(previous, max(0, m.rowCount()-1))
}
