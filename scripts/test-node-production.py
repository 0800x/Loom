#!/usr/bin/env python3
"""Exercise the real production image/storage in an isolated Compose project.
Never run against an existing installation; all resources use a random project.
"""
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parent.parent
SERVER=ROOT/'services/loom_server'
revision=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip()
installer=(SERVER/'scripts/linux/install-production.sh').read_text()
write_env=installer[installer.index('write_env()'):installer.index('set_env_value()',installer.index('write_env()'))]
random_secret=installer[installer.index('random_secret()'):installer.index('port_in_use()',installer.index('random_secret()'))]
project='loom-runtime-fixture-'+secrets.token_hex(6)

def run(args, **kwargs):
    return subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=600,**kwargs)

with tempfile.TemporaryDirectory(prefix='loom-production-fixture-') as temp:
    home=Path(temp)/'server'
    shutil.copytree(SERVER,home,ignore=shutil.ignore_patterns('node_modules','.env','*.log'))
    body='set -euo pipefail\n'+random_secret+write_env+'\nINSTALL_DIR="$1"; DOMAIN=chat.example.org; PROXY_MODE=nginx; OPERATOR_NAME="Example operator"; JURISDICTION=Unspecified; REGISTRATION=approval; FEDERATION=trusted; write_env\n'
    result=run(['bash','-c',body,'fixture',str(home)])
    if result.returncode:raise RuntimeError('Production environment generation failed')
    env_path=home/'deploy/.env'
    env_path.write_text(env_path.read_text().replace('LOOM_HOST_PORT=7483','LOOM_HOST_PORT=0')+'LOOM_BUILD_COMMIT='+revision+'\n')
    selected_profile=os.environ.get('LOOM_TEST_DOWNLOAD_PROFILE','official')
    if selected_profile not in ('official','liara','arvan'): raise ValueError('Unknown fixture download profile')
    helper=SERVER/'scripts/linux/download-sources.sh'
    policy=run(['bash','-c', 'source "$1"; loom_download_profile "$2"; printf "LOOM_DOCKER_PREFIX=%s\\nLOOM_GO_PROXY=%s\\nLOOM_NPM_REGISTRY=%s\\nLOOM_ALPINE_MIRROR=%s\\n" "$LOOM_DOCKER_PREFIX" "$LOOM_GO_PROXY" "$LOOM_NPM_REGISTRY" "$LOOM_ALPINE_MIRROR"', 'fixture', str(helper), selected_profile])
    if policy.returncode: raise RuntimeError('Fixture download policy failed')
    env_path.write_text(env_path.read_text()+policy.stdout)
    original=env_path.read_bytes()
    compose=['docker','compose','--project-name',project,'--env-file',str(env_path),'-f',str(home/'deploy/docker-compose.production.yml')]
    def safe_output(text):
        for line in original.decode().splitlines():
            if '=' in line:
                key,value=line.split('=',1)
                if any(name in key for name in ['PASSWORD','TOKEN','SECRET','ACCESS_KEY']) and value:
                    text=text.replace(value,'[redacted]')
        return re.sub(r'postgres(?:ql)?://[^\s]+','[database URL]',text)[-5000:]
    def operation(args):
        result=run(compose+args)
        if result.returncode:raise RuntimeError('Isolated production fixture operation failed: '+' '.join(args[:3])+'\n'+safe_output(result.stderr))
        return result.stdout.strip()
    # Real Compose interpolation: mirror selection must reach every builder and
    # runtime image without changing the daemon or any shared service.
    for profile, prefix in [('liara', 'docker-mirror.liara.ir/'), ('arvan', 'docker.arvancloud.ir/')]:
        profile_env=home/'deploy'/('fixture-'+profile+'.env')
        profile_env.write_text(original.decode()+'LOOM_DOCKER_PREFIX='+prefix+'\nLOOM_GO_PROXY=https://package-mirror.liara.ir/repository/go/\nLOOM_NPM_REGISTRY=https://package-mirror.liara.ir/repository/npm/\nLOOM_ALPINE_MIRROR=https://linux-mirror.liara.ir/repository/alpine\n')
        command=['docker','compose','--env-file',str(profile_env),'-f',str(home/'deploy/docker-compose.production.yml'), 'config', '--format', 'json']
        result=run(command)
        if result.returncode: raise RuntimeError('Mirror Compose configuration rejected: '+profile)
        services=json.loads(result.stdout)['services']
        exporters={}
        for name, service in services.items():
            if 'build' not in service: continue
            image=service.get('image')
            if not image: raise RuntimeError('Build service lacks an explicit image target: '+name)
            if image in exporters: raise RuntimeError('Concurrent build exporters share an image tag: '+exporters[image]+' and '+name)
            exporters[image]=name
        if services['postgres']['image'] != prefix+'postgres:17-alpine': raise RuntimeError('PostgreSQL mirror missing')
        for service in ('minio', 'minio-init', 'loom-node'):
            if services[service]['build']['args']['LOOM_DOCKER_PREFIX'] != prefix: raise RuntimeError('Build-base mirror missing')
        if services['minio']['build']['args']['LOOM_GO_PROXY'] != 'https://package-mirror.liara.ir/repository/go/': raise RuntimeError('Go mirror missing')
        if services['loom-node']['build']['args']['LOOM_NPM_REGISTRY'] != 'https://package-mirror.liara.ir/repository/npm/': raise RuntimeError('npm mirror missing')
        print('Real Compose accepts the isolated '+profile+' download profile',flush=True)
    identity_command=['exec','-T','loom-node','node','-e',"console.log(require('node:crypto').createHash('sha256').update(require('node:fs').readFileSync('/app/data/node-identity.json')).digest('hex'))"]
    try:
        print('Building and starting the real production Node, PostgreSQL and attachment storage',flush=True)
        operation(['up','-d','--build','--wait','--wait-timeout','180'])
        identity=operation(identity_command)
        if len(identity)!=64:raise RuntimeError('Persistent identity was not created by the production runtime')
        operation(['exec','-T','loom-node','node','-e',"fetch('http://127.0.0.1:7483/readyz').then(r=>process.exit(r.ok?0:1))"])
        print('Fresh production runtime is ready',flush=True)
        # Rebuild both cached Node targets together, including when their tags
        # already exist. Containerd stores reject concurrent exports to one tag.
        operation(['build','loom-node','minio-init'])
        images=operation(['images','--format','json'])
        if not images: raise RuntimeError('Built production images are unavailable')
        print('Concurrent Node and bucket-initializer rebuild completed with distinct image targets',flush=True)
        # Simulate the reported retained-volume/missing-config situation.
        missing=home/'deploy/missing.env'
        guard='source "$1"; loom_guard_persistent_install "$2"'
        result=run(['bash','-c',guard,'fixture',str(home/'scripts/linux/install-state.sh'),str(missing)])
        if result.returncode==0 or missing.exists():raise RuntimeError('Retained storage was allowed to generate replacement credentials')
        print('Retained storage with missing configuration is rejected without generating credentials',flush=True)
        # Changing POSTGRES_PASSWORD does not change the password in an existing database.
        values=dict(line.split('=',1) for line in original.decode().splitlines() if '=' in line)
        changed=original.decode().replace(values['POSTGRES_PASSWORD'],secrets.token_hex(32))
        env_path.write_text(changed)
        operation(['up','-d','--no-deps','--force-recreate','loom-node'])
        rejected=False
        for _ in range(30):
            logs=operation(['logs','--no-color','--tail','80','loom-node'])
            if 'password authentication failed' in logs or '28P01' in logs: rejected=True;break
            time.sleep(1)
        if not rejected:raise RuntimeError('Retained PostgreSQL did not reproduce the credential-mismatch failure')
        classification=run(['bash','-c','source "$1"; loom_classify_startup_failure "$2"','fixture',str(home/'scripts/linux/install-state.sh'),logs])
        if 'Restore the original' not in classification.stdout:raise RuntimeError('Credential mismatch did not produce the recovery instruction')
        print('Credential mismatch reproduces startup failure and is diagnosed without resetting credentials',flush=True)
        env_path.write_bytes(original)
        operation(['up','-d','--no-deps','--force-recreate','--wait','--wait-timeout','180','loom-node'])
        if operation(identity_command)!=identity:raise RuntimeError('Persistent Node identity changed across restart/restoration')
        if hashlib.sha256(env_path.read_bytes()).digest()!=hashlib.sha256(original).digest():raise RuntimeError('Saved configuration changed')
        print('Original configuration restores readiness; persistent identity remains byte-identical',flush=True)
    except Exception:
        failure=run(compose+['logs','--no-color','--tail','60','loom-node'])
        text=failure.stdout+failure.stderr
        for line in original.decode().splitlines():
            if '=' in line:
                key,value=line.split('=',1)
                if any(name in key for name in ['PASSWORD','TOKEN','SECRET','ACCESS_KEY']) and value:
                    text=text.replace(value,'[redacted]')
        text=re.sub(r'postgres(?:ql)?://[^\s]+','[database URL]',text)
        text=re.sub(r'\b(?:\d{1,3}\.){3}\d{1,3}\b','[address]',text)
        print(text[-6000:],flush=True)
        raise
    finally:
        result=run(compose+['down','--volumes','--remove-orphans'])
        if result.returncode:raise RuntimeError('Isolated fixture cleanup failed')
