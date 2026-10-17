#!/usr/bin/env python3
"""Run setup choices and provisioning commands against isolated files and command doubles."""
import os
import ast
import base64
import hashlib
import hmac
import secrets
import socket
import struct
from pathlib import Path
import pty
import fcntl
import termios
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SETUP = ROOT / 'services/loom_server/scripts/linux/setup.sh'
PLATFORM = SETUP.with_name('platform.sh')
SOURCE = SETUP.read_text()


def functions():
    return SOURCE[SOURCE.index('read_env_value()'):SOURCE.index('if [[ -f "$ENV_FILE" ]]; then\n  EXISTING_INSTALL=1')]


class SetupTests(unittest.TestCase):
    def test_preview_is_read_only_and_rejects_invalid_choices(self):
        good = subprocess.run(['bash', str(SETUP), '--plan', '--yes', '--domain', 'chat.example.org', '--turn', 'off', '--group-calls', 'off'], capture_output=True, text=True)
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertIn('Preview only. Nothing was changed.', good.stdout)
        for args in (['--video', 'invalid'], ['--group-calls', 'invalid'], ['--domain', 'bad;touch /tmp/loom-injection']):
            result = subprocess.run(['bash', str(SETUP), '--plan', '--yes', *args], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_interactive_questions_and_invalid_answer_retry(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.execvp('bash', ['bash', str(SETUP), '--plan', '--text'])
        output = bytearray()
        prompts = [(b'Download sources', b'official\n'), (b'HTTPS mode', b'public\n'), (b'Server hostname or IPv4', b'chat.example.org\n'), (b'Registration', b'invalid\nopen\n'), (b'Federation', b'disabled\n'), (b'Voice calls', b'auto\n'), (b'Video calls', b'no\n'), (b'Group calls (', b'on\n')]
        index, deadline = 0, time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([fd], [], [], .1)
                if ready:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                    if index < len(prompts) and prompts[index][0] in output:
                        os.write(fd, prompts[index][1]); index += 1
            waited, status = os.waitpid(pid, os.WNOHANG)
            if not waited:
                os.kill(pid, 15); os.waitpid(pid, 0)
                self.fail('Wizard did not finish: ' + output.decode(errors='replace'))
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode(errors='replace'))
            self.assertEqual(index, len(prompts))
            text = output.decode()
            self.assertIn('Invalid choice:', text)
            self.assertIn('Registration       open', text)
            self.assertIn('Video calls        no', text)
        finally:
            os.close(fd)

    def test_arrow_menu_and_cancel(self):
        # Real controlling PTY, real shell widgets; provisioning stays in --plan.
        for cancel in (False, True):
            pid, fd = pty.fork()
            if pid == 0:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 40, 0, 0))
                os.environ['TERM'] = 'xterm'
                os.execvp('bash', ['bash', str(SETUP), '--plan'])
            output, pending = bytearray(), bytearray()
            prompts = [(b'Download sources  (', b'\n'), (b'HTTPS mode  (', b'\n'), (b'Server hostname or IPv4', b'chat.example.org\n'),
                       (b'Registration  (', b'\x1b[B\n'),
                       (b'Federation  (', b'\x1b[B\n'),
                       (b'Voice calls  (', b'\x1b' if cancel else b'\n'),
                       (b'Video calls  (', b'\x1b[B\n'),
                       (b'Group calls (', b'\x1b[B\n')]
            if cancel:
                prompts = prompts[:6]
            index, deadline = 0, time.monotonic() + 15
            try:
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([fd], [], [], .1)
                    if not ready:
                        continue
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk); pending.extend(chunk)
                    if index < len(prompts) and prompts[index][0] in pending:
                        # Wait until the whole menu has rendered before input.
                        if b'Server hostname' in prompts[index][0] or pending.endswith(b'\r\n'):
                            os.write(fd, prompts[index][1])
                            index += 1; pending.clear()
                waited, status = os.waitpid(pid, os.WNOHANG)
                if not waited:
                    os.kill(pid, 15); os.waitpid(pid, 0)
                    self.fail('Menu did not finish: ' + output.decode(errors='replace'))
                self.assertEqual(os.waitstatus_to_exitcode(status), 130 if cancel else 0, output.decode(errors='replace'))
                self.assertEqual(index, len(prompts))
                if not cancel:
                    for expected in ('Registration       open', 'Federation         disabled',
                                     'Video calls        no', 'Group calls        off'):
                        self.assertIn(expected, output.decode(errors='replace'))
                else:
                    self.assertNotIn(b'Installing Loom Node', output)
            finally:
                os.close(fd)

    def test_local_certificate_san_reuse_and_mismatch(self):
        helper = SETUP.with_name('local-tls.sh')
        for host, option in [('192.0.2.24', '-verify_ip'), ('loom.local', '-verify_hostname')]:
            with tempfile.TemporaryDirectory() as temp:
                cert = Path(temp)/'tls'
                command = ['bash', '-c', 'set -euo pipefail; source "$1"; loom_local_certificate "$2" "$3"', 'fixture', str(helper), str(cert), host]
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                original = (cert/'privkey.pem').read_bytes(), (cert/'fullchain.pem').read_bytes()
                verified = subprocess.run(['openssl', 'verify', '-CAfile', str(cert/'fullchain.pem'), option, host, str(cert/'fullchain.pem')], capture_output=True)
                self.assertEqual(verified.returncode, 0, verified.stderr)
                wrong = subprocess.run(['openssl', 'verify', '-CAfile', str(cert/'fullchain.pem'), '-verify_hostname', 'wrong.example.org', str(cert/'fullchain.pem')], capture_output=True)
                self.assertNotEqual(wrong.returncode, 0)
                self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
                self.assertEqual(original, ((cert/'privkey.pem').read_bytes(), (cert/'fullchain.pem').read_bytes()))
                changed = command[:-1]+['other.local']
                self.assertNotEqual(subprocess.run(changed, capture_output=True).returncode, 0)
                self.assertEqual(original, ((cert/'privkey.pem').read_bytes(), (cert/'fullchain.pem').read_bytes()))
                self.assertEqual((cert/'privkey.pem').stat().st_mode & 0o777, 0o600)
        preview = subprocess.run(['bash', str(SETUP), '--plan', '--yes', '--tls', 'local', '--domain', '192.0.2.24', '--turn', 'off', '--group-calls', 'off'], capture_output=True, text=True)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertIn('HTTPS mode         local', preview.stdout)
        public = subprocess.run(['bash', str(SETUP), '--plan', '--yes', '--domain', '192.0.2.24'], capture_output=True)
        self.assertNotEqual(public.returncode, 0)

    def test_mirror_docker_install_never_requests_docker_inc_key(self):
        installer = SETUP.with_name('install-production.sh').read_text()
        body = installer[installer.index('install_docker_debian_like()'):installer.index('install_docker_rpm()')]
        script = 'set -euo pipefail\n'+body+r"""
LOOM_DOWNLOAD_PROFILE=arvan
VERSION_CODENAME=noble
dpkg-query(){ return 1; }
loom_packages(){ printf 'packages:%s\n' "$*"; }
systemctl(){ :; }
curl(){ echo 'Unexpected external download' >&2; exit 9; }
apt-get(){ echo 'Unexpected system APT call' >&2; exit 9; }
install_docker_debian_like ubuntu
"""
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('packages:docker.io docker-compose-v2 docker-buildx', result.stdout)

    def test_download_profiles_and_invalid_source(self):
        helper = SETUP.with_name('download-sources.sh')
        for profile, prefix in [('official', ''), ('liara', 'docker-mirror.liara.ir/'), ('arvan', 'docker.arvancloud.ir/')]:
            result = subprocess.run(['bash', '-c', 'source "$1"; loom_download_profile "$2"; printf "%s\\n%s\\n" "$LOOM_DOCKER_PREFIX" "$LOOM_GO_PROXY"',
                                     'fixture', str(helper), profile], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines()[0], prefix)
            self.assertEqual(result.stdout.splitlines()[1], 'https://proxy.golang.org,direct' if profile == 'official' else 'https://package-mirror.liara.ir/repository/go/')
            preview = subprocess.run(['bash', str(SETUP), '--plan', '--yes', '--domain', 'chat.example.org', '--downloads', profile], capture_output=True, text=True)
            self.assertEqual(preview.returncode, 0, preview.stderr)
            self.assertIn('Download sources   ' + profile, preview.stdout)
        invalid = subprocess.run(['bash', str(SETUP), '--plan', '--yes', '--downloads', 'https://untrusted.example'], capture_output=True)
        self.assertNotEqual(invalid.returncode, 0)

    def test_go_mirror_is_independent_and_persisted_defaults_are_retained(self):
        helper=SETUP.with_name('download-sources.sh')
        proxies={'official':'https://proxy.golang.org','liara':'https://package-mirror.liara.ir/repository/go/','runflare':'https://mirror-go.runflare.com','goproxy-cn':'https://goproxy.cn'}
        for mirror, proxy in proxies.items():
            command='set -euo pipefail; source "$1"; loom_download_profile arvan; loom_go_mirror "$2"; printf "%s\\n%s\\n%s\\n" "$LOOM_DOCKER_PREFIX" "$LOOM_GO_PROXY" "$LOOM_NPM_REGISTRY"'
            result=subprocess.run(['bash','-c',command,'fixture',str(helper),mirror],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout.splitlines(),['docker.arvancloud.ir/',proxy,'https://package-mirror.liara.ir/repository/npm/'])
            preview=subprocess.run(['bash',str(SETUP),'--plan','--yes','--domain','chat.example.org','--go-mirror',mirror],capture_output=True,text=True)
            self.assertEqual(preview.returncode,0,preview.stderr)
            self.assertIn(proxy,preview.stdout)
        result=subprocess.run(['bash',str(SETUP),'--plan','--yes','--domain','chat.example.org','--go-mirror','http://unapproved.example'],capture_output=True)
        self.assertNotEqual(result.returncode,0)
        with tempfile.TemporaryDirectory() as temp:
            env=Path(temp)/'deploy/.env';env.parent.mkdir();env.write_text('LOOM_GO_MIRROR=runflare\nLOOM_PUBLIC_DOMAIN=chat.example.org\n')
            preview=subprocess.run(['bash',str(SETUP),'--plan','--yes','--turn','off','--group-calls','off'],env={**os.environ,'LOOM_NODE_HOME':temp},capture_output=True,text=True)
            self.assertEqual(preview.returncode,0,preview.stderr)
            self.assertIn('https://mirror-go.runflare.com',preview.stdout)
            self.assertEqual(env.read_text(),'LOOM_GO_MIRROR=runflare\nLOOM_PUBLIC_DOMAIN=chat.example.org\n')

    def test_mirror_apt_uses_temporary_signed_sources(self):
        helper = SETUP.with_name('download-sources.sh')
        # Real temporary source generation; apt/dpkg are command doubles.
        for distro, codename, expected in [('ubuntu', 'noble', 'ubuntu'), ('debian', 'bookworm', 'debian')]:
            key = '/usr/share/keyrings/' + distro + '-archive-keyring.gpg'
            if not Path(key).exists():
                continue
            script = r"""
set -eu
source "$1"
ID="$2"; VERSION_CODENAME="$3"
dpkg(){ echo amd64; }
apt-get(){
  local arg file=''
  for arg; do case "$arg" in Dir::Etc::sourcelist=*) file="${arg#*=}";; esac; done
  [[ -n "$file" && -f "$file" ]] || exit 9
  cat "$file"
  printf '%s\n' "$*"
}
loom_mirror_apt curl
"""
            result = subprocess.run(['bash', '-c', script, 'fixture', str(helper), distro, codename], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('signed-by=' + key, result.stdout)
            self.assertIn('/repository/' + expected, result.stdout)
            self.assertIn(codename + '-security', result.stdout)
            self.assertIn('AllowUnauthenticated=false', result.stdout)
            self.assertIn('sourceparts=-', result.stdout)

    def test_package_routing_without_host_changes(self):
        for distro, expected in [('ubuntu', 'apt-get install -y'), ('debian', 'apt-get install -y'), ('fedora', 'dnf -y install'), ('centos', 'dnf -y install'), ('rhel', 'dnf -y install'), ('rocky', 'dnf -y install'), ('almalinux', 'dnf -y install'), ('arch', 'pacman -Syu --needed --noconfirm'), ('manjaro', 'pacman -Syu --needed --noconfirm'), ('opensuse-leap', 'zypper --non-interactive install')]:
            script = 'set -eu; source "$1"; ID="$2"; apt-get(){ echo apt-get "$@"; }; dnf(){ echo dnf "$@"; }; pacman(){ echo pacman "$@"; }; zypper(){ echo zypper "$@"; }; loom_packages git curl'
            result = subprocess.run(['bash', '-c', script, 'test', str(PLATFORM), distro], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected + ' git curl', result.stdout)
        result = subprocess.run(['bash', '-c', 'source "$1"; ID=unknown; loom_platform', 'test', str(PLATFORM)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_docker_install_routes_without_services(self):
        installer = SETUP.with_name('install-production.sh').read_text()
        body = installer[installer.index('install_docker_rpm()'):installer.index('ensure_runtime_tools()')]
        mocks = r"""
load_os_release(){ :; }
loom_require_systemd(){ :; }
ui_ok(){ :; }
docker(){ [[ "${1:-}" != info || -e "$MARKER" ]]; }
install_docker_debian_like(){ echo "debian-repo:$1"; touch "$MARKER"; }
loom_packages(){ echo "packages:$*"; touch "$MARKER"; }
systemctl(){ echo "systemctl:$*"; touch "$MARKER"; }
dnf(){
  if [[ "$*" == 'config-manager --help' ]]; then echo "$DNF_COMMAND"; return; fi
  echo "dnf:$*"
}
"""
        routes = [('ubuntu', 'debian-repo:ubuntu'), ('debian', 'debian-repo:debian'), ('fedora', 'linux/fedora/docker-ce.repo'), ('centos', 'linux/centos/docker-ce.repo'), ('rocky', 'linux/centos/docker-ce.repo'), ('almalinux', 'linux/centos/docker-ce.repo'), ('rhel', 'linux/rhel/docker-ce.repo'), ('arch', 'packages:docker docker-compose'), ('opensuse-leap', 'packages:docker docker-compose')]
        for distro, expected in routes:
            for dnf in ['addrepo', '--add-repo']:
                with tempfile.TemporaryDirectory(prefix='loom-distro-test-') as temp:
                    env = {**os.environ, 'ID': distro, 'DNF_COMMAND': dnf, 'MARKER': str(Path(temp)/'docker-ready')}
                    result = subprocess.run(['bash', '-c', 'set -euo pipefail\n'+body+mocks+'\nensure_docker'], env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(expected, result.stdout)
                    if '/docker-ce.repo' in expected:
                        self.assertIn('config-manager '+dnf, result.stdout)

    def test_retained_volumes_require_original_environment(self):
        state = SETUP.with_name('install-state.sh')
        for retained in [False, True]:
            with tempfile.TemporaryDirectory(prefix='loom-retained-') as temp:
                script='source "$1"; docker(){ if [[ "$1" == volume && "$2" == ls && "$3" == -q ]]; then printf "%s" "$RETAINED"; fi; }; loom_guard_persistent_install "$2/.env"'
                result=subprocess.run(['bash','-c',script,'test',str(state),temp],env={**os.environ,'RETAINED':'volume-id' if retained else ''},capture_output=True,text=True)
                self.assertEqual(result.returncode == 0,not retained,result.stderr)
                self.assertFalse((Path(temp)/'.env').exists())
                (Path(temp)/'.env').write_text('KEEP=original')
                result=subprocess.run(['bash','-c',script,'test',str(state),temp],env={**os.environ,'RETAINED':'volume-id'},capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual((Path(temp)/'.env').read_text(),'KEEP=original')

    @unittest.skipUnless(os.geteuid()==0, 'Root-owned approval fixture')
    def test_verified_install_records_approval_and_preserves_manual_policy(self):
        state=SETUP.with_name('install-state.sh')
        safety=SETUP.with_name('install-safety.sh')
        revision,digest='a'*40,'b'*64
        with tempfile.TemporaryDirectory(prefix='loom-approval-') as temp:
            directory=Path(temp)/'policy'
            script='set -euo pipefail; source "$1"; source "$2"; loom_write_release_approval unused "$4" "$5" "$3"'
            args=['bash','-c',script,'test',str(safety),str(state),str(directory),revision,digest]
            result=subprocess.run(args,capture_output=True,text=True);self.assertEqual(result.returncode,0,result.stderr)
            ledger=directory/'approved-releases';policy=directory/'update-policy'
            self.assertEqual(policy.read_text(),'publisher\n')
            self.assertEqual(ledger.stat().st_mode&0o777,0o600)
            result=subprocess.run(args,capture_output=True,text=True);self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(ledger.read_text().count(revision),1)
            policy.write_text('operator\n')
            result=subprocess.run(args,capture_output=True,text=True);self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(policy.read_text(),'operator\n')
            changed=args[:-1]+['c'*64]
            result=subprocess.run(changed,capture_output=True,text=True);self.assertNotEqual(result.returncode,0)
            self.assertIn(digest,ledger.read_text())

    def test_startup_diagnostics_never_echo_credentials(self):
        state=SETUP.with_name('install-state.sh')
        secret='synthetic-private-password'
        for logs in ['password authentication failed for user '+secret,'EACCES '+secret,'Invalid persisted Node identity '+secret,'unrecognised '+secret]:
            result=subprocess.run(['bash','-c','source "$1"; loom_classify_startup_failure "$2"','test',str(state),logs],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn(secret,result.stdout)

    def test_existing_storage_binary_is_pinned_without_migration(self):
        state=SETUP.with_name('install-state.sh')
        with tempfile.TemporaryDirectory(prefix='loom-storage-preserve-') as temp:
            home=Path(temp);(home/'deploy').mkdir();(home/'deploy/.env').write_text('KEEP=original')
            image='sha256:'+'a'*64
            script='set -euo pipefail; source "$1"; docker(){ if [[ "$1" == ps ]]; then echo owned-container; else echo "$IMAGE"; fi; }; loom_preserve_storage_image "$2"'
            result=subprocess.run(['bash','-c',script,'fixture',str(state),temp],env={**os.environ,'IMAGE':image},capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            overlay=(home/'deploy/docker-compose.storage-legacy.yml').read_text()
            self.assertIn('build: !reset null',overlay);self.assertIn(image,overlay)
            self.assertEqual((home/'deploy/.env').read_text(),'KEEP=original')

    @unittest.skipUnless(os.geteuid()==0, 'Root-owned uninstall backup fixture')
    def test_retained_data_has_a_private_reinstall_configuration(self):
        state=SETUP.with_name('install-state.sh');safety=SETUP.with_name('install-safety.sh')
        with tempfile.TemporaryDirectory(prefix='loom-uninstall-backup-') as temp:
            root=Path(temp);home=root/'node';(home/'deploy').mkdir(parents=True)
            value='LOOM_ADMIN_TOKEN=synthetic-private-configuration\n'
            env=home/'deploy/.env';env.write_text(value);env.chmod(0o600)
            result=subprocess.run(['bash','-c','set -euo pipefail; source "$1"; source "$2"; loom_backup_retained_configuration "$3" "$4"','fixture',str(safety),str(state),str(home),str(root/'backups')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn('synthetic-private-configuration',result.stdout+result.stderr)
            files=list((root/'backups').glob('config-*/deploy/.env'));self.assertEqual(len(files),1)
            self.assertEqual(files[0].read_text(),value);self.assertEqual(files[0].stat().st_mode&0o777,0o600)
            self.assertEqual(env.read_text(),value)

    def exercise_turn(self, secret='', fail=False, conflict=False, local=False):
        with tempfile.TemporaryDirectory(prefix='loom-setup-test-') as temp:
            home = Path(temp); deploy = home / 'deploy'; deploy.mkdir()
            env = deploy / '.env'
            original = 'KEEP=unchanged\n' + ('LOOM_TURN_SHARED_SECRET=' + secret + '\n' if secret else '')
            env.write_text(original); env.chmod(0o600)
            mocks = home / 'mock'; mocks.mkdir()
            commands = {'systemctl': 'exit 1', 'ss': 'echo occupied' if conflict else 'exit 0', 'curl': 'exit 99' if local else 'echo 198.51.100.8', 'ip': 'echo "1: eth0 inet 198.51.100.8/24"', 'docker': 'printf "%s\\n" "$*" >> "$CALLS"; exit ' + ('23' if fail else '0'), 'ufw': 'exit 1', 'firewall-cmd': 'exit 1'}
            for name, body in commands.items():
                path = mocks / name; path.write_text('#!/bin/bash\n' + body + '\n'); path.chmod(0o755)
            script = 'set -euo pipefail\n' + functions() + '\nINSTALL_DIR="$1"; ENV_FILE="$1/deploy/.env"; DOMAIN=chat.example.org; VIDEO=no; CYAN=""; RESET=""; GREEN=""; BOLD=""; DIM=""; YELLOW=""; configure_local_turn\n'
            environ = {**os.environ, 'PATH': str(mocks) + ':/usr/bin:/bin', 'CALLS': str(home / 'calls'), 'TLS_MODE': 'local' if local else 'public'}
            result = subprocess.run(['bash', '-c', script, 'test', str(home)], capture_output=True, text=True, env=environ)
            if fail or conflict or secret == 'invalid':
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(env.read_text(), original)
                return
            self.assertEqual(result.returncode, 0, result.stderr)
            content = env.read_text()
            generated = next(line.split('=', 1)[1] for line in content.splitlines() if line.startswith('LOOM_TURN_SHARED_SECRET='))
            self.assertNotIn(generated, result.stdout + result.stderr)
            self.assertEqual(len(generated), 64)
            if secret:
                self.assertEqual(generated, secret)
            self.assertIn('KEEP=unchanged', content)
            self.assertIn('LOOM_VIDEO_CALLS_ENABLED=false', content)
            self.assertEqual(env.stat().st_mode & 0o777, 0o600)
            self.assertEqual((deploy / 'turnserver.conf').stat().st_mode & 0o777, 0o600)
            self.assertIn('static-auth-secret=' + generated, (deploy / 'turnserver.conf').read_text())
            self.assertIn('up -d --wait --wait-timeout 90 turn', (home / 'calls').read_text())
            return (deploy / 'turnserver.conf').read_text(), generated

    def test_turn_creation_preserves_unrelated_configuration(self):
        self.exercise_turn()

    def test_local_turn_does_not_need_external_ip_discovery(self):
        config, _ = self.exercise_turn(local=True)
        self.assertNotIn('external-ip=', config)
        result = subprocess.run(['bash', str(SETUP), '--plan', '--yes', '--tls', 'local', '--domain', '192.0.2.24'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Group calls        off', result.stdout)

    def test_turn_reuses_existing_secret(self):
        self.exercise_turn(secret='a' * 64)

    def test_turn_failure_does_not_enable_calls(self):
        self.exercise_turn(fail=True)

    def test_invalid_secret_is_never_replaced(self):
        self.exercise_turn(secret='invalid')

    def test_existing_service_is_never_taken_over(self):
        self.exercise_turn(conflict=True)

    @unittest.skipUnless(os.getenv('LOOM_TEST_DOCKER') == '1', 'Set LOOM_TEST_DOCKER=1 on an isolated Docker host for native TURN allocation')
    def test_native_authenticated_turn_allocation(self):
        config, secret = self.exercise_turn()
        overlay = SOURCE.split("<<'TURN_COMPOSE'\n", 1)[1].split('\nTURN_COMPOSE', 1)[0]
        def field(name):
            return next(line.split(':', 1)[1].strip() for line in overlay.splitlines() if line.strip().startswith(name+':'))
        helper = SETUP.with_name('download-sources.sh')
        profile = os.environ.get('LOOM_TEST_DOWNLOAD_PROFILE', 'official')
        prefix = subprocess.check_output(['bash', '-c', 'source "$1"; loom_download_profile "$2"; printf "%s" "$LOOM_DOCKER_PREFIX"',
                                          'fixture', str(helper), profile], text=True)
        image = field('image').replace('${LOOM_DOCKER_PREFIX:-}', prefix)
        self.assertNotIn('$', image)
        self.assertTrue(image.endswith('@sha256:bbefd3e1fdfdc0d58770fe01b581fd8b00d9f3a5580d00acb77cf719a6bc78e3'))
        entrypoint = [arg.replace('$$', '$') for arg in ast.literal_eval(field('entrypoint'))]
        command = ast.literal_eval(field('command'))
        name = 'loom-turn-test-' + secrets.token_hex(6)
        with tempfile.TemporaryDirectory(prefix='loom-native-turn-') as temp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.bind(('127.0.0.1', 0))
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
                reservation.bind(('127.0.0.1', 0)); port = reservation.getsockname()[1]
            path = Path(temp) / 'turnserver.conf'
            path.write_text(config.replace('listening-port=3478', f'listening-port={port}\nlistening-ip=127.0.0.1\nrelay-ip=127.0.0.1'))
            path.chmod(0o600)
            subprocess.run(['docker', 'pull', image], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(['docker', 'run', '-d', '--name', name, '--network', 'host', '--user', f'{os.getuid()}:{os.getgid()}', '--cap-drop=ALL', '--cap-add=NET_BIND_SERVICE', '--security-opt=no-new-privileges:true', '--entrypoint', entrypoint[0], '-v', str(path)+':/etc/coturn/turnserver.conf:ro', image, *entrypoint[1:], *command], check=True, stdout=subprocess.DEVNULL)
            try:
                client.settimeout(1)
                def attribute(kind, value):
                    return struct.pack('!HH', kind, len(value)) + value + b'\0' * (-len(value) % 4)
                def exchange(kind, body, key=None):
                    transaction = secrets.token_bytes(12)
                    packet = struct.pack('!HHI12s', kind, len(body)+(24 if key else 0), 0x2112A442, transaction)+body
                    if key:
                        packet += attribute(8, hmac.new(key, packet, hashlib.sha1).digest())
                    client.sendto(packet, ('127.0.0.1', port))
                    response, _ = client.recvfrom(65536)
                    self.assertEqual(response[8:20], transaction)
                    fields, offset = {}, 20
                    while offset + 4 <= len(response):
                        field, length = struct.unpack_from('!HH', response, offset)
                        fields[field] = response[offset+4:offset+4+length]
                        offset += 4 + length + (-length % 4)
                    return struct.unpack_from('!H', response)[0], fields
                for _ in range(25):
                    try:
                        kind, _ = exchange(1, b'')
                        self.assertEqual(kind, 0x101)
                        break
                    except (TimeoutError, ConnectionRefusedError):
                        time.sleep(.2)
                else:
                    self.fail('Native TURN did not answer local STUN')
                subprocess.run(['docker', 'exec', name, 'turnutils_stunclient', '-p', str(port), '127.0.0.1'], check=True, capture_output=True)
                transport = attribute(0x19, b'\x11\0\0\0')
                kind, fields = exchange(3, transport)
                self.assertEqual(kind, 0x113)
                self.assertIn(0x15, fields)  # authenticated nonce challenge
                self.assertIn(0x14, fields)  # realm
                username = (str(int(time.time())+600)+':loom-install-test').encode()
                password = base64.b64encode(hmac.new(secret.encode(), username, hashlib.sha1).digest())
                key = hashlib.md5(username+b':'+fields[0x14]+b':'+password).digest()
                body = transport+attribute(6, username)+attribute(0x14, fields[0x14])+attribute(0x15, fields[0x15])
                kind, fields = exchange(3, body, key)
                self.assertEqual(kind, 0x103, 'Authenticated TURN allocation failed')
                self.assertIn(0x16, fields)  # allocated relay address
            except Exception:
                logs = subprocess.run(['docker', 'logs', '--tail', '50', name], capture_output=True, text=True)
                print((logs.stdout+logs.stderr).replace(secret, '[redacted]'))
                raise
            finally:
                subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)


if __name__ == '__main__':
    unittest.main()
