#!/usr/bin/env bash
set -euo pipefail

git fetch --no-tags origin "refs/heads/$DEFAULT_BRANCH"
if [[ $GITHUB_REF != "refs/heads/$DEFAULT_BRANCH" || $GITHUB_SHA != "$(git rev-parse FETCH_HEAD)" ]]; then
	echo "::error::Start a new run on the current default branch to publish images."
	exit 1
fi

# A failed publication can change registry tags without advancing the Git branch.
# Ignore queued runs: the workflow-level lock prevents them publishing concurrently.
for event in push repository_dispatch workflow_dispatch; do
	latest=$(gh api --method GET "repos/$GITHUB_REPOSITORY/actions/workflows/joomengine.yml/runs" \
		-f branch="$DEFAULT_BRANCH" -f event="$event" -f status=completed -F per_page=1 \
		--jq '.workflow_runs[0].run_number // 0')
	if ((latest > GITHUB_RUN_NUMBER)); then
		echo "::error::A newer publication (run #$latest) has completed. Retry the newest publisher run."
		exit 1
	fi
done
