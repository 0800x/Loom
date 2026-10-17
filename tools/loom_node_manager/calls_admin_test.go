package main

import "testing"

func TestCallingSetupValidationDoesNotAcceptEnvInjection(t *testing.T) {
	good := map[string]string{"LOOM_TURN_URLS":"turn:turn.example.org:3478?transport=udp,turns:turn.example.org:5349?transport=tcp", "LOOM_STUN_URLS":"stun:turn.example.org:3478", "LOOM_TURN_SHARED_SECRET":"01234567890123456789012345678901"}
	if err := validateCalling(good); err != nil { t.Fatal(err) }
	for _, bad := range []string{"https://example.org", "turn:host:99999", "turn:host\nLOOM_CALLS_ENABLED=true", "turn:user@host", "turn:host?transport=arbitrary"} {
		if validateICEList(bad, true) == nil { t.Fatalf("accepted invalid ICE endpoint %q", bad) }
	}
	good["LOOM_TURN_SHARED_SECRET"] = "${LOOM_ADMIN_TOKEN}01234567890123456789"
	if validateCalling(good) == nil { t.Fatal("accepted environment expansion in TURN secret") }
}

func TestCallingControlsUseActualNodeState(t *testing.T) {
	m := initialModel(newManager(t.TempDir()))
	for i, page := range pages { if page == "Calls" { m.page = i } }
	actions := m.actions()
	if len(actions) < 7 || actions[0].kind != "configure-group-calls" { t.Fatalf("calling controls missing: %v", actions) }
	if !actions[1].dangerous { t.Fatal("disabling active calls requires operator confirmation") }
}
