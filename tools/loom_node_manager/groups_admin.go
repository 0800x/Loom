package main

import (
	tea "charm.land/bubbletea/v2"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"unicode"
)

type adminGroup struct {
	ID             string `json:"id"`
	Title          string `json:"title"`
	Epoch          int64  `json:"epoch"`
	Revision       int64  `json:"revision"`
	Sequence       int64  `json:"sequence"`
	DeviceCount    int    `json:"deviceCount"`
	AccountCount   int    `json:"accountCount"`
	InboxRecords   int64  `json:"inboxRecords"`
	Paused         bool   `json:"paused"`
	PolicyRevision int64  `json:"policyRevision"`
}
type groupStatus struct {
	Protocol  string       `json:"protocol"`
	Groups    []adminGroup `json:"groups"`
	NextAfter string       `json:"nextAfter"`
}
type groupMember struct {
	AccountID string `json:"accountId"`
	DeviceID  string `json:"deviceId"`
	Role      string `json:"role"`
	Active    bool   `json:"active"`
}
type groupDetail struct {
	adminGroup
	Members []groupMember `json:"members"`
}
type groupsMsg struct {
	status groupStatus
	after  string
	err    error
}
type groupDetailMsg struct {
	id     string
	detail groupDetail
	err    error
}
type groupDiagnostics struct {
	InfrastructureReady  bool  `json:"infrastructureReady"`
	MessagingReady       bool  `json:"messagingReady"`
	GroupCount           int64 `json:"groupCount"`
	AvailableKeyPackages int64 `json:"availableKeyPackages"`
	InboxRecords         int64 `json:"inboxRecords"`
}

func (m manager) readGroups(after string) (groupStatus, error) {
	var result groupStatus
	out, err := m.internalAdminRequest("GET", "/admin/v1/groups?limit=50&after="+url.QueryEscape(after), nil)
	if err != nil {
		return result, fmt.Errorf("MLS admin API unavailable: %w", err)
	}
	if err = json.Unmarshal([]byte(out), &result); err != nil {
		return result, fmt.Errorf("invalid MLS admin response: %w", err)
	}
	if result.Protocol != "Loom-MLS-v1" {
		return result, fmt.Errorf("unsupported MLS admin protocol")
	}
	return result, nil
}
func groupsCmd(mgr manager, after string) tea.Cmd {
	return func() tea.Msg { v, err := mgr.readGroups(after); return groupsMsg{v, after, err} }
}
func groupDetailCmd(mgr manager, id string) tea.Cmd {
	return func() tea.Msg {
		var detail groupDetail
		out, err := mgr.internalAdminRequest("GET", "/admin/v1/groups/"+url.PathEscape(id), nil)
		if err == nil {
			err = json.Unmarshal([]byte(out), &detail)
		}
		return groupDetailMsg{id, detail, err}
	}
}
func groupPolicyCmd(mgr manager, a action) tea.Cmd {
	return func() tea.Msg {
		revision, err := strconv.ParseInt(a.args[2], 10, 64)
		if err != nil {
			return actionMsg{a.label, "", err}
		}
		out, err := mgr.internalAdminRequest("POST", "/admin/v1/groups/"+url.PathEscape(a.args[0])+"/policy", map[string]any{"paused": a.args[1] == "true", "expectedPolicyRevision": revision})
		if err != nil {
			return actionMsg{a.label, out, err}
		}
		return actionMsg{a.label, "Group policy updated. Membership and MLS keys are unchanged.", nil}
	}
}
func cleanupGroupPackagesCmd(mgr manager) tea.Cmd {
	return func() tea.Msg {
		out, err := mgr.internalAdminRequest("POST", "/admin/v1/groups/key-packages/cleanup", nil)
		return actionMsg{"Clean expired key packages", out, err}
	}
}
func (m model) selectedGroup() *adminGroup {
	if m.row < 0 || m.row >= len(m.groups.Groups) {
		return nil
	}
	return &m.groups.Groups[m.row]
}
func (m model) groupActions() []action {
	actions := []action{{label: "Refresh groups", hint: "reload MLS metadata and key-package stock", kind: "refresh"}}
	available := m.groups.Protocol == "Loom-MLS-v1" && m.groupsError == "" && !m.groupsLoading
	if g := m.selectedGroup(); g != nil && available {
		label, value := "Pause new messages", "true"
		if g.Paused {
			label, value = "Resume new messages", "false"
		}
		actions = append(actions,
			action{label: "Inspect members", hint: "show device roles and revocation status; no keys or messages", kind: "group-detail", args: []string{g.ID}},
			action{label: label, hint: "change delivery policy for " + groupLabel(g.Title, 32) + "; inbox reads and MLS commits remain available", kind: "group-policy", args: []string{g.ID, value, strconv.FormatInt(g.PolicyRevision, 10)}, dangerous: true})
	}
	if available {
		actions = append(actions, action{label: "Clean expired key packages", hint: "remove up to 1000 expired unused packages; preserve live reservations and consumed records", kind: "group-cleanup", dangerous: true})
		if m.groups.NextAfter != "" {
			actions = append(actions, action{label: "Next groups", hint: "load the next 50 groups", kind: "groups-page", args: []string{m.groups.NextAfter}})
		}
		if m.groupsAfter != "" {
			actions = append(actions, action{label: "First groups", hint: "return to the first page", kind: "groups-page", args: []string{""}})
		}
	}
	return actions
}

// Remote titles and account metadata must never become terminal escape sequences.
func groupLabel(value string, limit int) string {
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || (r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) {
			return ' '
		}
		return r
	}, value)
	return truncated(value, limit)
}
func (m model) groupsView() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render("MLS groups") + "\n\nProtocol: Loom-MLS-v1 • native client encryption • home-node groups\n")
	b.WriteString("Node operators manage metadata and delivery policy. Clients create groups and rotate membership keys.\n")
	if m.groupsLoading {
		b.WriteString("\nLoading group page…\n")
		return b.String()
	}
	if m.groupsError != "" {
		b.WriteString("\n" + badStyle.Render(groupLabel(m.groupsError, 140)) + "\nCheck the Node/admin API, update if needed, then refresh. Controls are unavailable.\n")
		return b.String()
	}
	if m.groups.Protocol == "" {
		b.WriteString("\nLoading MLS group administration…\n")
		return b.String()
	}
	if d := m.snapshot.Diagnostics; d != nil && d.Groups != nil {
		b.WriteString(fact("Total groups", strconv.FormatInt(d.Groups.GroupCount, 10)))
		b.WriteString(fact("Available key packages", strconv.FormatInt(d.Groups.AvailableKeyPackages, 10)))
		b.WriteString(fact("Stored inbox records", strconv.FormatInt(d.Groups.InboxRecords, 10)))
	}
	b.WriteString("\n  GROUP                         EPOCH  DEVICES  POLICY\n")
	for i, g := range m.groups.Groups {
		prefix, policy := "  ", "active"
		if i == m.row {
			prefix = "> "
		}
		if g.Paused {
			policy = "paused"
		}
		fmt.Fprintf(&b, "%s%-29s %5d %8d  %s\n", prefix, groupLabel(g.Title, 28), g.Epoch, g.DeviceCount, policy)
	}
	if len(m.groups.Groups) == 0 {
		b.WriteString("No MLS groups on this page.\n")
	}
	if g := m.selectedGroup(); g != nil {
		b.WriteString("\n" + fact("Group ID", groupLabel(g.ID, 64)))
		b.WriteString(fact("Accounts / devices", fmt.Sprintf("%d / %d", g.AccountCount, g.DeviceCount)))
		b.WriteString(fact("Revision / sequence", fmt.Sprintf("%d / %d", g.Revision, g.Sequence)))
		b.WriteString(fact("Stored inbox records", strconv.FormatInt(g.InboxRecords, 10)))
		if m.groupDetail != nil && m.groupDetail.ID == g.ID {
			b.WriteString("\nLast inspected members (revoked devices need a client removal commit):\n")
			for _, member := range m.groupDetail.Members {
				state := "active"
				if !member.Active {
					state = "revoked / missing"
				}
				fmt.Fprintf(&b, "%s  %s  %s  %s\n", groupLabel(member.AccountID, 24), groupLabel(member.DeviceID, 24), groupLabel(member.Role, 8), state)
			}
		}
	}
	b.WriteString("\nInbox records are retained ciphertext records, not unread-message counts.\n")
	return b.String()
}
