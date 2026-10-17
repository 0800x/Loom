package main

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

func TestUpdateVersionLabelIncludesCommit(t *testing.T) {
	got := updateVersionLabel("0.7.0", "1234567890abcdef")
	if got != "0.7.0  •  1234567890" {
		t.Fatalf("unexpected label: %q", got)
	}
}

func TestUpdateStateLabelsAreOperatorReadable(t *testing.T) {
	if got := updateStateLabel("up_to_date"); !strings.Contains(got, "Latest version installed") {
		t.Fatalf("unexpected current label: %q", got)
	}
	if got := updateStateLabel("update_available"); !strings.Contains(got, "New update available") {
		t.Fatalf("unexpected available label: %q", got)
	}
}

func TestCommitMatchLabelUsesFullCommitIdentity(t *testing.T) {
	if got := commitMatchLabel("ABCDEF012345", "abcdef012345"); !strings.Contains(got, "exact match") {
		t.Fatalf("expected exact match label: %q", got)
	}
	if got := commitMatchLabel("abcdef012345", "abcdef012346"); !strings.Contains(got, "newer commit available") {
		t.Fatalf("expected mismatch label: %q", got)
	}
}

func TestUpdateCheckNeverAutoInstalls(t *testing.T) {
	m := dashboardModel{
		inner:      model{page: len(pages) - 1},
		updateBusy: true,
	}
	updated, cmd := m.Update(updateCheckMsg{status: updateStatus{
		State:           "update_available",
		Branch:          "main",
		InstalledCommit: "1111111111111111111111111111111111111111",
		AvailableCommit: "2222222222222222222222222222222222222222",
	}})
	if cmd != nil {
		t.Fatal("an update check must not start installation")
	}
	got := updated.(dashboardModel)
	if got.inner.update.State != "update_available" || got.updateEvents != nil {
		t.Fatalf("unexpected update state after check: %+v", got.inner.update)
	}
	if !strings.Contains(got.inner.message, "install it manually") {
		t.Fatalf("expected manual-install guidance, got %q", got.inner.message)
	}
}

func TestClipLinesMakesLongPagesScrollable(t *testing.T) {
	content := strings.Join([]string{"0", "1", "2", "3", "4", "5", "6", "7"}, "\n")
	got, above, below := clipLines(content, 4, 2)
	if got != "2\n3\n4\n5" || !above || !below {
		t.Fatalf("unexpected viewport: %q above=%v below=%v", got, above, below)
	}
}

func TestPercentClampsEmptyTotal(t *testing.T) {
	if got := percent(10, 0); got != 0 {
		t.Fatalf("expected zero, got %v", got)
	}
	if got := percent(25, 100); got != 25 {
		t.Fatalf("expected 25, got %v", got)
	}
}

func TestUpdateProgressClamp(t *testing.T) {
	var got updateProgress
	reportUpdateProgress(func(progress updateProgress) { got = progress }, 120, "done")
	if got.Percent != 100 || got.Stage != "done" {
		t.Fatalf("unexpected progress: %+v", got)
	}
}

func TestDashboardFitsNarrowTerminalAndKeepsConfirmationVisible(t *testing.T) {
	for _, size := range [][2]int{{120, 40}, {80, 24}, {40, 12}} {
		m := dashboardModel{inner: model{width: size[0], height: size[1], message: strings.Repeat("A long operation result with a path /opt/loom-node. ", 100)}}
		view := m.View().Content
		if lipgloss.Width(view) > size[0] || lipgloss.Height(view) > size[1] {
			t.Fatalf("view overflows %dx%d", size[0], size[1])
		}
		m.scroll = m.maxScroll()
		m.inner.confirm = &action{label: "Restart Node", hint: "Restart the selected container", dangerous: true}
		m.clampScroll()
		view = m.View().Content
		if !strings.Contains(view, "[y]") || !strings.Contains(view, "cancel") {
			t.Fatal("confirmation controls are outside the viewport")
		}
	}
}

func TestEndThenScrollUpMovesImmediately(t *testing.T) {
	m := dashboardModel{inner: model{width: 80, height: 24, message: strings.Repeat("log line\n", 100)}}
	updated, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEnd})
	m = updated.(dashboardModel)
	end := m.scroll
	if end != m.maxScroll() || end == 0 {
		t.Fatalf("incorrect end: %d", end)
	}
	updated, _ = m.Update(tea.KeyPressMsg{Code: '[', Text: "["})
	m = updated.(dashboardModel)
	if m.scroll != max(0, end-8) {
		t.Fatalf("scroll up after End is stuck: %d -> %d", end, m.scroll)
	}
}

func TestBackgroundRefreshPreservesSelectedDeliveryAndRunningAction(t *testing.T) {
	page := 0
	for i, name := range pages {
		if name == "Federation Queue" {
			page = i
		}
	}
	m := dashboardModel{inner: model{page: page, row: 1, busy: true, message: "Retrying selected message", queue: federationQueue{Deliveries: []federationDelivery{{DeliveryID: "a"}, {DeliveryID: "b"}}}}}
	updated, _ := m.Update(dashboardStatusMsg{queue: federationQueueMsg{queue: federationQueue{Deliveries: []federationDelivery{{DeliveryID: "b"}, {DeliveryID: "a"}}}}})
	m = updated.(dashboardModel)
	if m.inner.selectedDelivery().DeliveryID != "b" {
		t.Fatal("refresh selected a different delivery")
	}
	if !m.inner.busy || m.inner.message != "Retrying selected message" {
		t.Fatal("background refresh overwrote the running action")
	}
}

func TestInstallActionUsesSelectionBeforeUpdatingUIState(t *testing.T) {
	model := initialDashboardModel(newManager(t.TempDir()))
	model.inner.update = updateStatus{State: "update_available", AvailableCommit: "invalid-selected-commit"}
	updated, command := model.startUpdate()
	if updated.inner.update.State != "updating" {
		t.Fatal("UI did not enter updating state")
	}
	message, ok := command().(updateApplyMsg)
	if !ok || message.err == nil || !strings.Contains(message.err.Error(), "invalid selected update commit") {
		t.Fatalf("the reviewed selection was replaced by UI state: %+v", message)
	}
}
