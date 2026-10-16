package main

import (
 "strings"
 "testing"
)

func TestPublicPageSettings(t *testing.T) {
 for _, value := range []string{"29","104857600","2147483648"} {
  if err := validateRuntimeSetting("LOOM_MAX_ATTACHMENT_BYTES",value); err != nil { t.Fatalf("valid limit %s: %v",value,err) }
 }
 for _, value := range []string{"28","2147483649","-1","1e8","100\nEVIL=true","0100"} {
  if validateRuntimeSetting("LOOM_MAX_ATTACHMENT_BYTES",value) == nil { t.Fatalf("accepted invalid limit %q",value) }
 }
 if validateRuntimeSetting("LOOM_PUBLIC_RESOURCE_METRICS","true") != nil { t.Fatal("metrics opt-in rejected") }
 if validateRuntimeSetting("LOOM_ADMIN_TOKEN","anything") == nil { t.Fatal("unexpected setting allowed") }
 if !strings.Contains(configuredUploadLimit(map[string]string{}),"100.0 MiB") { t.Fatal("default ceiling incorrect") }
}

func TestPublicNodeURL(t *testing.T) {
 if got := publicNodeURL("https://node.example:8443/path?token=hidden#fragment"); got != "https://node.example:8443" { t.Fatal(got) }
 for _, raw := range []string{"javascript:alert(1)","http://node.example","https://user:secret@node.example"} {
  if publicNodeURL(raw) != "" { t.Fatalf("unsafe URL accepted: %s",raw) }
 }
}
