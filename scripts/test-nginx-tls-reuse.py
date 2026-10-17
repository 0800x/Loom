#!/usr/bin/env python3
"""Exercise installer TLS routing with real certificates and mocked service changes."""
import pathlib
import subprocess
import tempfile
import unittest

INSTALLER = pathlib.Path(__file__).resolve().parents[1] / 'services/loom_server/scripts/linux/install-production.sh'


def function(source, name):
    start = source.index(name + '() {')
    end = source.index('\n}\n', start) + 3
    return source[start:end]


class NginxTlsReuse(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = INSTALLER.read_text()

    def run_shell(self, body):
        return subprocess.run(['bash', '-c', 'set -euo pipefail\n' + body], text=True, capture_output=True)

    def test_real_certificate_hostname_and_missing_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-subj', '/CN=node.example.test', '-addext', 'subjectAltName=DNS:node.example.test',
                            '-keyout', str(directory / 'privkey.pem'), '-out', str(directory / 'fullchain.pem')],
                           check=True, capture_output=True)
            check = function(self.source, 'nginx_certificate_is_valid')
            result = self.run_shell(check + '\nDOMAIN=node.example.test\nnginx_certificate_is_valid "$1"\n'.replace('"$1"', '"' + temporary + '"'))
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.run_shell(check + '\nDOMAIN=wrong.example.test\nnginx_certificate_is_valid "' + temporary + '"\n')
            self.assertNotEqual(result.returncode, 0)
            (directory / 'privkey.pem').unlink()
            result = self.run_shell(check + '\nDOMAIN=node.example.test\nnginx_certificate_is_valid "' + temporary + '"\n')
            self.assertNotEqual(result.returncode, 0)

    def flow(self, validity, issuer_status):
        body = '''
DOMAIN=node.example.test
ensure_nginx_certbot() { :; }
check_nginx_domain_conflict() { :; }
nginx_site_path() { echo /test/site; }
enable_nginx_site() { echo enable; }
write_nginx_http_site() { echo http; }
write_nginx_https_site() { echo https; }
install_certbot_renewal_hook() { echo renewal; }
ui_ok() { :; }
ui_warn() { :; }
ui_info() { :; }
calls=0
'''
        body += 'validity=(' + ' '.join(map(str, validity)) + ')\n'
        body += 'nginx_certificate_is_valid() { local result=${validity[$calls]}; calls=$((calls + 1)); return "$result"; }\n'
        body += 'issue_nginx_certificate() { echo issuer; return ' + str(issuer_status) + '; }\n'
        body += function(self.source, 'configure_nginx_tls') + '\nconfigure_nginx_tls\n'
        return self.run_shell(body)

    def test_valid_certificate_does_not_downgrade_or_issue(self):
        result = self.flow([0], 1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['enable', 'https', 'renewal'])

    def test_fresh_certificate_is_verified_before_https(self):
        result = self.flow([1, 0], 0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['http', 'issuer', 'https', 'renewal'])

    def test_failed_issuer_without_certificate_stays_closed(self):
        result = self.flow([1, 1], 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), ['http', 'issuer'])

    def test_successful_issuer_with_wrong_certificate_stays_closed(self):
        result = self.flow([1, 1], 0)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('https', result.stdout.splitlines())

    def test_concurrent_issuer_can_supply_valid_certificate(self):
        result = self.flow([1, 0, 0], 1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['http', 'issuer', 'https', 'renewal'])


if __name__ == '__main__':
    unittest.main()
