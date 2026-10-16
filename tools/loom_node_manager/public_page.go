package main

import (
 "fmt"
 "net/url"
 "strconv"
 "strings"
)

func configuredUploadLimit(values map[string]string) string {
 raw := values["LOOM_MAX_ATTACHMENT_BYTES"]
 if raw == "" { raw = "104857600" }
 if validateRuntimeSetting("LOOM_MAX_ATTACHMENT_BYTES", raw) != nil { return "Invalid setting — check production .env" }
 n, _ := strconv.ParseInt(raw, 10, 64)
 return fmt.Sprintf("%.1f MiB encrypted / %.1f MiB media before encryption", float64(n)/(1024*1024), float64(n-28)/(1024*1024))
}

func publicNodeURL(raw string) string {
 u, err := url.Parse(strings.TrimSpace(raw))
 if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil { return "" }
 u.Path, u.RawPath, u.RawQuery, u.Fragment = "", "", "", ""
 return strings.TrimRight(u.String(), "/")
}

func (m model) publicPageView() string {
 values := loadEnv(m.mgr.envPath)
 var b strings.Builder
 b.WriteString(titleStyle.Render("Public node page") + "\n\n")
 base := publicNodeURL(values["LOOM_PUBLIC_BASE_URL"])
 if d := m.snapshot.Diagnostics; d != nil {
  base = publicNodeURL(d.Network.PublicBaseURL)
  b.WriteString(fact("Running Node", d.Node.ServerVersion))
  b.WriteString(fact("Federation", d.Federation.Mode))
  b.WriteString(fact("Registered users", metric(d.Storage.Database.Stats, "accounts")))
  b.WriteString(fact("Process uptime", fmt.Sprintf("%d seconds", d.Runtime.UptimeSeconds)))
 }
 if base != "" {
  b.WriteString(fact("Public page", base + "/"))
  b.WriteString(fact("Share / download QR", base + "/node-qr.svg"))
  b.WriteString(fact("Public status JSON", base + "/api/v1/server/status"))
 } else { b.WriteString(fact("Public URL", "Unavailable — refresh diagnostics")) }
 b.WriteString("\n" + titleStyle.Render("Production configuration") + "\n")
 b.WriteString(fact("Configured upload limit", configuredUploadLimit(values)))
 b.WriteString(fact("Public process memory", status(values["LOOM_PUBLIC_RESOURCE_METRICS"] == "true", "Shown: process RSS and heap", "Hidden (default)")))
 b.WriteString("\nChanges recreate only the Node and briefly interrupt connections.\nThe proxy can enforce a lower upload ceiling; Nginx/Caddy configuration is separate.\nConfiguration values are from .env; they are not a runtime attestation.\n\nProject overview, clients and optional project donations appear on the public page.\nProject: https://github.com/0800x/Loom\n")
 return b.String()
}

func (m model) publicPageActions() []action {
 values := loadEnv(m.mgr.envPath)
 current := values["LOOM_PUBLIC_RESOURCE_METRICS"]
 if current == "" { current = "false" }
 limit := values["LOOM_MAX_ATTACHMENT_BYTES"]
 if limit == "" { limit = "104857600" }
 actions := []action{
  {label:"Refresh", hint:"reload Node diagnostics and page configuration", kind:"refresh"},
  settingAction("Hide process metrics", "remove public RSS/heap; recreates only the Node", "LOOM_PUBLIC_RESOURCE_METRICS", "false", current, true),
  settingAction("Show process metrics", "publish only Loom process RSS/heap; recreates only the Node", "LOOM_PUBLIC_RESOURCE_METRICS", "true", current, true),
 }
 for _, mib := range []int64{10,25,50,100} {
  actions = append(actions, settingAction(fmt.Sprintf("Upload ceiling: %d MiB", mib), "encrypted file limit; proxy may impose a lower ceiling; recreates only the Node", "LOOM_MAX_ATTACHMENT_BYTES", strconv.FormatInt(mib*1024*1024,10), limit, true))
 }
 return actions
}
