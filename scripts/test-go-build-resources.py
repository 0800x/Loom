#!/usr/bin/env python3
"""Verify resource limits used by the native Go compiler builders."""
from pathlib import Path
import subprocess
import unittest

HELPER = Path(__file__).resolve().parent.parent / 'services/loom_server/scripts/linux/go-build-resources.sh'

class BuildResources(unittest.TestCase):
    def call(self, function, *args):
        result = subprocess.run(['sh', '-ec', '. "$1"; shift; fn=$1; shift; "$fn" "$@"',
                                 'fixture', str(HELPER), function, *map(str, args)],
                                capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def test_cpu_quota_limits_host_cpu_count(self):
        for args, expected in [((32, 200000, 100000), '2'), ((8, 50000, 100000), '1'),
                               ((2, 'max', 100000), '2'), ((2, -1, 100000), '2')]:
            self.assertEqual(self.call('loom_go_effective_cpus', *args), expected)

    def test_memory_limits_parallelism_and_large_hosts_are_bounded(self):
        for args, expected in [((16, 1024), '1'), ((16, 2048), '2'), ((16, 16384), '8'),
                               ((2, 16384), '2'), ((8, 128), '1')]:
            self.assertEqual(self.call('loom_go_jobs_for', *args), expected)

if __name__ == '__main__': unittest.main()
