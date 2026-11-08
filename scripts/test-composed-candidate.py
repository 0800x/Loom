#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import assemble_composed_candidate as candidate


class ComposedCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.clients = self.root / "clients"
        self.nodes = self.root / "nodes"
        self.output = self.root / "candidate"
        self.clients.mkdir()
        self.nodes.mkdir()
        self.client_revision = "a" * 40
        self.node_revision = "b" * 40
        self.current_revision = "c" * 40
        self.current_tree = "d" * 40
        self.client_run_id = "1001"
        self.node_run_id = "1002"
        self.validation_run_id = "1003"
        for spec in candidate.CLIENT_SPECS:
            self.make_artifact(self.clients, spec, self.client_revision)
        for spec in candidate.NODE_SPECS:
            self.make_artifact(self.nodes, spec, self.node_revision)

    def tearDown(self):
        self.temp.cleanup()

    def make_artifact(self, parent, spec, revision):
        artifact_name, platform, architecture, signing = spec
        directory = parent / artifact_name
        directory.mkdir()
        payload = (artifact_name + " payload").encode()
        audit = b'{"findings":[]}\n'
        (directory / "payload.bin").write_bytes(payload)
        (directory / "identity-audit.json").write_bytes(audit)
        files = []
        for name in ("payload.bin", "identity-audit.json"):
            path = directory / name
            files.append({
                "name": name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "size": path.stat().st_size,
            })
        manifest = {
            "product": "Loom",
            "version": candidate.release.version()["version"],
            "revision": revision,
            "tree": "e" * 40,
            "platform": platform,
            "architecture": architecture,
            "signing": signing,
            "toolchains": {"fixture": "test"},
            "files": files,
        }
        (directory / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        candidate.release.checksums(directory)

    def compose(self):
        return candidate.compose(
            self.clients, self.nodes, self.output,
            self.client_revision, self.node_revision,
            self.current_revision, self.current_tree,
            self.client_run_id, self.node_run_id, self.validation_run_id,
        )

    def test_composes_eight_platform_manifests_and_records_component_revisions(self):
        manifest = self.compose()
        self.assertEqual(len(manifest["builds"]), 8)
        self.assertEqual(manifest["revision"], self.current_revision)
        self.assertEqual(manifest["node_manager_revision"], self.node_revision)
        self.assertTrue(manifest["reuse_node_manager_release"])
        self.assertEqual(manifest["provenance"]["client"]["revision"], self.client_revision)
        self.assertEqual(manifest["provenance"]["node"]["revision"], self.node_revision)
        self.assertEqual(manifest["provenance"]["validation"]["revision"], self.current_revision)
        self.assertTrue((self.output / "BUILD-MANIFEST.json").is_file())
        self.assertTrue((self.output / "SHA256SUMS").is_file())

    def test_rejects_an_artifact_modified_after_its_manifest_was_written(self):
        target = self.clients / candidate.CLIENT_SPECS[0][0] / "payload.bin"
        target.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "size mismatch|digest mismatch|Checksum mismatch"):
            self.compose()

    def test_rejects_a_client_artifact_from_an_unapproved_revision(self):
        manifest_path = self.clients / candidate.CLIENT_SPECS[0][0] / "build-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["revision"] = "f" * 40
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        candidate.release.checksums(manifest_path.parent)
        with self.assertRaisesRegex(ValueError, "Artifact metadata mismatch for revision"):
            self.compose()

    def test_rejects_unmanifested_files(self):
        extra = self.nodes / candidate.NODE_SPECS[0][0] / "unexpected.bin"
        extra.write_bytes(b"unexpected")
        with self.assertRaisesRegex(ValueError, "unmanifested files"):
            self.compose()


if __name__ == "__main__":
    unittest.main()
