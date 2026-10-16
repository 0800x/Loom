#!/usr/bin/env bash
# Configure an installed Node's optional SFU. Preserve existing credentials.
set -euo pipefail
home=${LOOM_HOME:-/opt/loom-node}
checkout=${LOOM_SOURCE:-/opt/loom-src}
ip=${1:-}
if [[ -z "$ip" ]]; then printf 'Usage: %s SERVER_PUBLIC_IPV4\n' "$0" >&2; exit 2; fi
command -v python3 >/dev/null
command -v docker >/dev/null
[[ -f "$home/deploy/.env" && -f "$home/deploy/docker-compose.production.yml" ]]
[[ -f "$checkout/services/loom_server/deploy/docker-compose.group-calls.yml" ]]
python3 - "$home" "$ip" <<'PY'
import ipaddress,os,pathlib,secrets,shutil,sys,time
root=pathlib.Path(sys.argv[1])/'deploy'
ip=str(ipaddress.IPv4Address(sys.argv[2]))
if not ipaddress.ip_address(ip).is_global: raise SystemExit('Use the reachable server public IPv4')
env=root/'.env'; config=root/'livekit.yaml'
if env.is_symlink() or config.is_symlink(): raise SystemExit('Refusing symlink configuration')
lines=env.read_text().splitlines();values={}
for line in lines:
 if '=' in line and not line.lstrip().startswith('#'):
  k,v=line.split('=',1);values[k.strip()]=v.strip().strip('"\'')
key=values.get('LOOM_GROUP_CALLS_API_KEY') or 'gc_'+secrets.token_hex(12)
secret=values.get('LOOM_GROUP_CALLS_API_SECRET') or secrets.token_hex(32)
if not key.replace('_','').isalnum() or not secret.replace('_','').replace('-','').isalnum() or len(secret)<32:
 raise SystemExit('Existing SFU credentials use unsupported characters; configure manually')
if secret in [values.get(k) for k in ['LOOM_ADMIN_TOKEN','LOOM_TURN_SHARED_SECRET','LOOM_S3_SECRET_ACCESS_KEY']]:
 raise SystemExit('SFU credentials must be independent of other service secrets')
changes={'LOOM_CALLS_ENABLED':'true','LOOM_VOICE_CALLS_ENABLED':'true','LOOM_GROUP_CALLS_ENABLED':'true','LOOM_GROUP_CALLS_API_URL':'http://livekit:7880','LOOM_GROUP_CALLS_API_KEY':key,'LOOM_GROUP_CALLS_API_SECRET':secret,'LOOM_GROUP_CALLS_MAX_PARTICIPANTS':values.get('LOOM_GROUP_CALLS_MAX_PARTICIPANTS','16'),'LOOM_GROUP_CALLS_PUBLIC_IP':ip}
if changes['LOOM_GROUP_CALLS_MAX_PARTICIPANTS'] not in map(str,range(2,33)): raise SystemExit('Invalid participant limit')
backup=root/('group-calls-backup-'+str(time.time_ns()));backup.mkdir(mode=0o700)
for path in [env,config]:
 if path.exists(): shutil.copy2(path,backup/path.name);os.chmod(backup/path.name,0o600)
text='\n'.join(l for l in lines if l.split('=',1)[0].strip() not in changes)+'\n'
text+=''.join(k+'='+v+'\n' for k,v in changes.items())
config_text=f'''port: 7880
rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 50100
  use_external_ip: false
keys:
  {key}: {secret}
webhook:
  api_key: {key}
  urls:
    - http://loom-node:7483/api/v1/group-calls/webhook
logging:
  level: warn
'''
for path,data in [(env,text),(config,config_text)]:
 tmp=path.with_name(path.name+'.group-calls-tmp')
 fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as out: out.write(data)
 os.replace(tmp,path);os.chmod(path,0o600)
print('Previous settings saved in:',backup)
PY
install -m 0644 "$checkout/services/loom_server/deploy/docker-compose.group-calls.yml" "$home/deploy/docker-compose.group-calls.yml"
compose() { docker compose --project-directory "$home/deploy" --env-file "$home/deploy/.env" -f "$home/deploy/docker-compose.production.yml" -f "$home/deploy/docker-compose.group-calls.yml" "$@"; }
compose config --quiet
compose up -d livekit
compose up -d --no-deps --force-recreate --wait --wait-timeout 120 loom-node
printf 'Allow TCP 7881 and UDP 50000–50100; keep TCP 7880 private.\n'
