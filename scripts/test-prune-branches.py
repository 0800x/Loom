#!/usr/bin/env python3
"""Verify pruning refuses moved/unmerged branches and never pushes in review mode."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('prune-merged-branches.sh')
ENTRIES = re.findall(r"'([^'|]+)\|([0-9a-f]{40})'", SCRIPT.read_text())

class PruneGuards(unittest.TestCase):
    def invoke(self, scenario, apply=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'git'
            fake.write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
a=sys.argv[1:]
entries=dict(line.split('|') for line in os.environ['ENTRIES'].splitlines())
if a[:1]==['rev-parse']: print('a'*40)
elif a[:1]==['ls-remote']:
 branch=a[-1].removeprefix('refs/heads/')
 sha=entries[branch]
 if os.environ['SCENARIO']=='moved' and branch==next(iter(entries)): sha='b'*40
 print(sha+'\\trefs/heads/'+branch)
elif a[:1]==['merge-base']:
 if os.environ['SCENARIO']=='unmerged': sys.exit(1)
elif a[:1]==['push']:
 with open(os.environ['PUSH_LOG'],'a') as out: out.write(' '.join(a)+'\\n')
''')
            fake.chmod(0o755)
            log = root / 'pushes'
            env = dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'],
                       SCENARIO=scenario, PUSH_LOG=str(log),
                       ENTRIES='\n'.join(branch+'|'+sha for branch,sha in ENTRIES))
            result = subprocess.run(['bash',str(SCRIPT),*(['--apply'] if apply else [])],env=env,capture_output=True,text=True)
            return result, log.read_text() if log.exists() else ''

    def test_review_does_not_mutate(self):
        result, pushes = self.invoke('merged')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(pushes,'')

    def test_changed_head_is_preserved(self):
        result, pushes = self.invoke('moved',True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(pushes,'')

    def test_unmerged_head_is_preserved(self):
        result, pushes = self.invoke('unmerged',True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(pushes,'')

    def test_apply_only_deletes_known_refs_with_leases(self):
        result, pushes = self.invoke('merged',True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(pushes.splitlines()),len(ENTRIES))
        for branch, sha in ENTRIES:
            self.assertIn('--force-with-lease=refs/heads/'+branch+':'+sha,pushes)
            self.assertIn('origin :refs/heads/'+branch,pushes)
        self.assertNotIn(':refs/heads/main',pushes)

if __name__ == '__main__': unittest.main()
