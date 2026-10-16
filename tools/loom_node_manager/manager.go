package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

type nodeDiagnostics struct {
 Groups *groupDiagnostics `json:"groups"`
	SchemaVersion int    `json:"schemaVersion"`
	GeneratedAt   string `json:"generatedAt"`
	Ready         bool   `json:"ready"`
	OverallStatus string `json:"overallStatus"`
	Node          struct {
		ServerVersion       string `json:"serverVersion"`
		NodeID              string `json:"nodeId"`
		Name                string `json:"name"`
		Domain              string `json:"domain"`
		Endpoint            string `json:"endpoint"`
		Fingerprint         string `json:"fingerprint"`
		Registration        string `json:"registration"`
		FederationMode      string `json:"federationMode"`
		NetworkJurisdiction string `json:"networkJurisdiction"`
	} `json:"node"`
	Runtime struct {
		Mode          string `json:"mode"`
		BuildCommit string `json:"buildCommit"`
		UptimeSeconds int64  `json:"uptimeSeconds"`
		ListenHost    string `json:"listenHost"`
		ListenPort    int    `json:"listenPort"`
	} `json:"runtime"`
	Storage struct {
		Database struct {
			Ready     bool               `json:"ready"`
			Backend   string             `json:"backend"`
			LatencyMS int64              `json:"latencyMs"`
			Stats     map[string]float64 `json:"stats"`
			Error     string             `json:"error"`
		} `json:"database"`
		Attachments struct {
			Ready     bool   `json:"ready"`
			Backend   string `json:"backend"`
			LatencyMS int64  `json:"latencyMs"`
			Bucket    string `json:"bucket"`
			Detail    string `json:"detail"`
		} `json:"attachments"`
	} `json:"storage"`
	Network struct {
		PublicDomain  string `json:"publicDomain"`
		PublicBaseURL string `json:"publicBaseUrl"`
		TLSExpected   bool   `json:"tlsExpected"`
		LANDiscovery  bool   `json:"lanDiscovery"`
	} `json:"network"`
	Registration struct {
		Policy                 string `json:"policy"`
		AcceptingRegistrations bool   `json:"acceptingRegistrations"`
		AutomaticRegistration  bool   `json:"automaticRegistration"`
		ApprovalWorkflowReady  bool   `json:"approvalWorkflowReady"`
		PendingRequests        int    `json:"pendingRequests"`
		Status                 string `json:"status"`
	} `json:"registration"`
	Federation struct {
		Mode           string `json:"mode"`
		Enabled        bool   `json:"enabled"`
		DiscoveryReady bool   `json:"discoveryReady"`
		IngressReady   bool   `json:"ingressReady"`
		RoutingReady   bool   `json:"routingReady"`
		Status         string `json:"status"`
	} `json:"federation"`
	Messaging *struct {
		AccountStreams int `json:"accountStreams"`
		DeliveredFrames int64 `json:"deliveredFrames"`
		SyncFailures int64 `json:"syncFailures"`
	} `json:"messaging"`
	Calls *struct {
		VoiceEnabled bool `json:"voiceEnabled"`
		VideoEnabled bool `json:"videoEnabled"`
		RealtimeDevices int `json:"realtimeDevices"`
		PendingCalls int `json:"pendingCalls"`
		FederationFailures int64 `json:"federationFailures"`
		BackgroundPushReady bool `json:"backgroundPushReady"`
		Enabled bool `json:"enabled"`
		RTCReady bool `json:"rtcReady"`
        GroupCallsEnabled bool `json:"groupCallsEnabled"`
        GroupCallMaximum int `json:"groupCallMaximum"`
		TURNConfigured bool `json:"turnConfigured"`
	} `json:"calls"`
	Security struct {
		NodeIdentityReady    bool   `json:"nodeIdentityReady"`
		AdminTokenConfigured bool   `json:"adminTokenConfigured"`
		NodeFingerprint      string `json:"nodeFingerprint"`
	} `json:"security"`
}

type registrationRequest struct {
	RequestID           string `json:"requestId"`
	Username            string `json:"username"`
	DisplayName         string `json:"displayName"`
	DeviceName          string `json:"deviceName"`
	IdentityID          string `json:"identityId"`
	IdentityFingerprint string `json:"identityFingerprint"`
	Status              string `json:"status"`
	CreatedAt           string `json:"createdAt"`
}

type tlsSnapshot struct {
	Ready     bool
	DNS       []string
	Port80    bool
	Port443   bool
	Issuer    string
	ExpiresAt time.Time
	DaysLeft  int
	Error     string
}

type snapshot struct {
	Home                 string
	DockerInstalled      bool
	DockerReady          bool
	ComposeReady         bool
	ConfigPresent        bool
	Services             string
	Diagnostics          *nodeDiagnostics
	DiagnosticError      string
	PendingRegistrations []registrationRequest
	RegistrationError    string
	TLS                  tlsSnapshot
}

type manager struct {
	home        string
	deployDir   string
	envPath     string
	composePath string
}

func defaultHome() string {
	if configured := strings.TrimSpace(os.Getenv("LOOM_NODE_HOME")); configured != "" {
		return configured
	}
	if cwd, err := os.Getwd(); err == nil {
		candidate := filepath.Join(cwd, "deploy", "docker-compose.production.yml")
		if _, err := os.Stat(candidate); err == nil {
			return cwd
		}
	}
	if runtime.GOOS == "windows" {
		if programData := os.Getenv("ProgramData"); programData != "" {
			return filepath.Join(programData, "Loom", "Node")
		}
		return `C:\ProgramData\Loom\Node`
	}
	return "/opt/loom-node"
}

func newManager(home string) manager {
	home, _ = filepath.Abs(home)
	deployDir := filepath.Join(home, "deploy")
	return manager{
		home:        home,
		deployDir:   deployDir,
		envPath:     filepath.Join(deployDir, ".env"),
		composePath: filepath.Join(deployDir, "docker-compose.production.yml"),
	}
}

func loadEnv(path string) map[string]string {
	values := map[string]string{}
	file, err := os.Open(path)
	if err != nil {
		return values
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		values[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	return values
}

func commandOutput(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	bytes, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(bytes)), err
}

func (m manager) composeArgs(args ...string) []string {
	prefix := []string{"compose", "--env-file", m.envPath, "-f", m.composePath}
	if info,err:=os.Stat(filepath.Join(m.deployDir,"docker-compose.group-calls.yml"));err==nil&&info.Mode().IsRegular(){prefix=append(prefix,"-f",filepath.Join(m.deployDir,"docker-compose.group-calls.yml"))}
	return append(prefix, args...)
}

func (m manager) composeCommand(args ...string) *exec.Cmd {
	return exec.Command("docker", m.composeArgs(args...)...)
}

func (m manager) recentNodeLogs(tail int) string {
	if tail < 1 || tail > 200 {
		tail = 20
	}
	output, _ := commandOutput(
		"docker",
		m.composeArgs(
			"logs",
			"--no-color",
			"--tail",
			strconv.Itoa(tail),
			"loom-node",
		)...,
	)
	return strings.TrimSpace(output)
}

func probeOutput(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if ctx.Err() != nil { return "", fmt.Errorf("probe timed out: %s", name) }
	return strings.TrimSpace(string(output)), err
}

func (m manager) internalAdminGet(path string) (string, error) {
	const script = `const path=process.argv[1];const token=process.env.LOOM_ADMIN_TOKEN;if(!token){console.error('admin token missing in container');process.exit(2)}fetch('http://127.0.0.1:7483'+path,{signal:AbortSignal.timeout(5000),headers:{authorization:'Bearer '+token}}).then(async r=>{const body=await r.text();if(!r.ok){console.error(body);process.exit(3)}console.log(body)}).catch(e=>{console.error(e.message);process.exit(4)})`
	return probeOutput("docker", m.composeArgs("exec", "-T", "loom-node", "node", "-e", script, path)...)
}

func (m manager) readDiagnostics() (*nodeDiagnostics, error) {
	output, err := m.internalAdminGet("/admin/v1/diagnostics")
	if err != nil {
		return nil, fmt.Errorf("node diagnostics probe failed: %w: %s", err, output)
	}
	var diagnostics nodeDiagnostics
	if err := json.Unmarshal([]byte(output), &diagnostics); err != nil {
		return nil, fmt.Errorf("invalid diagnostics JSON: %w", err)
	}
	return &diagnostics, nil
}

func (m manager) readPendingRegistrations() ([]registrationRequest, error) {
	output, err := m.internalAdminGet("/admin/v1/registrations?status=pending&limit=100")
	if err != nil {
		return nil, fmt.Errorf("registration list failed: %w: %s", err, output)
	}
	var payload struct {
		Requests []registrationRequest `json:"requests"`
	}
	if err := json.Unmarshal([]byte(output), &payload); err != nil {
		return nil, fmt.Errorf("invalid registration list JSON: %w", err)
	}
	return payload.Requests, nil
}

func (m manager) registrationCommand(requestID, action string) *exec.Cmd {
	const script = `const id=process.argv[1],action=process.argv[2];const token=process.env.LOOM_ADMIN_TOKEN;if(!token){console.error('admin token missing in container');process.exit(2)}if(!/^reg_[0-9a-f-]{36}$/i.test(id)||!['approve','reject'].includes(action)){console.error('invalid registration action');process.exit(2)}fetch('http://127.0.0.1:7483/admin/v1/registrations/'+encodeURIComponent(id)+'/'+action,{method:'POST',headers:{authorization:'Bearer '+token,'content-type':'application/json'},body:'{}'}).then(async r=>{const body=await r.text();if(!r.ok){console.error(body);process.exit(3)}console.log(body)}).catch(e=>{console.error(e.message);process.exit(4)})`
	return exec.Command("docker", m.composeArgs("exec", "-T", "loom-node", "node", "-e", script, requestID, action)...)
}

func probeTCP(host, port string) bool {
	connection, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), 2*time.Second)
	if err != nil {
		return false
	}
	_ = connection.Close()
	return true
}

func probePublic(publicURL string) tlsSnapshot {
	result := tlsSnapshot{}
	parsed, err := url.Parse(publicURL)
	if err != nil || parsed.Hostname() == "" {
		result.Error = "invalid public URL"
		return result
	}
	host := parsed.Hostname()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if addresses, err := net.DefaultResolver.LookupHost(ctx, host); err == nil {
		result.DNS = addresses
	} else {
		result.Error = "DNS: " + err.Error()
	}
	result.Port80 = probeTCP(host, "80")
	result.Port443 = probeTCP(host, "443")

	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Get(strings.TrimRight(publicURL, "/") + "/readyz")
	if err != nil {
		if result.Error == "" {
			result.Error = err.Error()
		}
		return result
	}
	defer response.Body.Close()
	result.Ready = parsed.Scheme == "https" && response.StatusCode == http.StatusOK && response.TLS != nil
	if response.TLS != nil && len(response.TLS.PeerCertificates) > 0 {
		certificate := response.TLS.PeerCertificates[0]
		result.Issuer = certificate.Issuer.CommonName
		result.ExpiresAt = certificate.NotAfter
		result.DaysLeft = int(time.Until(certificate.NotAfter).Hours() / 24)
	}
	if !result.Ready && result.Error == "" {
		result.Error = response.Status
	}
	return result
}

func (m manager) inspectLocal() snapshot {
	s := snapshot{Home: m.home}
	_, composeErr := os.Stat(m.composePath)
	_, envErr := os.Stat(m.envPath)
	s.ConfigPresent = composeErr == nil && envErr == nil

	if _, err := exec.LookPath("docker"); err != nil {
		return s
	}
	s.DockerInstalled = true
	if _, err := probeOutput("docker", "info"); err != nil {
		return s
	}
	s.DockerReady = true
	if _, err := probeOutput("docker", "compose", "version"); err != nil {
		return s
	}
	s.ComposeReady = true
	if !s.ConfigPresent {
		return s
	}

	s.Services, _ = probeOutput("docker", m.composeArgs("ps")...)
	if diagnostics, err := m.readDiagnostics(); err != nil {
		s.DiagnosticError = err.Error()

	} else {
		s.Diagnostics = diagnostics
		if registrations, err := m.readPendingRegistrations(); err != nil {
			s.RegistrationError = err.Error()
		} else {
			s.PendingRegistrations = registrations
		}
	}

	return s
}

func (m manager) inspectTLS() tlsSnapshot {
	publicURL := loadEnv(m.envPath)["LOOM_PUBLIC_BASE_URL"]
	if publicURL == "" { return tlsSnapshot{Error: "Public URL is not configured"} }
	return probePublic(publicURL)
}

func (m manager) inspect() snapshot {
	s := m.inspectLocal()
	s.TLS = m.inspectTLS()
	return s
}
