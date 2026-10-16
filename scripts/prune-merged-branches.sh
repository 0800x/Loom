#!/usr/bin/env bash
# Review mode by default. --apply deletes unchanged, fully merged remote refs.
set -euo pipefail
[[ $# == 0 || ($# == 1 && "$1" == --apply) ]] || { echo 'Usage: prune-merged-branches.sh [--apply]' >&2; exit 2; }
apply="${1:-}"
git rev-parse --show-toplevel >/dev/null
git fetch origin main
main=$(git rev-parse FETCH_HEAD)
branches=(
 'architecture-v2-unified|5b6899d92bc006422e53d1153d95fea3d6aa18eb'
 'codex/android-windows-ux-20261008|72ae4730deab0611ce37c21dcbfd7cd0dd81a43f'
 'codex/calls-location-ux-20261013|afbc89a3e73cc199623a3e5d7709d22d629eea1c'
 'codex/loom-rebrand|72036275833bbb8e277aa4c02740953e4cdd3eb4'
 'codex/ui-ux-coherence-20261013|ae3496ba5415f8a5beeac8f2306fc40ea332a6f1'
 'fix/offline-dtn-routing|4512fdd43c044cb4932430a4a0a11d7ffdc6aeff'
)
ready=()
for entry in "${branches[@]}"; do
 branch=${entry%|*}; expected=${entry#*|}
 actual=$(git ls-remote --heads origin "refs/heads/$branch" | awk '{print $1}')
 if [[ -z "$actual" ]]; then printf 'Already absent: %s\n' "$branch"; continue; fi
 [[ "$actual" == "$expected" ]] || { echo "Branch moved; preserved: $branch" >&2; exit 1; }
 git fetch origin "$branch"
 git merge-base --is-ancestor "$actual" "$main" || { echo "Not fully merged; preserved: $branch" >&2; exit 1; }
 ready+=("$entry")
 printf 'Fully merged, unchanged: %s\n' "$branch"
done
if [[ "$apply" != --apply ]]; then
 echo 'Review complete. Run again with --apply to delete the listed remote refs.'
 exit 0
fi
for entry in "${ready[@]}"; do
 branch=${entry%|*}; expected=${entry#*|}
 git push --force-with-lease="refs/heads/$branch:$expected" origin ":refs/heads/$branch"
done
echo 'Unmerged branches and local branches were preserved. History was not rewritten.'
