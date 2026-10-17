package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

type refreshMsg snapshot
type federationStatusMsg struct{ status federationStatus; err error }
type federationQueueMsg struct{ queue federationQueue; err error }
type usersMsg struct{ users []adminUser; err error }
type systemStatsMsg systemStats
type requestUpdateCheckMsg struct{}
type requestUpdateApplyMsg struct{}

type actionMsg struct { name, output string; err error }
type terminalFinishedMsg struct { name string; err error }
type action struct { label, hint, kind string; args []string; dangerous, disabled bool }

const (
	focusSidebar = iota
	focusTable
	focusActions
)

type model struct {
	mgr manager
	snapshot snapshot
	federation federationStatus
	federationError string
	queue federationQueue
	queueError string
	users []adminUser
	usersError string
 groups groupStatus
 groupsError string
 groupsAfter string
 groupsLoading bool
 groupDetail *groupDetail
	system systemStats
	update updateStatus
	page int
	row int
	actionCursor int
	focus int
	width int
	height int
	busy bool
	message string
	groupCallsForm *groupCallsForm
	confirm *action
	help bool
	logService string
	logTail int
}

var pages = []string{
	"Overview", "Services", "Users", "Registration", "Federation", "Federation Queue",
	"Calls", "Groups", "Public page", "Network & TLS", "Database", "Storage", "Security", "Logs", "Backup", "Maintenance", "Updates",
}

var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#F4A28C"))
	dimStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	goodStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("42")).Bold(true)
	warnStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("214")).Bold(true)
	badStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("196")).Bold(true)
	selStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#F4A28C")).Bold(true)
	panelStyle = lipgloss.NewStyle().PaddingLeft(2).PaddingRight(2)
	navStyle = lipgloss.NewStyle().Width(23).PaddingRight(2).BorderRight(true).BorderStyle(lipgloss.NormalBorder()).BorderForeground(lipgloss.Color("238"))
	contentStyle = lipgloss.NewStyle().PaddingLeft(2)
)

func refreshCmd(mgr manager) tea.Cmd { return func() tea.Msg { return refreshMsg(mgr.inspect()) } }
func federationStatusCmd(mgr manager) tea.Cmd { return func() tea.Msg { v, err := mgr.readFederationStatus(); return federationStatusMsg{v, err} } }
func federationQueueCmd(mgr manager) tea.Cmd { return func() tea.Msg { v, err := mgr.readFederationQueue(); return federationQueueMsg{v, err} } }
func usersCmd(mgr manager) tea.Cmd { return func() tea.Msg { v, err := mgr.readAdminUsers(); return usersMsg{v, err} } }
func systemStatsCmd() tea.Cmd { return func() tea.Msg { return systemStatsMsg(readSystemStats()) } }
func refreshAllCmd(mgr manager) tea.Cmd { return tea.Batch(refreshCmd(mgr), federationStatusCmd(mgr), federationQueueCmd(mgr), usersCmd(mgr), groupsCmd(mgr,""), systemStatsCmd()) }
func actionCmd(mgr manager, name string, args ...string) tea.Cmd { return func() tea.Msg { out, err := mgr.composeCommand(args...).CombinedOutput(); return actionMsg{name, strings.TrimSpace(string(out)), err} } }
func registrationActionCmd(mgr manager, name, requestID, operation string) tea.Cmd { return func() tea.Msg { out, err := mgr.registrationCommand(requestID, operation).CombinedOutput(); return actionMsg{name, strings.TrimSpace(string(out)), err} } }
func settingActionCmd(mgr manager, name, key, value string) tea.Cmd { return func() tea.Msg { out, err := mgr.setRuntimeSetting(key, value); return actionMsg{name, strings.TrimSpace(out), err} } }
func managerSettingCmd(mgr manager, name, key, value string) tea.Cmd { return func() tea.Msg { out, err := mgr.setManagerSetting(key, value); return actionMsg{name, strings.TrimSpace(out), err} } }
func federationNodeActionCmd(mgr manager, name, nodeID, operation string) tea.Cmd { return func() tea.Msg { out, err := mgr.federationNodeAction(nodeID, operation); return actionMsg{name, strings.TrimSpace(out), err} } }
func queueActionCmd(mgr manager, name, operation, deliveryID string) tea.Cmd { return func() tea.Msg { var out string; var err error; switch operation { case "retry": out, err = mgr.retryFederationDelivery(deliveryID); case "retry-all": out, err = mgr.retryAllFederationFailures(); case "purge": out, err = mgr.purgeFederationDeadLetter(); default: err = fmt.Errorf("unknown queue operation") }; return actionMsg{name, strings.TrimSpace(out), err} } }
func cleanupSessionsCmd(mgr manager) tea.Cmd { return func() tea.Msg { out, err := mgr.cleanupExpiredSessions(); return actionMsg{"Clean expired sessions", out, err} } }
func rotateAdminTokenCmd(mgr manager) tea.Cmd { return func() tea.Msg { out, err := mgr.rotateAdminToken(); return actionMsg{"Rotate admin token", out, err} } }
func logsCmd(mgr manager, service string, tail int) tea.Cmd { return tea.ExecProcess(mgr.logsCommand(service, tail), func(err error) tea.Msg { return terminalFinishedMsg{"Log viewer", err} }) }
func postgresShellCmd(mgr manager) tea.Cmd { return tea.ExecProcess(mgr.postgresShellCommand(), func(err error) tea.Msg { return terminalFinishedMsg{"PostgreSQL console", err} }) }

func initialModel(mgr manager) model { return model{mgr: mgr, focus: focusSidebar, logService: "loom-node", logTail: 200, update: updateStatus{State: "checking", InstalledVersion: version}} }
func (m model) Init() tea.Cmd { return refreshAllCmd(m.mgr) }
func currentRegistration(m model) string { if m.snapshot.Diagnostics == nil { return "" }; return m.snapshot.Diagnostics.Registration.Policy }
func currentFederation(m model) string { if m.federation.Mode != "" { return m.federation.Mode }; if m.snapshot.Diagnostics == nil { return "" }; return m.snapshot.Diagnostics.Federation.Mode }
func currentLAN(m model) bool { return m.snapshot.Diagnostics != nil && m.snapshot.Diagnostics.Network.LANDiscovery }
func settingAction(label, hint, key, value, current string, dangerous bool) action { return action{label: label, hint: hint, kind: "setting", args: []string{key, value}, dangerous: dangerous, disabled: current == value} }

func (m model) selectedNode() *federationNode { if m.row < 0 || m.row >= len(m.federation.Nodes) { return nil }; v := m.federation.Nodes[m.row]; return &v }
func (m model) selectedDelivery() *federationDelivery { if m.row < 0 || m.row >= len(m.queue.Deliveries) { return nil }; v := m.queue.Deliveries[m.row]; return &v }
func (m model) selectedUser() *adminUser { if m.row < 0 || m.row >= len(m.users) { return nil }; v := m.users[m.row]; return &v }
func (m model) selectedRegistration() *registrationRequest { if m.row < 0 || m.row >= len(m.snapshot.PendingRegistrations) { return nil }; v := m.snapshot.PendingRegistrations[m.row]; return &v }

func (m model) actions() []action {
	switch pages[m.page] {
	case "Overview":
		return []action{{label:"Refresh",hint:"refresh diagnostics, federation and network probes",kind:"refresh"}}
	case "Services":
		return []action{
			{label:"Restart Node",hint:"restart only the Loom application container",kind:"compose",args:[]string{"restart","loom-node"},dangerous:true},
			{label:"Node logs",hint:"follow Loom Node logs",kind:"service-logs",args:[]string{"loom-node"}},
			{label:"Restart PostgreSQL",hint:"restart PostgreSQL; persistent volume is preserved",kind:"compose",args:[]string{"restart","postgres"},dangerous:true},
			{label:"PostgreSQL console",hint:"open interactive psql",kind:"db-shell"},
			{label:"Restart MinIO",hint:"restart object storage; persistent volume is preserved",kind:"compose",args:[]string{"restart","minio"},dangerous:true},
			{label:"Restart Caddy",hint:"restart the bundled reverse proxy when its profile is active",kind:"compose",args:[]string{"restart","caddy"},dangerous:true},
		}
	case "Users":
		return []action{{label:"Refresh users",hint:"reload account/device/session counts",kind:"refresh"}}
	case "Registration":
		current := currentRegistration(m)
		a := []action{
			settingAction("Open", "allow immediate account registration", "LOOM_REGISTRATION_POLICY", "open", current, false),
			settingAction("Approval", "queue new accounts for operator review", "LOOM_REGISTRATION_POLICY", "approval", current, false),
			settingAction("Closed", "reject all new registrations", "LOOM_REGISTRATION_POLICY", "closed", current, true),
		}
		if req := m.selectedRegistration(); req != nil {
			a = append(a,
				action{label:"Approve selected",hint:"approve @"+req.Username,kind:"registration",args:[]string{req.RequestID,"approve"},dangerous:true},
				action{label:"Reject selected",hint:"reject @"+req.Username,kind:"registration",args:[]string{req.RequestID,"reject"},dangerous:true},
			)
		}
		return a
	case "Federation":
		current := currentFederation(m)
		a := []action{
			settingAction("Disabled", "disable inbound and outbound federation", "LOOM_FEDERATION_MODE", "disabled", current, true),
			settingAction("Trusted", "discover Nodes automatically; require operator trust", "LOOM_FEDERATION_MODE", "trusted", current, false),
			settingAction("Hybrid", "trusted public Nodes plus local/private Nodes", "LOOM_FEDERATION_MODE", "hybrid", current, false),
			settingAction("Open", "allow any cryptographically valid compatible Node", "LOOM_FEDERATION_MODE", "open", current, false),
			settingAction("Local", "allow only local/private network Nodes", "LOOM_FEDERATION_MODE", "local", current, false),
		}
		if node := m.selectedNode(); node != nil {
			a = append(a, action{label:"Verify",hint:"rediscover and verify "+node.Domain,kind:"node-action",args:[]string{node.NodeID,"verify"}})
			if node.TrustState != "trusted" { a = append(a, action{label:"Trust",hint:"persist operator trust for "+node.Domain,kind:"node-action",args:[]string{node.NodeID,"trust"},dangerous:true}) }
			if node.TrustState != "blocked" { a = append(a, action{label:"Block",hint:"block federation with "+node.Domain,kind:"node-action",args:[]string{node.NodeID,"block"},dangerous:true}) }
			a = append(a, action{label:"Forget",hint:"remove cached discovery record; it may be rediscovered later",kind:"node-action",args:[]string{node.NodeID,"forget"},dangerous:true})
		}
		return a
	case "Federation Queue":
		a := []action{{label:"Refresh queue",hint:"reload pending, retrying and failed deliveries",kind:"refresh"}}
		if d := m.selectedDelivery(); d != nil && d.Status == "failed" { a = append(a, action{label:"Retry selected",hint:"move selected failed delivery back to pending",kind:"queue-action",args:[]string{"retry",d.DeliveryID}}) }
		if m.queue.Summary["failed"] > 0 { a = append(a, action{label:"Retry all failed",hint:"retry every dead-letter delivery",kind:"queue-action",args:[]string{"retry-all",""}}, action{label:"Purge dead-letter",hint:"permanently remove failed delivery records only",kind:"queue-action",args:[]string{"purge",""},dangerous:true}) }
		return a
	case "Calls":
		current, voice, video := "false", "false", "false"
		if d := m.snapshot.Diagnostics; d != nil && d.Calls != nil {
			current = strconv.FormatBool(d.Calls.Enabled)
			voice = strconv.FormatBool(d.Calls.VoiceEnabled)
			video = strconv.FormatBool(d.Calls.VideoEnabled)
		}
		return []action{
			{label:"Set up group calls", hint:"automatic media service, private keys and settings; review before applying", kind:"configure-group-calls"},
            {label:"Disable group calls", hint:"end group calls and stop media service; keep configuration for next time", kind:"disable-group-calls", dangerous:true, disabled:groupCallsEnv(m.mgr.envPath)["LOOM_GROUP_CALLS_ENABLED"]!="true"},
            {label:"Check group media service",hint:"verify Node policy and authenticated private media API; no settings changed",kind:"check-group-calls"},
            {label:"Group media logs",hint:"open recent media service logs",kind:"service-logs",args:[]string{"livekit"}},
            {label:"Set up TURN automatically", hint:"install local relay, generate or preserve its secret, configure and test authentication", kind:"automatic-turn", dangerous:true},
            {label:"Configure TURN", hint:"guided calling setup; secret entry is hidden; confirmation before applying", kind:"configure-calls"},
			settingAction("Enable calls", "requires TURN or configured group media service", "LOOM_CALLS_ENABLED", "true", current, false),
			settingAction("Disable calls", "stop accepting new voice/video calls; Node restart ends active calls", "LOOM_CALLS_ENABLED", "false", current, true),
			settingAction("Allow voice", "enable voice offers", "LOOM_VOICE_CALLS_ENABLED", "true", voice, false),
			settingAction("Disable voice", "reject new voice offers", "LOOM_VOICE_CALLS_ENABLED", "false", voice, true),
			settingAction("Allow video", "enable video offers", "LOOM_VIDEO_CALLS_ENABLED", "true", video, false),
			settingAction("Disable video", "reject video offers and camera upgrades", "LOOM_VIDEO_CALLS_ENABLED", "false", video, true),
		}
	case "Groups":
		return m.groupActions()
	case "Public page":
		return m.publicPageActions()
	case "Network & TLS":
		lan := currentLAN(m)
		return []action{
			{label:"Refresh probes",hint:"DNS, ports, HTTPS and certificate status",kind:"refresh"},
			{label:func() string { if lan { return "LAN Discovery [ ON ]" }; return "LAN Discovery [ OFF ]" }(),hint:"toggle local-network discovery",kind:"setting",args:[]string{"LOOM_LAN_DISCOVERY",map[bool]string{true:"false",false:"true"}[lan]}},
		}
	case "Database":
		return []action{
			{label:"Refresh database",hint:"reload health, latency and row counts",kind:"refresh"},
			{label:"Open psql",hint:"interactive PostgreSQL console",kind:"db-shell"},
			{label:"Clean expired sessions",hint:"delete only sessions beyond refresh lifetime",kind:"cleanup-sessions"},
			{label:"Restart PostgreSQL",hint:"restart database service",kind:"compose",args:[]string{"restart","postgres"},dangerous:true},
		}
	case "Storage":
		return []action{{label:"Verify storage",hint:"refresh MinIO/S3 health and bucket probe",kind:"refresh"},{label:"Restart MinIO",hint:"restart object storage service",kind:"compose",args:[]string{"restart","minio"},dangerous:true}}
	case "Security":
		return []action{{label:"Refresh security",hint:"reload identity, TLS and token readiness",kind:"refresh"},{label:"Rotate admin token",hint:"atomically replace the admin secret and recreate only the Node",kind:"rotate-token",dangerous:true}}
	case "Logs":
		return []action{
			{label:"Source: Node",hint:"Loom application logs",kind:"log-source",args:[]string{"loom-node"},disabled:m.logService=="loom-node"},
			{label:"Source: PostgreSQL",hint:"database logs",kind:"log-source",args:[]string{"postgres"},disabled:m.logService=="postgres"},
			{label:"Source: MinIO",hint:"object storage logs",kind:"log-source",args:[]string{"minio"},disabled:m.logService=="minio"},
			{label:"Source: Caddy",hint:"proxy/TLS logs",kind:"log-source",args:[]string{"caddy"},disabled:m.logService=="caddy"},
			{label:"Source: All",hint:"combined compose logs",kind:"log-source",args:[]string{"all"},disabled:m.logService=="all"},
			{label:"Tail 50",hint:"show last 50 lines before following",kind:"log-tail",args:[]string{"50"},disabled:m.logTail==50},
			{label:"Tail 100",hint:"show last 100 lines before following",kind:"log-tail",args:[]string{"100"},disabled:m.logTail==100},
			{label:"Tail 200",hint:"show last 200 lines before following",kind:"log-tail",args:[]string{"200"},disabled:m.logTail==200},
			{label:"Tail 500",hint:"show last 500 lines before following",kind:"log-tail",args:[]string{"500"},disabled:m.logTail==500},
			{label:"Follow logs",hint:"handoff terminal safely; Esc/Ctrl+C returns to manager",kind:"logs"},
		}
	case "Backup":
		return []action{{label:"Backup unavailable",hint:"safe atomic PostgreSQL + object storage + identity backup is not implemented",disabled:true}}
	case "Maintenance":
		return []action{
			{label:"Pull dependency images",hint:"pull PostgreSQL, MinIO and proxy images",kind:"compose",args:[]string{"pull"},dangerous:true},
			{label:"Rebuild / reconcile",hint:"docker compose up -d --build",kind:"compose",args:[]string{"up","-d","--build"},dangerous:true},
			{label:"Recreate Node",hint:"force-recreate only loom-node",kind:"compose",args:[]string{"up","-d","--no-deps","--force-recreate","loom-node"},dangerous:true},
			{label:"Stop services",hint:"stop stack without deleting volumes",kind:"compose",args:[]string{"stop"},dangerous:true},
		}
	case "Updates":
		a := []action{{label:"Check now",hint:"refresh latest commit now; background checks run every 60 seconds",kind:"update-check"}}
		if m.update.State == "update_available" { a = append(a, action{label:"Install update",hint:"manually validate and install the available commit",kind:"update-apply",dangerous:true}) }
		return a
	}
	return nil
}

func (m model) execute(a action) (tea.Model, tea.Cmd) {
	m.message = ""
	if a.disabled { m.message = "Already selected."; return m, nil }
	switch a.kind {
	case "group-detail": if len(a.args)!=1 { return m,nil }; return m,groupDetailCmd(m.mgr,a.args[0])
 case "group-policy": if len(a.args)!=3 { return m,nil }; m.busy=true; return m,groupPolicyCmd(m.mgr,a)
 case "group-cleanup": m.busy=true; return m,cleanupGroupPackagesCmd(m.mgr)
 case "groups-page": if len(a.args)!=1 { return m,nil }; m.groupsAfter=a.args[0]; m.groupsLoading=true; m.row=0; m.groupDetail=nil; return m,groupsCmd(m.mgr,m.groupsAfter)
 case "refresh": return m, requestStatusRefreshCmd()
	case "check-group-calls": m.busy=true;return m,func()tea.Msg{err:=m.mgr.mediaCommand("verify-group-calls");out:="";if err==nil{out="Private media API reachable. Test calls between two networks to verify media ports."};return actionMsg{"Group media check",out,err}}
    case "configure-group-calls": return m.openGroupCallsForm(),nil
    case "disable-group-calls": values:=groupCallsEnv(m.mgr.envPath);limit,_:=strconv.Atoi(values["LOOM_GROUP_CALLS_MAX_PARTICIPANTS"]);m.busy=true;return m,groupCallsApplyCmd(m.mgr,groupCallsSetup{values["LOOM_GROUP_CALLS_PUBLIC_IP"],limit,values["LOOM_VIDEO_CALLS_ENABLED"]=="true"},false)
	case "automatic-turn": return m, automaticTURNCmd(m.mgr)
	case "configure-calls": return m, callsSetupCmd(m.mgr)
	case "compose": m.busy = true; return m, actionCmd(m.mgr, a.label, a.args...)
	case "setting": if len(a.args)!=2 { return m,nil }; m.busy=true; return m, settingActionCmd(m.mgr,a.label,a.args[0],a.args[1])
	case "manager-setting": if len(a.args)!=2 { return m,nil }; m.busy=true; return m, managerSettingCmd(m.mgr,a.label,a.args[0],a.args[1])
	case "registration": if len(a.args)!=2 { return m,nil }; m.busy=true; return m, registrationActionCmd(m.mgr,a.label,a.args[0],a.args[1])
	case "node-action": if len(a.args)!=2 { return m,nil }; m.busy=true; return m, federationNodeActionCmd(m.mgr,a.label,a.args[0],a.args[1])
	case "queue-action": if len(a.args)!=2 { return m,nil }; m.busy=true; return m, queueActionCmd(m.mgr,a.label,a.args[0],a.args[1])
	case "cleanup-sessions": m.busy=true; return m,cleanupSessionsCmd(m.mgr)
	case "rotate-token": m.busy=true; return m,rotateAdminTokenCmd(m.mgr)
	case "db-shell": return m,postgresShellCmd(m.mgr)
	case "service-logs": if len(a.args)>0 { return m,logsCmd(m.mgr,a.args[0],m.logTail) }; return m,nil
	case "log-source": if len(a.args)>0 { m.logService=a.args[0]; m.message="Log source changed." }; return m,nil
	case "log-tail": if len(a.args)>0 { if n,err:=strconv.Atoi(a.args[0]);err==nil { m.logTail=n; m.message="Log tail changed." } }; return m,nil
	case "logs": return m,logsCmd(m.mgr,m.logService,m.logTail)
	case "update-check": return m,func() tea.Msg{return requestUpdateCheckMsg{}}
	case "update-apply": return m,func() tea.Msg{return requestUpdateApplyMsg{}}
	}
	return m,nil
}

func (m model) runSelected() (tea.Model, tea.Cmd) { a := m.actions(); if m.busy || len(a)==0 || m.actionCursor<0 || m.actionCursor>=len(a){return m,nil}; selected:=a[m.actionCursor]; if selected.disabled{return m.execute(selected)}; if selected.dangerous { m.confirm=&selected; return m,nil }; return m.execute(selected) }
func (m *model) resetPageState(){m.row=0;m.actionCursor=0;m.message="";m.confirm=nil}
func (m model) rowCount() int { switch pages[m.page] { case "Groups": if m.groupsLoading||m.groupsError!="" { return 0 }; return len(m.groups.Groups); case "Users": return len(m.users); case "Registration": return len(m.snapshot.PendingRegistrations); case "Federation": return len(m.federation.Nodes); case "Federation Queue": return len(m.queue.Deliveries) }; return 0 }
func (m model) focusOrder() []int { if m.rowCount()>0 { return []int{focusSidebar,focusTable,focusActions} }; return []int{focusSidebar,focusActions} }
func (m *model) cycleFocus(delta int){order:=m.focusOrder();idx:=0;for i,v:=range order{if v==m.focus{idx=i;break}};m.focus=order[(idx+delta+len(order))%len(order)]}
func (m *model) movePage(delta int){m.page=(m.page+delta+len(pages))%len(pages);m.resetPageState();if m.focus==focusTable&&m.rowCount()==0{m.focus=focusActions}}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg:=msg.(type){
	case tea.WindowSizeMsg: m.width,m.height=msg.Width,msg.Height
    case tea.PasteMsg: if m.groupCallsForm!=nil{return m.updateGroupCallsForm(strings.TrimSpace(msg.Content))}
	case tea.KeyPressMsg:
		key:=msg.String()
        if m.groupCallsForm!=nil{return m.updateGroupCallsForm(key)}
        if m.busy&&(key=="q"||key=="ctrl+c"){m.message="Wait for the current operation to finish.";return m,nil}
		if m.confirm!=nil { switch key { case "y","Y": a:=*m.confirm;m.confirm=nil;return m.execute(a); case "n","N","esc": m.confirm=nil;m.message="Cancelled." }; return m,nil }
		if m.help { if key=="?"||key=="esc"{m.help=false};return m,nil }
		switch key {
		case "q","ctrl+c": return m,tea.Quit
		case "?": m.help=true
		case "tab": m.cycleFocus(1)
		case "shift+tab": m.cycleFocus(-1)
		case "esc": m.focus=focusSidebar;m.message=""
		case "up","k":
			switch m.focus { case focusSidebar: m.movePage(-1); case focusTable: if m.row>0{m.row--};m.actionCursor=0; case focusActions: if m.actionCursor>0{m.actionCursor--} }
		case "down","j":
			switch m.focus { case focusSidebar: m.movePage(1); case focusTable: if m.row<m.rowCount()-1{m.row++};m.actionCursor=0; case focusActions: if m.actionCursor<len(m.actions())-1{m.actionCursor++} }
		case "enter"," ":
			if m.focus==focusSidebar { if m.rowCount()>0{m.focus=focusTable}else{m.focus=focusActions};return m,nil }
			if m.focus==focusTable { m.focus=focusActions;return m,nil }
			return m.runSelected()
		case "r": return m,requestStatusRefreshCmd()
		}
	case groupCallsAppliedMsg: m.busy=false; if msg.err!=nil{if m.groupCallsForm!=nil{m.groupCallsForm.err=msg.err.Error()};m.message=msg.err.Error();return m,nil};m.groupCallsForm=nil;m.message="Group calling disabled; configuration preserved.";if msg.enabled{m.message="Group calling enabled; private media API verified. Test with two devices on different networks."};return m,requestStatusRefreshCmd()
	case refreshMsg: m.snapshot=snapshot(msg);if m.row>=m.rowCount(){m.row=0};m.message="Status refreshed."
	case federationStatusMsg: if msg.err!=nil{m.federationError=msg.err.Error()}else{m.federation=msg.status;m.federationError=""};if pages[m.page]=="Federation"&&m.row>=len(m.federation.Nodes){m.row=0}
	case federationQueueMsg: if msg.err!=nil{m.queueError=msg.err.Error()}else{m.queue=msg.queue;m.queueError=""};if pages[m.page]=="Federation Queue"&&m.row>=len(m.queue.Deliveries){m.row=0}
 case groupsMsg:
  if msg.after!=m.groupsAfter { return m,nil }
  m.groupsLoading=false
  selected:=m.selectedRowID()
  if msg.err!=nil { m.groupsError=msg.err.Error() } else { m.groups=msg.status; m.groupsError="" }
  if pages[m.page]=="Groups" { m.restoreSelectedRow(selected); if m.row>=m.rowCount(){m.row=0}; if m.rowCount()==0&&m.focus==focusTable { m.focus=focusActions }; if g:=m.selectedGroup(); g!=nil&&m.groupDetail!=nil&&m.groupDetail.ID==g.ID&&m.groupDetail.Revision!=g.Revision {m.groupDetail=nil} }
  m.actionCursor=min(m.actionCursor,max(0,len(m.actions())-1))
 case groupDetailMsg:
  if msg.err!=nil { m.message="Group details unavailable." } else if msg.detail.ID==msg.id { m.groupDetail=&msg.detail }
 case usersMsg: if msg.err!=nil{m.usersError=msg.err.Error()}else{m.users=msg.users;m.usersError=""};if pages[m.page]=="Users"&&m.row>=len(m.users){m.row=0}
	case systemStatsMsg: m.system=systemStats(msg)
	case actionMsg: m.busy=false;if msg.err!=nil{m.message=fmt.Sprintf("%s failed: %v",msg.name,msg.err);if strings.TrimSpace(msg.output)!=""{m.message+="\n"+strings.TrimSpace(msg.output)}}else{m.message=msg.name+" completed.";if strings.TrimSpace(msg.output)!=""{m.message+="\n"+strings.TrimSpace(msg.output)}};return m,requestStatusRefreshCmd()
	case terminalFinishedMsg: if msg.err!=nil{m.message=msg.name+" exited with error: "+msg.err.Error()}else{m.message=msg.name+" closed."};return m,requestStatusRefreshCmd()
	}
	return m,nil
}

func status(value bool,yes,no string)string{if value{return goodStyle.Render("● "+yes)};return badStyle.Render("● "+no)}
func featureStatus(value bool,yes,no string)string{if value{return goodStyle.Render("● "+yes)};return warnStyle.Render("○ "+no)}
func metric(stats map[string]float64,key string)string{if stats==nil{return "—"};v,ok:=stats[key];if !ok{return "—"};return fmt.Sprintf("%.0f",v)}
func formatUptime(seconds int64)string{if seconds<=0{return "—"};d:=time.Duration(seconds)*time.Second;days:=int(d/(24*time.Hour));hours:=int((d%(24*time.Hour))/time.Hour);minutes:=int((d%time.Hour)/time.Minute);if days>0{return fmt.Sprintf("%dd %02dh %02dm",days,hours,minutes)};return fmt.Sprintf("%dh %02dm",hours,minutes)}
func formatBytes(v uint64)string{if v==0{return "—"};units:=[]string{"B","KiB","MiB","GiB","TiB"};f:=float64(v);i:=0;for f>=1024&&i<len(units)-1{f/=1024;i++};return fmt.Sprintf("%.1f %s",f,units[i])}
func fact(label,value string)string{return dimStyle.Render(fmt.Sprintf("%-22s",label))+" "+value+"\n"}
func section(name string)string{return "\n"+titleStyle.Render(name)+"\n"}
func selector(values []string,current string)string{parts:=make([]string,0,len(values));for _,v:=range values{label:="[ "+v+" ]";if strings.EqualFold(v,current){label=selStyle.Render(" "+v+" ")};parts=append(parts,label)};return strings.Join(parts," ")}
func truncated(value string,n int)string{value=strings.ReplaceAll(strings.TrimSpace(value),"\n"," ");runes:=[]rune(value);if n<=0{return ""};if len(runes)<=n{return value};if n<2{return string(runes[:n])};return string(runes[:n-1])+"…"}

func (m model) navView() string { var b strings.Builder;b.WriteString(titleStyle.Render("Sections")+"\n\n");for i,p:=range pages{prefix:="  ";label:=p;if i==m.page{prefix="> ";if m.focus==focusSidebar{label=selStyle.Render(p)}else{label=titleStyle.Render(p)}};b.WriteString(prefix+label+"\n")};return navStyle.Render(b.String()) }
func (m model) header() string {focus:=map[int]string{focusSidebar:"sidebar",focusTable:"table",focusActions:"actions"}[m.focus];return titleStyle.Render("Loom Node Manager")+dimStyle.Render("  v"+version+"  •  dark operations console  •  focus: "+focus)+"\n"+dimStyle.Render(m.mgr.home)+"\n\n"}

func (m model) overviewView() string {var b strings.Builder;b.WriteString(titleStyle.Render("Overview"));if m.snapshot.Diagnostics==nil{b.WriteString("\n\n"+status(m.snapshot.DockerReady,"DOCKER READY","DOCKER UNAVAILABLE")+"  "+status(m.snapshot.ComposeReady,"COMPOSE READY","COMPOSE MISSING"));if m.snapshot.DiagnosticError!=""{b.WriteString("\n\n"+badStyle.Render("Node diagnostics unavailable")+"\n"+dimStyle.Render(m.snapshot.DiagnosticError))};return b.String()};d:=m.snapshot.Diagnostics;b.WriteString(section("NODE"));b.WriteString(fact("Name",d.Node.Name));b.WriteString(fact("Domain",d.Node.Domain));b.WriteString(fact("Node ID",truncated(d.Node.NodeID,54)));b.WriteString(fact("Version",d.Node.ServerVersion));b.WriteString(fact("Uptime",formatUptime(d.Runtime.UptimeSeconds)));b.WriteString(fact("Federation mode",currentFederation(m)));b.WriteString(section("SYSTEM"));b.WriteString(fact("CPU",fmt.Sprintf("%d logical CPUs",m.system.CPUs)));b.WriteString(fact("Memory",formatBytes(m.system.MemoryUsed)+" / "+formatBytes(m.system.MemoryTotal)));b.WriteString(fact("Disk /",formatBytes(m.system.DiskUsed)+" / "+formatBytes(m.system.DiskTotal)));b.WriteString(fact("Load average",firstNonEmpty(m.system.LoadAverage,"—")));b.WriteString(section("SERVICES"));b.WriteString(fact("Node readiness",status(d.Ready,"HEALTHY","DEGRADED")));b.WriteString(fact("PostgreSQL",status(d.Storage.Database.Ready,"HEALTHY","DOWN")));b.WriteString(fact("Object storage",status(d.Storage.Attachments.Ready,"HEALTHY","DOWN")));b.WriteString(fact("Public HTTPS",status(m.snapshot.TLS.Ready,"VALID","UNVERIFIED")));b.WriteString(section("USERS / MESSAGING"));b.WriteString(fact("Registered accounts",metric(d.Storage.Database.Stats,"accounts")));b.WriteString(fact("Devices",metric(d.Storage.Database.Stats,"devices")));b.WriteString(fact("Pending registrations",fmt.Sprintf("%d",d.Registration.PendingRequests)));b.WriteString(fact("Conversations",metric(d.Storage.Database.Stats,"conversations")));b.WriteString(fact("Messages",metric(d.Storage.Database.Stats,"messages")));b.WriteString(section("FEDERATION"));b.WriteString(fact("Discovered Nodes",fmt.Sprintf("%d",m.federation.DiscoveredNodes)));b.WriteString(fact("Healthy Nodes",fmt.Sprintf("%d",m.federation.HealthyNodes)));b.WriteString(fact("Pending deliveries",fmt.Sprintf("%d",m.federation.PendingOutboundDeliveries)));b.WriteString(fact("Failed deliveries",fmt.Sprintf("%d",m.federation.FailedDeliveries)));b.WriteString(section("NETWORK"));b.WriteString(fact("Public URL",d.Network.PublicBaseURL));b.WriteString(fact("TLS expiry",func()string{if m.snapshot.TLS.ExpiresAt.IsZero(){return "—"};return m.snapshot.TLS.ExpiresAt.Format("2006-01-02") }()));b.WriteString(fact("DNS",func()string{if len(m.snapshot.TLS.DNS)==0{return "—"};return strings.Join(m.snapshot.TLS.DNS,", ")}()));return b.String()}
func (m model) servicesView()string{var b strings.Builder;b.WriteString(titleStyle.Render("Services")+"\n\n");b.WriteString(fact("Docker",status(m.snapshot.DockerReady,"READY","UNAVAILABLE")));b.WriteString(fact("Compose",status(m.snapshot.ComposeReady,"READY","MISSING")));b.WriteString("\n"+titleStyle.Render("docker compose ps")+"\n");if strings.TrimSpace(m.snapshot.Services)==""{b.WriteString(dimStyle.Render("No service status available."))}else{b.WriteString(m.snapshot.Services)};return b.String()}
func (m model) usersView()string{var b strings.Builder;b.WriteString(titleStyle.Render("Users")+"\n\n");domain:="";if m.snapshot.Diagnostics!=nil{domain=m.snapshot.Diagnostics.Node.Domain};if len(m.users)==0{b.WriteString(dimStyle.Render("No users available."))}else{b.WriteString(dimStyle.Render("   Address                              Display name             Devices Sessions")+"\n");for i,u:=range m.users{mark:="  ";if i==m.row{mark="> ";};address:="@"+u.Username+":"+domain;line:=fmt.Sprintf("%s%-36s %-24s %7d %8d",mark,truncated(address,35),truncated(u.DisplayName,23),u.DeviceCount,u.ActiveSessionCount);if i==m.row&&m.focus==focusTable{line=selStyle.Render(line)};b.WriteString(line+"\n")}};if m.usersError!=""{b.WriteString("\n"+badStyle.Render("Users probe failed")+"\n"+dimStyle.Render(m.usersError))};return b.String()}
func (m model) registrationView()string{var b strings.Builder;b.WriteString(titleStyle.Render("Registration")+"\n\n");current:=currentRegistration(m);b.WriteString("Policy: "+selector([]string{"Open","Approval","Closed"},current)+"\n");if m.snapshot.Diagnostics!=nil{r:=m.snapshot.Diagnostics.Registration;b.WriteString(fact("Pending",fmt.Sprintf("%d",r.PendingRequests)));b.WriteString(fact("Accepting",fmt.Sprintf("%t",r.AcceptingRegistrations)))};b.WriteString("\n"+titleStyle.Render("Pending requests")+"\n");if len(m.snapshot.PendingRegistrations)==0{b.WriteString(dimStyle.Render("No pending registration requests."))}else{b.WriteString(dimStyle.Render("   Username             Display name             Device              Fingerprint")+"\n");for i,r:=range m.snapshot.PendingRegistrations{mark:="  ";if i==m.row{mark="> "};line:=fmt.Sprintf("%s%-20s %-24s %-19s %s",mark,"@"+r.Username,truncated(r.DisplayName,23),truncated(r.DeviceName,18),truncated(r.IdentityFingerprint,24));if i==m.row&&m.focus==focusTable{line=selStyle.Render(line)};b.WriteString(line+"\n")}};return b.String()}
func (m model) federationView()string{var b strings.Builder;b.WriteString(titleStyle.Render("Federation")+"\n\n");b.WriteString("Mode: "+selector([]string{"Disabled","Trusted","Hybrid","Open","Local"},currentFederation(m))+"\n\n");b.WriteString(featureStatus(m.federation.Enabled,"Federation running","Federation disabled")+"   "+featureStatus(m.snapshot.Diagnostics!=nil&&m.snapshot.Diagnostics.Federation.DiscoveryReady,"Discovery ready","Discovery unavailable")+"   "+featureStatus(m.snapshot.Diagnostics!=nil&&m.snapshot.Diagnostics.Federation.RoutingReady,"Routing ready","Routing unavailable")+"\n");b.WriteString(fact("Discovered / trusted / blocked",fmt.Sprintf("%d / %d / %d",m.federation.DiscoveredNodes,m.federation.TrustedNodes,m.federation.BlockedNodes)));b.WriteString(fact("Healthy / unreachable",fmt.Sprintf("%d / %d",m.federation.HealthyNodes,m.federation.UnreachableNodes)));b.WriteString("\n"+titleStyle.Render("Remote Nodes")+"\n");if len(m.federation.Nodes)==0{b.WriteString(dimStyle.Render("No Nodes discovered yet. Discovery happens automatically when an address needs a remote domain."))}else{b.WriteString(dimStyle.Render("   Domain                              Trust       Health       Latency  Fail")+"\n");for i,n:=range m.federation.Nodes{mark:="  ";if i==m.row{mark="> "};latency:="—";if n.LatencyMS!=nil{latency=fmt.Sprintf("%dms",*n.LatencyMS)};line:=fmt.Sprintf("%s%-36s %-11s %-12s %7s %5d",mark,truncated(n.Domain,35),n.TrustState,n.Health,latency,n.RecentFailures);if i==m.row&&m.focus==focusTable{line=selStyle.Render(line)};b.WriteString(line+"\n")}};if m.federationError!=""{b.WriteString("\n"+badStyle.Render("Federation probe failed")+"\n"+dimStyle.Render(m.federationError))};return b.String()}
func (m model) queueView()string{var b strings.Builder;b.WriteString(titleStyle.Render("Federation Queue")+"\n\n");b.WriteString(fact("Pending",fmt.Sprintf("%d",m.queue.Summary["pending"])));b.WriteString(fact("Retrying",fmt.Sprintf("%d",m.queue.Summary["retrying"])));b.WriteString(fact("Failed / dead-letter",fmt.Sprintf("%d",m.queue.Summary["failed"])));b.WriteString(fact("Delivered",fmt.Sprintf("%d",m.queue.Summary["delivered"])));b.WriteString("\n"+titleStyle.Render("Recent deliveries")+"\n");if len(m.queue.Deliveries)==0{b.WriteString(dimStyle.Render("Queue is empty."))}else{b.WriteString(dimStyle.Render("   Destination                         Event               Try  State       Next retry")+"\n");for i,d:=range m.queue.Deliveries{mark:="  ";if i==m.row{mark="> "};line:=fmt.Sprintf("%s%-36s %-19s %3d  %-10s %s",mark,truncated(d.DestinationDomain,35),truncated(d.EventID,18),d.Attempts,d.Status,truncated(d.NextAttemptAt,19));if i==m.row&&m.focus==focusTable{line=selStyle.Render(line)};b.WriteString(line+"\n")};if d:=m.selectedDelivery();d!=nil&&d.LastError!=""{b.WriteString("\n"+warnStyle.Render("Selected error")+"\n"+dimStyle.Render(truncated(d.LastError,300)))}};if m.queueError!=""{b.WriteString("\n"+badStyle.Render("Queue probe failed")+"\n"+dimStyle.Render(m.queueError))};return b.String()}
func (m model) networkView()string{var b strings.Builder;b.WriteString(titleStyle.Render("Network & TLS")+"\n\n");if m.snapshot.Diagnostics!=nil{d:=m.snapshot.Diagnostics;b.WriteString(fact("Public domain",d.Network.PublicDomain));b.WriteString(fact("Public URL",d.Network.PublicBaseURL));b.WriteString(fact("LAN discovery",featureStatus(d.Network.LANDiscovery,"ON","OFF")))};dns:="—";if len(m.snapshot.TLS.DNS)>0{dns=strings.Join(m.snapshot.TLS.DNS,", ")};b.WriteString(fact("DNS",dns));b.WriteString(fact("TCP 80",status(m.snapshot.TLS.Port80,"REACHABLE","UNREACHABLE")));b.WriteString(fact("TCP 443",status(m.snapshot.TLS.Port443,"REACHABLE","UNREACHABLE")));b.WriteString(fact("HTTPS",status(m.snapshot.TLS.Ready,"VALID","UNVERIFIED")));if !m.snapshot.TLS.ExpiresAt.IsZero(){b.WriteString(fact("Certificate issuer",m.snapshot.TLS.Issuer));b.WriteString(fact("Expiry",m.snapshot.TLS.ExpiresAt.Format(time.RFC3339)));b.WriteString(fact("Days remaining",fmt.Sprintf("%d",m.snapshot.TLS.DaysLeft)))};if m.snapshot.TLS.Error!=""{b.WriteString("\n"+dimStyle.Render(m.snapshot.TLS.Error))};return b.String()}
func (m model) databaseView()string{var b strings.Builder;b.WriteString(titleStyle.Render("Database")+"\n\n");if m.snapshot.Diagnostics==nil{return b.String()+dimStyle.Render("Diagnostics unavailable.")};d:=m.snapshot.Diagnostics.Storage.Database;b.WriteString(fact("PostgreSQL",status(d.Ready,"HEALTHY","FAILED")));b.WriteString(fact("Latency",fmt.Sprintf("%d ms",d.LatencyMS)));for _,key:=range []string{"accounts","devices","sessions","conversations","messages","events"}{b.WriteString(fact(strings.Title(key),metric(d.Stats,key)))};b.WriteString(fact("Federation outbox pending",fmt.Sprintf("%d",m.federation.PendingOutboundDeliveries)));b.WriteString(fact("Federation outbox retrying",fmt.Sprintf("%d",m.federation.RetryingDeliveries)));b.WriteString(fact("Federation outbox failed",fmt.Sprintf("%d",m.federation.FailedDeliveries)));b.WriteString(fact("Federation received total",fmt.Sprintf("%d",m.federation.ReceivedEventsTotal)));return b.String()}
func (m model) storageView()string{var b strings.Builder;b.WriteString(titleStyle.Render("Storage")+"\n\n");if m.snapshot.Diagnostics==nil{return b.String()+dimStyle.Render("Diagnostics unavailable.")};a:=m.snapshot.Diagnostics.Storage.Attachments;b.WriteString(fact("Backend",a.Backend));b.WriteString(fact("Health",status(a.Ready,"HEALTHY","FAILED")));b.WriteString(fact("Latency",fmt.Sprintf("%d ms",a.LatencyMS)));if a.Bucket!=""{b.WriteString(fact("Bucket",a.Bucket))};if a.Detail!=""{b.WriteString(fact("Detail",a.Detail))};return b.String()}
func (m model) securityView()string{var b strings.Builder;b.WriteString(titleStyle.Render("Security")+"\n\n");if m.snapshot.Diagnostics==nil{return b.String()+dimStyle.Render("Diagnostics unavailable.")};d:=m.snapshot.Diagnostics;b.WriteString(fact("Node identity",status(d.Security.NodeIdentityReady,"READY","FAILED")));b.WriteString(fact("Fingerprint",d.Security.NodeFingerprint));b.WriteString(fact("Admin token",status(d.Security.AdminTokenConfigured,"CONFIGURED","INVALID")));b.WriteString(fact("TLS",status(m.snapshot.TLS.Ready,"VALID","UNVERIFIED")));b.WriteString(fact("Signature failures",fmt.Sprintf("%d",m.federation.SignatureFailures)));b.WriteString(fact("Duplicate events rejected",fmt.Sprintf("%d",m.federation.DuplicateEventsRejected)));b.WriteString("\n"+dimStyle.Render("Secrets, passwords, session tokens and private Node keys are never displayed."));return b.String()}
func (m model) logsView()string{return titleStyle.Render("Logs")+"\n\n"+fact("Source",m.logService)+fact("Tail",fmt.Sprintf("%d lines",m.logTail))+"\n"+dimStyle.Render("Choose source/tail as lightweight controls, then Follow logs. Terminal handoff returns safely to the dashboard.")}
func (m model) backupView()string{return titleStyle.Render("Backup")+"\n\n"+warnStyle.Render("Disabled until atomic backup/restore exists")+"\n\n"+dimStyle.Render("A valid backup must cover PostgreSQL, object storage and the Node identity together. The console refuses partial fake-safety backups.")}
func (m model) maintenanceView()string{return titleStyle.Render("Maintenance")+"\n\n"+warnStyle.Render("Disruptive operations")+"\n\n"+dimStyle.Render("Rebuild, recreate, image pulls and service stops require explicit confirmation. Persistent volumes are not removed by these controls.")}
func (m model) updatesView()string{var b strings.Builder;b.WriteString(titleStyle.Render("Updates")+"\n\n");state:=m.update.State;if state=="up_to_date"{state="Latest version installed"};if state=="update_available"{state="New update available"};if state=="unavailable"&&m.update.Detail!=""{state="Update check unavailable"};b.WriteString(fact("State",state));b.WriteString(fact("Installed commit",shortCommit(m.update.InstalledCommit)));if m.update.AvailableCommit!=""{b.WriteString(fact("Latest commit",shortCommit(m.update.AvailableCommit)))};b.WriteString(fact("Repository",m.update.Repository));b.WriteString(fact("Branch",m.update.Branch));b.WriteString(fact("Installation","Install update (explicit action)"));if m.update.Detail!=""{b.WriteString("\n"+dimStyle.Render(m.update.Detail))};b.WriteString("\n\n"+dimStyle.Render("Update status refreshes automatically every 60 seconds by comparing commit SHAs. Installation requires an explicit Install update action."));return b.String()}
func (m model) pageView()string{switch pages[m.page]{case"Overview":return m.overviewView();case"Services":return m.servicesView();case"Users":return m.usersView();case"Registration":return m.registrationView();case"Federation":return m.federationView();case"Federation Queue":return m.queueView();case"Calls":return m.callsView();case"Groups":return m.groupsView();case"Public page":return m.publicPageView();case"Network & TLS":return m.networkView();case"Database":return m.databaseView();case"Storage":return m.storageView();case"Security":return m.securityView();case"Logs":return m.logsView();case"Backup":return m.backupView();case"Maintenance":return m.maintenanceView();case"Updates":return m.updatesView()};return""}
func (m model) actionsView()string{actions:=m.actions();if len(actions)==0{return""};var b strings.Builder;b.WriteString("\n\n"+titleStyle.Render("Contextual controls")+"\n");for i,a:=range actions{prefix:="  ";label:="[ "+a.label+" ]";if a.disabled{label=dimStyle.Render("[ "+a.label+" ]")};if i==m.actionCursor{prefix="> ";if m.focus==focusActions&&!a.disabled{label=selStyle.Render(" "+a.label+" ")}};fmt.Fprintf(&b,"%s%s\n  %s\n",prefix,label,dimStyle.Render(a.hint))};return b.String()}
func (m model) helpView()string{return titleStyle.Render("Keyboard help")+"\n\n↑/↓  move inside the focused panel\nTab / Shift+Tab  switch sidebar, table and controls\nEnter  open section / move to controls / activate selected control\nEsc  return focus to sidebar or close modal\nr  refresh all operational data\n?  toggle this help\nq  quit\n\n"+dimStyle.Render("Destructive controls require y/n confirmation. Harmless switches do not.")}
func (m model) View()tea.View{content:=m.pageView()+m.actionsView();contentWidth:=m.width-34;if contentWidth<72{contentWidth=72};body:=lipgloss.JoinHorizontal(lipgloss.Top,m.navView(),contentStyle.Width(contentWidth).Render(content));var b strings.Builder;b.WriteString(panelStyle.Render(m.header()+body));if m.help{b.WriteString("\n\n"+contentStyle.Width(min(contentWidth,82)).Render(m.helpView()))}else if m.confirm!=nil{b.WriteString("\n\n"+warnStyle.Render("Confirm destructive action")+"\n"+titleStyle.Render(m.confirm.label)+"\n"+dimStyle.Render(m.confirm.hint)+"\n"+warnStyle.Render("[y] confirm   [n/Esc] cancel"))}else if m.busy{b.WriteString("\n\n"+warnStyle.Render("Working…"))}else if strings.TrimSpace(m.message)!=""{b.WriteString("\n\n"+m.message)};b.WriteString("\n\n"+dimStyle.Render("↑/↓ move  •  Tab/Shift+Tab focus  •  Enter open/activate  •  Esc back  •  r refresh  •  ? help  •  q quit"));v:=tea.NewView(b.String());v.AltScreen=true;return v}

