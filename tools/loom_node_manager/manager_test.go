package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestDiagnosticsContractUnmarshal(t *testing.T) {
	payload := []byte(`{
		"schemaVersion":1,
		"ready":true,
		"overallStatus":"healthy",
		"registration":{"policy":"approval","acceptingRegistrations":true,"automaticRegistration":false,"approvalWorkflowReady":true,"pendingRequests":2,"status":"approval_required"},
		"federation":{"mode":"disabled","enabled":false,"discoveryReady":true,"ingressReady":false,"routingReady":false,"status":"disabled"},
		"storage":{"database":{"ready":true,"backend":"postgresql","latencyMs":3,"stats":{"accounts":4,"messages":9}},"attachments":{"ready":true,"backend":"s3","latencyMs":5,"bucket":"loom-attachments"}},
		"network":{"publicDomain":"node.example.com","publicBaseUrl":"https://node.example.com","tlsExpected":true,"lanDiscovery":true},
		"security":{"nodeIdentityReady":true,"adminTokenConfigured":true,"nodeFingerprint":"AAAA BBBB"},
		"runtime":{"mode":"production","uptimeSeconds":3600,"listenHost":"0.0.0.0","listenPort":7483},
		"node":{"serverVersion":"0.8.0","nodeId":"node:test","domain":"node.example.com","endpoint":"https://node.example.com","fingerprint":"AAAA BBBB","registration":"approval","federationMode":"disabled"}
	}`)
	var diagnostics nodeDiagnostics
	if err := json.Unmarshal(payload, &diagnostics); err != nil {
		t.Fatalf("unmarshal diagnostics: %v", err)
	}
	if !diagnostics.Ready || diagnostics.Registration.PendingRequests != 2 {
		t.Fatalf("unexpected diagnostics: %+v", diagnostics.Registration)
	}
	if diagnostics.Storage.Database.Backend != "postgresql" || diagnostics.Storage.Database.Stats["messages"] != 9 {
		t.Fatalf("unexpected storage diagnostics: %+v", diagnostics.Storage.Database)
	}
}

func TestRegistrationPageBuildsContextControls(t *testing.T) {
	m := initialModel(newManager("."))
	m.page = 3
	m.snapshot.Diagnostics = &nodeDiagnostics{}
	m.snapshot.Diagnostics.Registration.Policy = "approval"
	m.snapshot.PendingRegistrations = []registrationRequest{{
		RequestID:           "reg_11111111-1111-1111-1111-111111111111",
		Username:            "alice",
		DisplayName:         "Alice",
		DeviceName:          "Laptop",
		IdentityFingerprint: "AAAA BBBB CCCC DDDD",
	}}
	actions := m.actions()
	if len(actions) != 5 {
		t.Fatalf("expected 3 policy controls + approve + reject, got %d actions", len(actions))
	}
	if actions[0].kind != "setting" || actions[0].args[1] != "open" {
		t.Fatalf("unexpected open-registration action: %+v", actions[0])
	}
	if !actions[1].disabled || actions[1].args[1] != "approval" {
		t.Fatalf("current approval policy should be disabled: %+v", actions[1])
	}
	if actions[3].kind != "registration" || actions[3].args[1] != "approve" || !actions[3].dangerous {
		t.Fatalf("unexpected approve action: %+v", actions[3])
	}
	if actions[4].args[1] != "reject" || !actions[4].dangerous {
		t.Fatalf("unexpected reject action: %+v", actions[4])
	}
}

func TestFederationPageSeparatesDiscoveryFromTrust(t *testing.T) {
	m := initialModel(newManager("."))
	m.page = 4
	m.snapshot.Diagnostics = &nodeDiagnostics{}
	m.snapshot.Diagnostics.Federation.Mode = "trusted"
	m.federation = federationStatus{
		Mode: "trusted",
		Nodes: []federationNode{{Domain: "remote.example", NodeID: "node:test", TrustState: "verified", Health: "online"}},
	}
	actions := m.actions()
	if len(actions) < 9 {
		t.Fatalf("expected mode selector and selected-node controls, got %d", len(actions))
	}
	if !actions[1].disabled || actions[1].args[1] != "trusted" {
		t.Fatalf("trusted federation control should reflect current mode: %+v", actions[1])
	}
	foundTrust := false
	for _, action := range actions {
		if action.kind == "node-action" && action.label == "Trust" {
			foundTrust = true
			if action.args[0] != "node:test" || action.args[1] != "trust" {
				t.Fatalf("unexpected trust action: %+v", action)
			}
		}
	}
	if !foundTrust {
		t.Fatal("verified node should expose an explicit Trust control")
	}
}

func TestExplicitFocusNavigationUsesArrowsWithinPanel(t *testing.T) {
	m := initialModel(newManager("."))
	if m.focus != focusSidebar {
		t.Fatalf("initial focus should be sidebar, got %d", m.focus)
	}
	m.movePage(1)
	if m.page != 1 {
		t.Fatalf("sidebar page did not move: %d", m.page)
	}
	m.focus = focusActions
	m.actionCursor = 0
	if len(m.actions()) < 2 {
		t.Fatal("services should have multiple contextual actions")
	}
	m.actionCursor++
	if m.page != 1 {
		t.Fatal("moving action selection must not change sidebar page")
	}
}

func TestReplaceEnvSetting(t *testing.T) {
	input := "A=1\nLOOM_FEDERATION_MODE=disabled\n# keep me\n"
	got := replaceEnvSetting(input, "LOOM_FEDERATION_MODE", "trusted")
	if !strings.Contains(got, "LOOM_FEDERATION_MODE=trusted\n") {
		t.Fatalf("setting was not replaced: %q", got)
	}
	if strings.Contains(got, "LOOM_FEDERATION_MODE=disabled") || !strings.Contains(got, "# keep me") {
		t.Fatalf("replacement damaged env content: %q", got)
	}

	appended := replaceEnvSetting("A=1\n", "LOOM_LAN_DISCOVERY", "true")
	if !strings.Contains(appended, "A=1\nLOOM_LAN_DISCOVERY=true\n") {
		t.Fatalf("setting was not appended correctly: %q", appended)
	}
}

func TestRandomAdminToken(t *testing.T) {
	token, err := randomAdminToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(token) < 40 || strings.ContainsAny(token, "\r\n") {
		t.Fatalf("unexpected token format: %q", token)
	}
}

func TestFormatUptime(t *testing.T) {
	if got := formatUptime(90061); got != "1d 01h 01m" {
		t.Fatalf("unexpected uptime: %s", got)
	}
}
