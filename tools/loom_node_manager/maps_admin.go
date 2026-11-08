package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

type mapsCacheJob struct {
	Country   string `json:"country"`
	MinZoom   int    `json:"minZoom"`
	MaxZoom   int    `json:"maxZoom"`
	Total     int    `json:"total"`
	Done      int    `json:"done"`
	Failed    int    `json:"failed"`
	StartedAt string `json:"startedAt"`
	Running   bool   `json:"running"`
}

type mapsCacheDisk struct {
	Files int    `json:"files"`
	Bytes uint64 `json:"bytes"`
}

type mapsCacheStatus struct {
	Job             *mapsCacheJob `json:"job"`
	Directory       string        `json:"directory"`
	Upstream        string        `json:"upstream"`
	MinZoom         int           `json:"minZoom"`
	MaxZoom         int           `json:"maxZoom"`
	PrefetchEnabled bool          `json:"prefetchEnabled"`
	Disk            mapsCacheDisk `json:"disk"`
}

type mapsCacheMsg struct {
	status mapsCacheStatus
	err    error
}

func (m manager) internalAdminPost(path string, body []byte) (string, error) {
	const script = `const path=process.argv[1],body=process.argv[2],token=process.env.LOOM_ADMIN_TOKEN;if(!token){console.error('admin token missing in container');process.exit(2)}fetch('http://127.0.0.1:7483'+path,{method:'POST',signal:AbortSignal.timeout(15000),headers:{authorization:'Bearer '+token,'content-type':'application/json'},body}).then(async r=>{const text=await r.text();if(!r.ok){console.error(text);process.exit(3)}console.log(text)}).catch(e=>{console.error(e.message);process.exit(4)})`
	return probeOutputTimeout(60*time.Second, "docker", m.composeArgs("exec", "-T", "loom-node", "node", "-e", script, path, string(body))...)
}

func (m manager) readMapsCache() (mapsCacheStatus, error) {
	var status mapsCacheStatus
	output, err := m.internalAdminGet("/admin/v1/maps/status")
	if err != nil {
		return status, fmt.Errorf("map cache status failed: %w: %s", err, output)
	}
	if err := json.Unmarshal([]byte(output), &status); err != nil {
		return status, fmt.Errorf("invalid map cache status JSON: %w", err)
	}
	return status, nil
}

func (m manager) warmMapsCountry(country string, minZoom, maxZoom int) (string, error) {
	body, err := json.Marshal(map[string]any{"country": country, "minZoom": minZoom, "maxZoom": maxZoom})
	if err != nil {
		return "", err
	}
	output, err := m.internalAdminPost("/admin/v1/maps/warm", body)
	if err != nil {
		return output, fmt.Errorf("map warm-up failed: %w", err)
	}
	return fmt.Sprintf("Map warm-up queued for %s (zoom %d–%d).\n%s", strings.ToUpper(country), minZoom, maxZoom, output), nil
}

func (m manager) purgeMapsCache() (string, error) {
	output, err := m.internalAdminPost("/admin/v1/maps/purge", []byte("{}"))
	if err != nil {
		return output, fmt.Errorf("map cache purge failed: %w", err)
	}
	return "Persistent map tile cache purged.\n" + output, nil
}

func mapsCacheCmd(mgr manager) tea.Cmd {
	return func() tea.Msg {
		status, err := mgr.readMapsCache()
		return mapsCacheMsg{status: status, err: err}
	}
}

func mapsWarmCmd(mgr manager, country string, minZoom, maxZoom int) tea.Cmd {
	return func() tea.Msg {
		output, err := mgr.warmMapsCountry(country, minZoom, maxZoom)
		return actionMsg{name: "Map warm-up", output: output, err: err}
	}
}

func mapsPurgeCmd(mgr manager) tea.Cmd {
	return func() tea.Msg {
		output, err := mgr.purgeMapsCache()
		return actionMsg{name: "Purge map cache", output: output, err: err}
	}
}

func (m model) mapsView() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render("Map tile cache"))
	if m.mapsCacheError != "" {
		b.WriteString("\n\n" + badStyle.Render("Map cache probe failed") + "\n" + m.mapsCacheError)
		return b.String()
	}
	if m.mapsCache.Directory == "" {
		b.WriteString("\n\n" + dimStyle.Render("Map cache status has not been loaded. Select Refresh map cache."))
		return b.String()
	}
	b.WriteString(section("PERSISTENT CACHE"))
	b.WriteString(fact("Cached tiles", fmt.Sprintf("%d files", m.mapsCache.Disk.Files)))
	b.WriteString(fact("Disk usage", formatBytes(m.mapsCache.Disk.Bytes)))
	b.WriteString(fact("Cache directory", m.mapsCache.Directory))
	b.WriteString(fact("Zoom range", fmt.Sprintf("%d–%d", m.mapsCache.MinZoom, m.mapsCache.MaxZoom)))
	if parsed, err := url.Parse(m.mapsCache.Upstream); err == nil && parsed.Hostname() != "" {
		b.WriteString(fact("Tile provider", parsed.Hostname()))
	}
	b.WriteString(section("WARM-UP JOB"))
	if m.mapsCache.Job == nil {
		b.WriteString(fact("Status", "Idle"))
	} else {
		job := m.mapsCache.Job
		state := "Completed"
		if job.Running { state = "Running" }
		b.WriteString(fact("Status", state))
		b.WriteString(fact("Country", strings.ToUpper(job.Country)))
		b.WriteString(fact("Zoom", fmt.Sprintf("%d–%d", job.MinZoom, job.MaxZoom)))
		b.WriteString(fact("Progress", fmt.Sprintf("%d / %d", job.Done+job.Failed, job.Total)))
		b.WriteString(fact("Cached", fmt.Sprintf("%d", job.Done)))
		b.WriteString(fact("Failed", fmt.Sprintf("%d", job.Failed)))
	}
	b.WriteString(section("PROVIDER POLICY"))
	if m.mapsCache.PrefetchEnabled {
		b.WriteString(status(true, "PREFETCH ENABLED", "PREFETCH DISABLED"))
		b.WriteString("\n" + dimStyle.Render("Only use warm-up when the provider's licence explicitly permits bulk downloads and offline caching."))
	} else {
		b.WriteString(status(false, "PREFETCH ENABLED", "PREFETCH DISABLED"))
		b.WriteString("\n" + dimStyle.Render("Interactive viewport tiles can still be cached. Bulk country downloads are disabled; OSM standard tiles and Google Maps tiles are never prefetch sources."))
		b.WriteString("\n" + dimStyle.Render("For a licensed provider, set LOOM_TILE_CACHE_ALLOW_PREFETCH=true in the Node .env and configure its XYZ template."))
	}
	return b.String()
}
