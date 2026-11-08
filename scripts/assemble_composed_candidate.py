#!/usr/bin/env python3
"""Assemble a Loom release from separately verified client and Node build runs."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import release

CLIENT_SPECS = (
    ("Loom-0.6.0-android", "android", "armeabi-v7a,arm64-v8a,x86_64", "existing-production-key"),
    ("Loom-0.6.0-linux-x64", "linux", "x64", "unsigned-engineering"),
    ("Loom-0.6.0-windows-x64", "windows", "x64", "unsigned-engineering"),
    ("Loom-0.6.0-macos-arm64", "macos", "arm64", "adhoc-engineering"),
    ("Loom-0.6.0-macos-x64", "macos", "x64", "adhoc-engineering"),
)
NODE_SPECS = (
    ("Loom-0.6.0-node-linux-amd64", "node-linux", "amd64", "unsigned-engineering"),
    ("Loom-0.6.0-node-linux-arm64", "node-linux", "arm64", "unsigned-engineering"),
    ("Loom-0.6.0-node-windows-amd64", "node-windows", "amd64", "unsigned-engineering"),
)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verify_checksums(directory):
    directory = Path(directory)
    checksum_file = directory / "SHA256SUMS"
    if not checksum_file.is_file():
        raise ValueError("Missing SHA256SUMS: " + str(directory))
    expected = {}
    for line in checksum_file.read_text().splitlines():
        parts = line.split("  ", 1)
        if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{64}", parts[0]):
            raise ValueError("Malformed checksum entry in " + str(checksum_file))
        name = parts[1]
        if Path(name).name != name or name in expected:
            raise ValueError("Unsafe or duplicate checksum entry: " + name)
        expected[name] = parts[0]
    actual = {path.name for path in directory.iterdir() if path.is_file() and path.name != "SHA256SUMS"}
    if set(expected) != actual:
        raise ValueError("SHA256SUMS entries do not match artifact files in " + str(directory))
    for name, checksum in expected.items():
        if digest(directory / name) != checksum:
            raise ValueError("Checksum mismatch: " + str(directory / name))


def verify_artifact(directory, expected_platform, expected_architecture, expected_signing, expected_revision):
    directory = Path(directory)
    if not directory.is_dir():
        raise ValueError("Missing downloaded build artifact: " + str(directory))
    if any(path.is_symlink() or not path.is_file() for path in directory.iterdir()):
        raise ValueError("Unexpected directory, symlink, or non-file in artifact: " + str(directory))
    manifest_path = directory / "build-manifest.json"
    if not manifest_path.is_file():
        raise ValueError("Missing build-manifest.json in " + str(directory))
    manifest = json.loads(manifest_path.read_text())
    required = {
        "product": "Loom",
        "version": release.version()["version"],
        "revision": expected_revision,
        "platform": expected_platform,
        "architecture": expected_architecture,
        "signing": expected_signing,
    }
    for key, value in required.items():
        if manifest.get(key) != value:
            raise ValueError(
                "Artifact metadata mismatch for " + key + " in " + str(directory)
                + ": expected " + str(value) + ", got " + str(manifest.get(key))
            )
    if not re.fullmatch(r"[0-9a-f]{40}", str(manifest.get("tree", ""))):
        raise ValueError("Invalid source tree in " + str(manifest_path))
    if not isinstance(manifest.get("toolchains"), dict) or not manifest["toolchains"]:
        raise ValueError("Missing toolchain provenance in " + str(manifest_path))
    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries:
        raise ValueError("Missing artifact file list in " + str(manifest_path))
    names = set()
    for item in entries:
        name = item.get("name", "")
        if not name or Path(name).name != name or name in names:
            raise ValueError("Unsafe or duplicate artifact member: " + str(name))
        names.add(name)
        path = directory / name
        if not path.is_file() or path.stat().st_size != item.get("size"):
            raise ValueError("Artifact size mismatch: " + str(path))
        if digest(path) != item.get("sha256"):
            raise ValueError("Artifact digest mismatch: " + str(path))
    actual_names = {path.name for path in directory.iterdir()}
    if actual_names != names | {"build-manifest.json", "SHA256SUMS"}:
        raise ValueError("Artifact contains missing or unmanifested files: " + str(directory))
    verify_checksums(directory)
    return manifest


def compose(client_source, node_source, destination, client_revision, node_revision,
            current_revision, current_tree, client_run_id, node_run_id, validation_run_id):
    if release.version()["version"] != "0.6.0":
        raise ValueError("This saved-artifact composer is restricted to Loom 0.6.0")
    for label, value in (
        ("client revision", client_revision), ("Node revision", node_revision),
        ("current revision", current_revision), ("current tree", current_tree),
    ):
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            raise ValueError("Invalid " + label)
    for label, value in (
        ("client source run ID", client_run_id), ("Node source run ID", node_run_id),
        ("validation run ID", validation_run_id),
    ):
        if not str(value).isdigit():
            raise ValueError("Invalid " + label)

    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise ValueError("Candidate destination must be empty")

    builds = []
    for specs, source, source_revision in (
        (CLIENT_SPECS, Path(client_source), client_revision),
        (NODE_SPECS, Path(node_source), node_revision),
    ):
        for artifact_name, platform, architecture, signing in specs:
            manifest = verify_artifact(
                source / artifact_name, platform, architecture, signing, source_revision
            )
            slug = platform + "-" + architecture.replace(",", "-")
            target = destination / slug
            shutil.copytree(source / artifact_name, target)
            builds.append(manifest)

    aggregate = {
        "product": "Loom",
        "version": release.version()["version"],
        "revision": current_revision,
        "tree": current_tree,
        "node_manager_revision": node_revision,
        "reuse_node_manager_release": True,
        "provenance": {
            "strategy": "verified-composed-saved-artifacts",
            "client": {"revision": client_revision, "run_id": int(client_run_id)},
            "node": {"revision": node_revision, "run_id": int(node_run_id)},
            "validation": {"revision": current_revision, "run_id": int(validation_run_id)},
        },
        "builds": builds,
    }
    (destination / "BUILD-MANIFEST.json").write_text(json.dumps(aggregate, indent=2) + "\n")
    release.checksums(destination)
    print(json.dumps({
        "version": aggregate["version"],
        "release_revision": current_revision,
        "client_revision": client_revision,
        "node_revision": node_revision,
        "platform_builds": len(builds),
        "destination": str(destination),
    }, indent=2))
    return aggregate


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: assemble_composed_candidate.py CLIENT_ARTIFACTS NODE_ARTIFACTS DESTINATION")
    compose(
        sys.argv[1], sys.argv[2], sys.argv[3],
        os.environ["CLIENT_BUILD_REVISION"],
        os.environ["NODE_BUILD_REVISION"],
        os.environ["GITHUB_SHA"],
        release.git("rev-parse", "HEAD^{tree}"),
        os.environ["CLIENT_SOURCE_RUN_ID"],
        os.environ["NODE_SOURCE_RUN_ID"],
        os.environ["VALIDATION_RUN_ID"],
    )
