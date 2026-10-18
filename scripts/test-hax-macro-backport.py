#!/usr/bin/env python3
"""Compile runtime annotations and reject malformed Hax extraction annotations.

The extraction-only implementation requires nightly, as upstream 0.3.7 does.
--compare-upstream compares error messages and primary source spans too.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--macro-path', type=Path, default=ROOT / 'third_party/hax-lib-macros')
parser.add_argument('--compare-upstream', type=Path)
parser.add_argument('--nightly', default='nightly-2026-10-17')
args = parser.parse_args()
manifest = tomllib.loads((args.macro_path / 'Cargo.toml').read_text())
assert all('proc-macro-error2' not in t.get('dependencies', {})
           for t in manifest.get('target', {}).values()), 'Unmaintained diagnostic dependency remains'

unchanged_sources = {'impl_fn_decoration.rs': '40abbc808bdda92422bc2b314a722a031b16ad93a33c441869816e3ad29ff177', 'quote.rs': '8c2012c74ed3880c29fb55f74d332980479291d5484cea1334d7622d9201b863', 'hax_paths.rs': '3bdedd676bb227a055a057e9fd9d38e2b435270a0417915c5f851d8e9af91c68', 'rewrite_self.rs': 'e51dbf7e00b81359118703e725012cc1d3e1d7a6904df049bf7af0b087c90221', 'utils.rs': 'e4c92c9954cc2721ef15ce464ee70ca50cdd7a54f207949c2b6a42d857f4cb94', 'syn_ext.rs': 'b0cb0918b0fb7c8a43d9eb20d52edddfb9b2fdad55e6be20665303ea8128ceef', 'dummy.rs': '6f1d02497342310f83935a8079ae7aa15a5e39e5b8723c320f175e3832bfb5e1', 'lib.rs': '20e4abda602341ce6a7c2487f613168a9d87f761a7169bd6eafc448c3f751343'}
for name, expected in unchanged_sources.items():
    assert hashlib.sha256((args.macro_path / "src" / name).read_bytes()).hexdigest() == expected, name

cases = [
    ('#[hax_lib_macros::fstar_verification_status(invalid)]\nfn sample() {}', 'Expected `lax` or `panic_free`'),
    ('#[hax_lib_macros::lemma]\nfn sample() {}', 'A lemma is expected to return'),
    ('#[hax_lib_macros::refinement_type(|x| true)]\nstruct Sample { x: u32 }', 'Expected a newtype'),
    ('#[hax_lib_macros::refinement_type(|x| true)]\nstruct Sample(pub u32);', 'This field was expected to be private'),
    ('#[hax_lib_macros::fstar_before(invalid, "text")]\nfn sample() {}', 'Expected `impl`, `both` or `interface`'),
]

with tempfile.TemporaryDirectory(prefix='loom-hax-regression-') as temp:
    project = Path(temp)
    (project / 'src').mkdir()
    source = project / 'src/lib.rs'
    env = os.environ.copy()
    env['CARGO_TARGET_DIR'] = str(project / 'target')

    def run(macro_path, text, extraction=False, test=False):
        (project / 'Cargo.toml').write_text(
            '[package]\nname="loom_hax_regression"\nversion="0.0.0"\nedition="2021"\n'
            '[dependencies]\nhax-lib-macros={path=' + json.dumps(str(macro_path.resolve())) + '}\n')
        source.write_text(text + '\n')
        child_env = env.copy()
        if extraction:
            child_env['RUSTFLAGS'] = child_env.get('RUSTFLAGS', '') + ' --cfg hax'
        command = ['cargo'] + (['+' + args.nightly] if extraction else [])
        command += ['test' if test else 'check', '--message-format=json']
        result = subprocess.run(command, cwd=project, env=child_env, capture_output=True, text=True)
        messages = []
        for line in result.stdout.splitlines():
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get('reason') == 'compiler-message':
                message = entry['message']
                if message['level'] == 'error':
                    spans = [(s['line_start'], s['column_start'], s['line_end'], s['column_end'])
                             for s in message['spans'] if s['is_primary']]
                    messages.append((message['message'], spans))
        return result, messages

    ordinary = '''
#[hax_lib_macros::requires(x > 0)]
#[hax_lib_macros::ensures(|result| result == x + 1)]
fn increment(x: u32) -> u32 { x + 1 }
#[test] fn annotations_preserve_runtime() { assert_eq!(increment(41), 42); }
'''
    result, _ = run(args.macro_path, ordinary, test=True)
    assert result.returncode == 0, result.stdout + result.stderr
    for text, expected in cases:
        result, errors = run(args.macro_path, text, extraction=True)
        assert result.returncode != 0 and any(expected in e[0] for e in errors), result.stdout + result.stderr
        assert not any('panicked' in e[0] for e in errors), errors
        if args.compare_upstream:
            before, original = run(args.compare_upstream, text, extraction=True)
            assert before.returncode != 0 and original == errors, (original, errors)
    print('PASS: runtime annotation test and five fail-closed extraction diagnostic cases'
          + ('; messages and primary spans match upstream 0.3.7' if args.compare_upstream else ''))
