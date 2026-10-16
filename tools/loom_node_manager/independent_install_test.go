package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestIndependentLoomDefaultDoesNotAdoptLegacyHome(t *testing.T) {
	t.Chdir(t.TempDir())
	t.Setenv("LOOM_NODE_HOME", "")
	t.Setenv("FOREIGN_NODE_HOME", filepath.Join(t.TempDir(), "legacy-node"))
	programData := t.TempDir()
	t.Setenv("ProgramData", programData)
	legacy := filepath.Join(programData, "PreviousApp", "Node", "preserved.txt")
	if err := os.MkdirAll(filepath.Dir(legacy), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacy, []byte("existing data"), 0600); err != nil {
		t.Fatal(err)
	}
	want := "/opt/loom-node"
	if runtime.GOOS == "windows" {
		want = filepath.Join(programData, "Loom", "Node")
	}
	if got := defaultHome(); got != want {
		t.Fatalf("new installation home = %q; want %q", got, want)
	}
	if data, err := os.ReadFile(legacy); err != nil || string(data) != "existing data" {
		t.Fatal("legacy data was changed", err)
	}
}

func TestLoomExplicitHomeIsRespected(t *testing.T) {
	t.Chdir(t.TempDir())
	want := filepath.Join(t.TempDir(), "operator-selected-node")
	t.Setenv("LOOM_NODE_HOME", want)
	if got := defaultHome(); got != want {
		t.Fatalf("home = %q; want %q", got, want)
	}
}
