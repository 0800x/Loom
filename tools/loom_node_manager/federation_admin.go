package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

type federationNode struct {
	Domain           string `json:"domain"`
	NodeID           string `json:"nodeId"`
	Fingerprint      string `json:"fingerprint"`
	TrustState       string `json:"trustState"`
	Health           string `json:"health"`
	LastVerification string `json:"lastVerification"`
	LastContact      string `json:"lastContact"`
	LatencyMS        *int64 `json:"latencyMs"`
	RecentFailures   int    `json:"recentFailures"`
}

type federationStatus struct {
	InFlightDeliveries int `json:"inFlightDeliveries"`
	LastWorkerError string `json:"lastWorkerError"`
	Mode                      string           `json:"mode"`
	Enabled                   bool             `json:"enabled"`
	DiscoveredNodes           int              `json:"discoveredNodes"`
	TrustedNodes              int              `json:"trustedNodes"`
	BlockedNodes              int              `json:"blockedNodes"`
	HealthyNodes              int              `json:"healthyNodes"`
	UnreachableNodes          int              `json:"unreachableNodes"`
	PendingOutboundDeliveries int              `json:"pendingOutboundDeliveries"`
	RetryingDeliveries        int              `json:"retryingDeliveries"`
	FailedDeliveries          int              `json:"failedDeliveries"`
	DeliveredEventsTotal      int64            `json:"deliveredEventsTotal"`
	ReceivedEventsTotal       int64            `json:"receivedEventsTotal"`
	DuplicateEventsRejected   int64            `json:"duplicateEventsRejected"`
	SignatureFailures         int64            `json:"signatureFailures"`
	LastFederationSuccess     string           `json:"lastFederationSuccess"`
	LastFederationError       string           `json:"lastFederationError"`
	Nodes                     []federationNode `json:"nodes"`
}

type federationDelivery struct {
	DeliveryID        string `json:"deliveryId"`
	EventID           string `json:"eventId"`
	DestinationNodeID string `json:"destinationNodeId"`
	DestinationDomain string `json:"destinationDomain"`
	Attempts          int    `json:"attempts"`
	Status            string `json:"status"`
	NextAttemptAt     string `json:"nextAttemptAt"`
	CreatedAt         string `json:"createdAt"`
	DeliveredAt       string `json:"deliveredAt"`
	LastError         string `json:"lastError"`
}

type federationQueue struct {
	Deliveries []federationDelivery `json:"deliveries"`
	Summary    map[string]int        `json:"summary"`
}

type adminUser struct {
	AccountID          string `json:"accountId"`
	Username           string `json:"username"`
	DisplayName        string `json:"displayName"`
	CreatedAt          string `json:"createdAt"`
	DeviceCount        int    `json:"deviceCount"`
	ActiveSessionCount int    `json:"activeSessionCount"`
}

func (m manager) internalAdminRequest(method, path string, body any) (string, error) {
	method = strings.ToUpper(strings.TrimSpace(method))
	if method != "GET" && method != "POST" && method != "DELETE" {
		return "", fmt.Errorf("unsupported admin method")
	}
	if !strings.HasPrefix(path, "/admin/v1/") || strings.ContainsAny(path, "\r\n") {
		return "", fmt.Errorf("invalid admin path")
	}
	bodyText := ""
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return "", err
		}
		bodyText = string(encoded)
	}
	const script = `const method=process.argv[1],path=process.argv[2],body=process.argv[3]||'';const token=process.env.LOOM_ADMIN_TOKEN;if(!token){console.error('admin token missing in container');process.exit(2)}const headers={authorization:'Bearer '+token,accept:'application/json'};if(body)headers['content-type']='application/json';fetch('http://127.0.0.1:7483'+path,{method,headers,body:body||undefined}).then(async r=>{const text=await r.text();if(!r.ok){console.error(text||('HTTP '+r.status));process.exit(3)}console.log(text)}).catch(e=>{console.error(e.message);process.exit(4)})`
	return commandOutput("docker", m.composeArgs("exec", "-T", "loom-node", "node", "-e", script, method, path, bodyText)...)
}

func (m manager) readFederationStatus() (federationStatus, error) {
	var status federationStatus
	output, err := m.internalAdminRequest("GET", "/admin/v1/federation/status", nil)
	if err != nil {
		return status, fmt.Errorf("federation status failed: %w: %s", err, output)
	}
	if err := json.Unmarshal([]byte(output), &status); err != nil {
		return status, fmt.Errorf("invalid federation status: %w", err)
	}
	return status, nil
}

func (m manager) readFederationQueue() (federationQueue, error) {
	var queue federationQueue
	output, err := m.internalAdminRequest("GET", "/admin/v1/federation/queue?limit=200", nil)
	if err != nil {
		return queue, fmt.Errorf("federation queue failed: %w: %s", err, output)
	}
	if err := json.Unmarshal([]byte(output), &queue); err != nil {
		return queue, fmt.Errorf("invalid federation queue: %w", err)
	}
	if queue.Summary == nil {
		queue.Summary = map[string]int{}
	}
	return queue, nil
}

func (m manager) readAdminUsers() ([]adminUser, error) {
	output, err := m.internalAdminRequest("GET", "/admin/v1/users?limit=500", nil)
	if err != nil {
		return nil, fmt.Errorf("users list failed: %w: %s", err, output)
	}
	var payload struct {
		Users []adminUser `json:"users"`
	}
	if err := json.Unmarshal([]byte(output), &payload); err != nil {
		return nil, fmt.Errorf("invalid users list: %w", err)
	}
	return payload.Users, nil
}

func (m manager) federationNodeAction(nodeID, action string) (string, error) {
	if strings.TrimSpace(nodeID) == "" || strings.ContainsAny(nodeID, "/\r\n") {
		return "", fmt.Errorf("invalid node ID")
	}
	switch action {
	case "trust", "block", "verify", "probe":
		return m.internalAdminRequest("POST", "/admin/v1/federation/nodes/"+nodeID+"/"+action, nil)
	case "forget":
		return m.internalAdminRequest("DELETE", "/admin/v1/federation/nodes/"+nodeID, nil)
	default:
		return "", fmt.Errorf("unsupported federation action")
	}
}

func (m manager) retryFederationDelivery(deliveryID string) (string, error) {
	if strings.TrimSpace(deliveryID) == "" || strings.ContainsAny(deliveryID, "/\r\n") {
		return "", fmt.Errorf("invalid delivery ID")
	}
	return m.internalAdminRequest("POST", "/admin/v1/federation/queue/"+deliveryID+"/retry", nil)
}

func (m manager) retryAllFederationFailures() (string, error) {
	return m.internalAdminRequest("POST", "/admin/v1/federation/queue/retry-failed", nil)
}

func (m manager) purgeFederationDeadLetter() (string, error) {
	return m.internalAdminRequest("DELETE", "/admin/v1/federation/queue/dead-letter", nil)
}

func (m manager) revokeUserSessions(accountID string) (string, error) {
	if strings.TrimSpace(accountID) == "" || strings.ContainsAny(accountID, "/\r\n") {
		return "", fmt.Errorf("invalid account ID")
	}
	return m.internalAdminRequest("POST", "/admin/v1/users/"+accountID+"/revoke-sessions", nil)
}

func (m manager) logsCommand(service string, tail int) *exec.Cmd {
	if tail != 50 && tail != 100 && tail != 200 && tail != 500 {
		tail = 200
	}
	args := []string{"logs", "-f", "--tail", strconv.Itoa(tail)}
	if service != "" && service != "all" {
		args = append(args, service)
	}
	return m.composeCommand(args...)
}

func (m manager) setManagerSetting(key, value string) (string, error) {
	if key != "LOOM_AUTO_UPDATE" || (value != "true" && value != "false") {
		return "", fmt.Errorf("unsupported manager setting")
	}
	original, err := os.ReadFile(m.envPath)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(m.envPath)
	if err != nil {
		return "", err
	}
	if loadEnv(m.envPath)[key] == value {
		return key + " is already " + value, nil
	}
	if err := writeFileAtomic(m.envPath, []byte(replaceEnvSetting(string(original), key, value)), info.Mode()); err != nil {
		return "", err
	}
	return key + "=" + value, nil
}
