package main

import "testing"

func TestAutomaticTURNRejectsUninstalledPaths(t *testing.T) {
	m := manager{home: t.TempDir()}
	if _, err := m.automaticTURNCommand(); err == nil {
		t.Fatal("fixture path could launch production setup")
	}
}
