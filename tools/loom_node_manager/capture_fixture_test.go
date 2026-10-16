package main

import (
	tea "charm.land/bubbletea/v2"
	"testing"
)

func TestCaptureFixtureCannotRunProductionCommands(t *testing.T) {
	m := newCaptureFixture()
	if m.Init() != nil {
		t.Fatal("fixture must not initialize services")
	}
	for page := range pages {
		m.dashboard.inner.page = page
		for _, key := range []string{"enter", "y", "r", "u", "a"} {
			updated, cmd := m.Update(tea.KeyPressMsg{Text: key})
			if cmd != nil {
				t.Fatalf("fixture started command on %s: %s", pages[page], key)
			}
			m = updated.(captureFixture)
		}
	}
	if m.dashboard.inner.mgr.home != "" {
		t.Fatal("fixture acquired installation")
	}
}
