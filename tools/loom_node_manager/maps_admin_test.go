package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestMapsCacheStatusDecodesPersistentUsageAndWarmProgress(t *testing.T) {
	body := `{"job":{"country":"ir","minZoom":0,"maxZoom":8,"total":285,"done":120,"failed":2,"running":true},"directory":"/app/data/tile-cache","upstream":"https://tiles.example.org/{z}/{x}/{y}.png","minZoom":0,"maxZoom":17,"prefetchEnabled":true,"disk":{"files":122,"bytes":524288}}`
	var status mapsCacheStatus
	if err := json.Unmarshal([]byte(body), &status); err != nil {
		t.Fatal(err)
	}
	if status.Job == nil || status.Job.Country != "ir" || status.Job.Done != 120 || !status.Job.Running {
		t.Fatalf("unexpected warm-up status: %+v", status.Job)
	}
	if status.Disk.Files != 122 || status.Disk.Bytes != 524288 || !status.PrefetchEnabled {
		t.Fatalf("unexpected cache status: %+v", status)
	}
}

func TestMapsWarmActionsRequireProviderPrefetchPermission(t *testing.T) {
	m := initialModel(newManager(t.TempDir()))
	for i, page := range pages {
		if page == "Maps" { m.page = i; break }
	}
	countWarm := func() int {
		count := 0
		for _, item := range m.actions() {
			if item.kind == "maps-warm" { count++ }
		}
		return count
	}
	if got := countWarm(); got != 0 {
		t.Fatalf("warm actions exposed while prefetch is disabled: %d", got)
	}
	m.mapsCache.PrefetchEnabled = true
	if got := countWarm(); got != 3 {
		t.Fatalf("warm actions = %d, want 3", got)
	}
	if !strings.Contains(m.mapsView(), "PREFETCH ENABLED") {
		t.Fatal("Maps page did not report the enabled provider policy")
	}
}
