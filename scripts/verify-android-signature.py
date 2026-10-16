"""Verify a tag APK against the owner's protected, existing certificate digest.
Do not print the certificate subject or expose signing configuration.
"""
import os
import re
import subprocess
import sys

expected = os.environ.get('EXPECTED_CERTIFICATE', '').replace(':', '').lower()
if not re.fullmatch('[0-9a-f]{64}', expected):
    raise ValueError('Protected LOOM_ANDROID_CERT_SHA256 approval is required')
result = subprocess.check_output([sys.argv[2], 'verify', '--print-certs', sys.argv[1]], text=True)
digests = re.findall(r'Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)', result)
if len(digests) != 1 or digests[0].lower() != expected:
    raise ValueError('APK does not use the approved existing signing certificate')
print('APK signature matches the approved existing certificate')
