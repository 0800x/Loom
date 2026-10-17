package main

import (
	"charm.land/lipgloss/v2"
	"errors"
	"strings"
	"testing"
)

func groupModel() model {
	m := initialModel(manager{})
	for i, p := range pages {
		if p == "Groups" {
			m.page = i
		}
	}
	m.groups = groupStatus{Protocol: "Loom-MLS-v1", Groups: []adminGroup{{ID: "g1", Title: "Friends", Epoch: 3, DeviceCount: 2, PolicyRevision: 4}, {ID: "g2", Title: "Work"}}}
	return m
}
func TestGroupControlsUseSelectedIDAndRevision(t *testing.T) {
	m := groupModel()
	a := m.groupActions()[2]
	if a.kind != "group-policy" || !a.dangerous || strings.Join(a.args, ",") != "g1,true,4" {
		t.Fatalf("unsafe policy action: %+v", a)
	}
	m.groups.Groups[0].Paused = true
	if a := m.groupActions()[2]; a.label != "Resume new messages" || a.args[1] != "false" {
		t.Fatal(a)
	}
	m.groupsError = "unauthorized"
	if len(m.groupActions()) != 1 {
		t.Fatal("stale metadata enabled controls")
	}
	if strings.Contains(m.groupsView(), "engine unavailable") {
		t.Fatal("stale engine warning")
	}
}
func TestGroupRefreshPreservesSelectionAndDropsOldPage(t *testing.T) {
	m := groupModel()
	m.row = 1
	updated, _ := m.Update(groupsMsg{status: groupStatus{Protocol: "Loom-MLS-v1", Groups: []adminGroup{{ID: "g2"}, {ID: "g1"}}}})
	m = updated.(model)
	if m.row != 0 || m.selectedRowID() != "g2" {
		t.Fatal("selection changed")
	}
	m.groupsAfter = "g2"
	updated, _ = m.Update(groupsMsg{status: groupStatus{Protocol: "Loom-MLS-v1", Groups: []adminGroup{{ID: "obsolete"}}}, after: ""})
	m = updated.(model)
	if m.groups.Groups[0].ID != "g2" {
		t.Fatal("old page replaced current page")
	}
	updated, _ = m.Update(groupsMsg{after: "g2", err: errors.New("offline")})
	m = updated.(model)
	if m.groupsError != "offline" || len(m.groupActions()) != 1 {
		t.Fatal("error left controls enabled")
	}
}
func TestGroupMetadataCannotInjectTerminalControls(t *testing.T) {
	value := groupLabel("Friends\x1b]52;c;secret\a\n\u202e", 100)
	if strings.ContainsAny(value, "\x1b\a\n\u202e") {
		t.Fatal("remote terminal control retained")
	}
	m := groupModel()
	m.groups.Groups[0].Title = "Persian گروه"
	m.groupDetail = &groupDetail{adminGroup: m.groups.Groups[0], Members: []groupMember{{AccountID: "account", DeviceID: "device", Role: "owner", Active: false}}}
	view := m.groupsView()
	for _, text := range []string{"Persian گروه", "revoked / missing", "not unread-message counts"} {
		if !strings.Contains(view, text) {
			t.Fatal(text)
		}
	}
}

func TestGroupPolicyConfirmationCapturesOriginalTarget(t *testing.T) {
	m := groupModel()
	m.actionCursor = 2
	updated, cmd := m.runSelected()
	m = updated.(model)
	if cmd != nil || m.confirm == nil || m.confirm.args[0] != "g1" {
		t.Fatal("policy bypassed confirmation")
	}
	m.row = 1
	if m.confirm.args[0] != "g1" || m.confirm.args[2] != "4" {
		t.Fatal("confirmation target changed with selection")
	}
}

func TestGroupDashboardFitsNarrowScreensWithLongMetadata(t *testing.T) {
	for _, size := range [][2]int{{120, 40}, {80, 24}, {40, 12}} {
		inner := groupModel()
		inner.width = size[0]
		inner.height = size[1]
		inner.groups.Groups[0].Title = strings.Repeat("گروه long group name ", 30)
		inner.confirm = &action{label: "Pause new messages", hint: "Inbox and MLS commits remain available", dangerous: true}
		m := dashboardModel{inner: inner}
		view := m.View().Content
		if lipgloss.Width(view) > size[0] || lipgloss.Height(view) > size[1] {
			t.Fatalf("group screen overflows %dx%d", size[0], size[1])
		}
		if !strings.Contains(view, "[y]") || !strings.Contains(view, "cancel") {
			t.Fatal("group confirmation clipped")
		}
	}
}
