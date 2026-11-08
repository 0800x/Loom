#!/usr/bin/env python3
"""Fail-closed verification for the saved Loom 0.6.0 build and validate-only runs."""
import json
import os
import re
import subprocess

REPOSITORY = "0800x/Loom"
WORKFLOW = ".github/workflows/loom-alpha.yml"
CLIENT_REVISION = "ab1701beb926cbfe00f11199185282799a9d65d7"
NODE_REVISION = "751ec9e0cd110b6d74aaa3a0dd9a62846ee52f4f"
MANAGER_TAG = "node-manager-0.6.0-751ec9e0cd11"
CLIENT_ARTIFACTS = {
    "Loom-0.6.0-android", "Loom-0.6.0-linux-x64", "Loom-0.6.0-windows-x64",
    "Loom-0.6.0-macos-arm64", "Loom-0.6.0-macos-x64",
}
NODE_ARTIFACTS = {
    "Loom-0.6.0-node-linux-amd64", "Loom-0.6.0-node-linux-arm64",
    "Loom-0.6.0-node-windows-amd64",
}
MANAGER_ASSETS = {
    "Loom-0.6.0-manager-linux-amd64", "Loom-0.6.0-manager-linux-arm64",
    "Loom-node-linux-amd64-build-manifest.json", "Loom-node-linux-arm64-build-manifest.json",
    "node-channel.json", "loom-install.sh", "loom-install.sh.sha256",
}
CLIENT_LINT_ONLY = {
    "apps/loom/lib/features/calls/presentation/active_call_screen.dart",
    "apps/loom/lib/features/groups/presentation/group_call_screen.dart",
    "apps/loom/lib/features/settings/presentation/maps_settings_screen.dart",
}


def api(path):
    raw = subprocess.check_output(["gh", "api", path], text=True)
    return json.loads(raw)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def get_run(run_id):
    require(str(run_id).isdigit(), "Actions run ID must be numeric")
    return api("repos/" + REPOSITORY + "/actions/runs/" + str(run_id))


def get_jobs(run_id):
    return api("repos/" + REPOSITORY + "/actions/runs/" + str(run_id) + "/jobs?per_page=100")["jobs"]


def check_run_identity(run, expected_sha, expected_event):
    require(run.get("path", "").split("@", 1)[0] == WORKFLOW, "Unexpected workflow for run " + str(run["id"]))
    require(run.get("head_branch") == "main", "Run was not created from main: " + str(run["id"]))
    require(run.get("head_sha") == expected_sha, "Unexpected source revision for run " + str(run["id"]))
    require(run.get("event") == expected_event, "Unexpected trigger for run " + str(run["id"]))
    require(run.get("status") == "completed", "Run is not complete: " + str(run["id"]))


def require_success(jobs, name):
    matches = [job for job in jobs if job.get("name") == name]
    require(len(matches) == 1 and matches[0].get("conclusion") == "success",
            "Required job did not succeed exactly once: " + name)


def require_artifacts(run_id, expected_names):
    payload = api("repos/" + REPOSITORY + "/actions/runs/" + str(run_id) + "/artifacts?per_page=100")
    actual = {}
    for artifact in payload.get("artifacts", []):
        actual[artifact["name"]] = artifact
    missing = expected_names - set(actual)
    require(not missing, "Missing source artifacts: " + ", ".join(sorted(missing)))
    expired = [name for name in expected_names if actual[name].get("expired")]
    require(not expired, "Expired source artifacts: " + ", ".join(sorted(expired)))


def require_ancestor(source_revision, current_revision):
    comparison = api(
        "repos/" + REPOSITORY + "/compare/" + source_revision + "..." + current_revision
    )
    require(comparison.get("status") in ("ahead", "identical") and comparison.get("behind_by") == 0,
            "Saved build revision is not an ancestor of the current main revision: " + source_revision)
    return comparison


def resolve_tag_commit(tag):
    ref = api("repos/" + REPOSITORY + "/git/ref/tags/" + tag)["object"]
    target = ref
    if target["type"] == "tag":
        target = api("repos/" + REPOSITORY + "/git/tags/" + target["sha"])["object"]
    require(target.get("type") == "commit", "Node Manager tag does not resolve to a commit")
    return target["sha"]


def main():
    client_run_id = os.environ["CLIENT_SOURCE_RUN_ID"]
    node_run_id = os.environ["NODE_SOURCE_RUN_ID"]
    validation_run_id = os.environ["VALIDATION_RUN_ID"]
    current_revision = os.environ["GITHUB_SHA"]

    main_sha = api("repos/" + REPOSITORY + "/git/ref/heads/main")["object"]["sha"]
    require(main_sha == current_revision, "Publisher must run on the current main HEAD")

    client_run = get_run(client_run_id)
    check_run_identity(client_run, CLIENT_REVISION, "push")
    client_jobs = get_jobs(client_run_id)
    require_success(client_jobs, "preflight")
    require_success(client_jobs, "android")
    desktop_jobs = [job for job in client_jobs if job.get("name", "").startswith("desktop (")]
    require(len(desktop_jobs) == 4 and all(job.get("conclusion") == "success" for job in desktop_jobs),
            "All four saved desktop builds must have succeeded")
    require_artifacts(client_run_id, CLIENT_ARTIFACTS)

    node_run = get_run(node_run_id)
    check_run_identity(node_run, NODE_REVISION, "push")
    require(node_run.get("conclusion") == "success", "Node-only source run did not succeed")
    node_jobs = get_jobs(node_run_id)
    for name in ("preflight", "node-check", "node-images", "node-publish"):
        require_success(node_jobs, name)
    node_build_jobs = [job for job in node_jobs if job.get("name", "").startswith("node (")]
    require(len(node_build_jobs) == 3 and all(job.get("conclusion") == "success" for job in node_build_jobs),
            "All three saved Node builds must have succeeded")
    require_artifacts(node_run_id, NODE_ARTIFACTS)

    validation_run = get_run(validation_run_id)
    check_run_identity(validation_run, current_revision, "workflow_dispatch")
    require(validation_run.get("conclusion") == "success", "Current-main validation run did not succeed")
    validation_jobs = get_jobs(validation_run_id)
    require_success(validation_jobs, "preflight")
    require_success(validation_jobs, "validate")
    unexpected = [
        job["name"] for job in validation_jobs
        if job.get("name") not in ("preflight", "validate") and job.get("conclusion") != "skipped"
    ]
    require(not unexpected, "Validation run executed non-validation jobs: " + ", ".join(unexpected))

    client_comparison = require_ancestor(CLIENT_REVISION, current_revision)
    product_changes = {
        item["filename"] for item in client_comparison.get("files", [])
        if item["filename"].startswith(("apps/", "packages/", "native/"))
    }
    require(product_changes == CLIENT_LINT_ONLY,
            "Client source changed beyond the three analyzer-only cleanup files: " + ", ".join(sorted(product_changes ^ CLIENT_LINT_ONLY)))

    node_comparison = require_ancestor(NODE_REVISION, current_revision)
    node_source_drift = [
        item["filename"] for item in node_comparison.get("files", [])
        if item["filename"].startswith(("services/", "tools/loom_node_manager/"))
    ]
    require(not node_source_drift,
            "Node runtime or Manager source changed after the saved Node build: " + ", ".join(node_source_drift))

    manager_release = api("repos/" + REPOSITORY + "/releases/tags/" + MANAGER_TAG)
    require(manager_release.get("tag_name") == MANAGER_TAG and not manager_release.get("draft")
            and manager_release.get("prerelease"), "Expected published Node Manager release is unavailable")
    require(resolve_tag_commit(MANAGER_TAG) == NODE_REVISION,
            "Published Node Manager release does not point to the verified Node source revision")
    manager_names = {asset["name"] for asset in manager_release.get("assets", [])}
    require(manager_names == MANAGER_ASSETS,
            "Published Node Manager release contains an unexpected asset set")

    print(json.dumps({
        "client_source_run": int(client_run_id),
        "client_revision": CLIENT_REVISION,
        "node_source_run": int(node_run_id),
        "node_revision": NODE_REVISION,
        "validation_run": int(validation_run_id),
        "validated_revision": current_revision,
        "client_build_jobs": "success",
        "node_build_jobs": "success",
        "validation_jobs": "success; all package-build jobs skipped",
        "node_manager_release": MANAGER_TAG,
    }, indent=2))


if __name__ == "__main__":
    main()
