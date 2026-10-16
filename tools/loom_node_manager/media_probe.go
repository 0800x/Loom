package main

import "strings"

// Only fixed support codes leave the probe: SDK errors can contain credentials.
const groupMediaProbe = `
const report = code => { console.log('LOOM_MEDIA_' + code); process.exitCode = 1; };
const e = process.env;
if (!e.LOOM_GROUP_CALLS_API_URL || !e.LOOM_GROUP_CALLS_API_KEY || !e.LOOM_GROUP_CALLS_API_SECRET) {
  report('CONFIG');
} else {
  let SDK;
  try { SDK = await import('livekit-server-sdk'); } catch (_) { report('SDK'); }
  if (SDK) {
    let client;
    try { client = new SDK.RoomServiceClient(e.LOOM_GROUP_CALLS_API_URL,
      e.LOOM_GROUP_CALLS_API_KEY, e.LOOM_GROUP_CALLS_API_SECRET,
      {requestTimeout: 5, failover: false}); } catch (_) { report('CONFIG'); }
    if (client) {
      let reason = 'UNAVAILABLE', ready = false;
      for (let attempt = 0; attempt < 12; attempt++) {
        try { await client.listRooms(); ready = true; break; }
        catch (error) {
          reason = 'UNAVAILABLE';
          let cause = error;
          for (let depth = 0; cause && depth < 6; depth++, cause = cause.cause) {
            if (cause.status === 401 || cause.status === 403) { reason = 'AUTH'; break; }
            if (['ENOTFOUND', 'EAI_AGAIN'].includes(cause.code)) reason = 'DNS';
            if (['ETIMEDOUT', 'UND_ERR_CONNECT_TIMEOUT'].includes(cause.code) ||
                ['TimeoutError', 'AbortError'].includes(cause.name)) reason = 'TIMEOUT';
          }
          if (reason === 'AUTH') break;
          if (attempt < 11) await new Promise(resolve => setTimeout(resolve, 2000));
        }
      }
      if (!ready) report(reason);
    }
  }
}
`

func groupMediaFailure(output []byte) string {
	messages := map[string]string{
		"CONFIG":      "Media configuration is incomplete or invalid",
		"SDK":         "Node image is missing its media SDK; rebuild Node",
		"AUTH":        "Media credentials rejected; check matching Node and media configuration",
		"DNS":         "Node cannot resolve the private media service; check the Docker network",
		"TIMEOUT":     "Private media API timed out after startup retries",
		"UNAVAILABLE": "Private media API is unavailable after startup retries; check media service status",
	}
	for _, line := range strings.Split(string(output), "\n") {
		if message, ok := messages[strings.TrimPrefix(strings.TrimSpace(line), "LOOM_MEDIA_")]; ok && strings.HasPrefix(strings.TrimSpace(line), "LOOM_MEDIA_") {
			return message
		}
	}
	return "Media verification command failed; check Node and media service status"
}
