package main

import (
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLocalHTTPSRequiresExplicitCertificate(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) }))
	defer server.Close()
	if probePublic(server.URL).Ready {
		t.Fatal("unconfigured self-signed certificate was trusted")
	}
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	if result := probePublicWithCertificate(server.URL, certificate); !result.Ready {
		t.Fatalf("explicit certificate rejected: %s", result.Error)
	}
	if probePublicWithCertificate(server.URL, []byte("not a certificate")).Ready {
		t.Fatal("invalid certificate trusted")
	}
}
