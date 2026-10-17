#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT=Path(__file__).with_name('initialize-release-history.py').resolve()

class HistoryTests(unittest.TestCase):
    def test_two_clean_commits_and_verified_installer_pins(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            def git(*args): return subprocess.check_output(['git', *args],cwd=root,text=True).strip()
            git('init','-q')
            git('config','user.name','Loom fixture')
            git('config','user.email','fixture@example.org')
            git('remote','add','origin','https://github.com/0800x/Loom.git')
            (root/'obsolete.txt').write_text('Synthetic old history')
            git('add','.');git('commit','-qm','Earlier history')
            git('rm','-q','obsolete.txt')
            (root/'scripts').mkdir();(root/'release').mkdir();(root/'.github').mkdir()
            (root/'scripts/install-loom-node.sh').write_text('#!/bin/bash\necho fixture\n')
            (root/'install.sh').write_text("LOOM_INSTALL_REVISION='"+'1'*40+"'\nLOOM_INSTALL_ARCHIVE_SHA256='"+'2'*64+"'\nLOOM_INSTALL_BOOTSTRAP_SHA256='"+'3'*64+"'\n")
            (root/'release/node-channel.json').write_text(json.dumps({'repository':'0800x/Loom','branch':'main','revision':'1'*40,'sha256':'2'*64,'sequence':4}))
            git('add','.');git('commit','-qm','Reviewed source')
            reviewed=git('rev-parse','HEAD')
            (root/'.github/clean-history-request.json').write_text('{}')
            git('add','.');git('commit','-qm','Initialize release history')
            result=subprocess.run(['python3',str(SCRIPT),'--reviewed-revision',reviewed],cwd=root,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            info=json.loads(result.stdout.splitlines()[-1])
            self.assertEqual(git('rev-list','--count',info['head']),'2')
            self.assertEqual(git('rev-parse',info['initialCommit']+'^{tree}'),git('rev-parse',reviewed+'^{tree}'))
            archive=subprocess.check_output(['git','archive','--format=tar',info['initialCommit']],cwd=root)
            self.assertEqual(hashlib.sha256(archive).hexdigest(),info['sourceDigest'])
            channel=json.loads(git('show',info['head']+':release/node-channel.json'))
            self.assertEqual(channel['revision'],info['initialCommit'])
            self.assertEqual(channel['sequence'],5)
            self.assertNotIn('obsolete.txt',git('ls-tree','-r','--name-only',info['head']))
            self.assertNotIn('.github/clean-history-request.json',git('ls-tree','-r','--name-only',info['head']))
            # Preparing the new objects must not itself move HEAD or publish.
            self.assertEqual(git('log','-1','--format=%s'),'Initialize release history')

if __name__=='__main__': unittest.main()
