#!/usr/bin/env bash
set -euo pipefail

if (( $# != 4 )); then
	printf 'usage: %s upstream-tag upstream-name prerelease target-sha\n' "$0" >&2
	exit 2
fi

upstream_tag=$1
upstream_name=$2
prerelease=$3
target_sha=$4
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
: "${FIX_SHA:?FIX_SHA is required}"

for value in "${upstream_tag}" "${upstream_name}" "${prerelease}" "${target_sha}"; do
	if [[ -z "${value}" || "${value}" =~ [[:cntrl:]] ]]; then
		printf 'release arguments must not be empty or contain control characters\n' >&2
		exit 2
	fi
done
if [[ "${prerelease}" != "true" && "${prerelease}" != "false" ]]; then
	printf 'prerelease must be true or false\n' >&2
	exit 2
fi

release_tag=${upstream_tag}-legacy-filter-query

lookup_response=$(mktemp)
trap 'rm -f "${lookup_response}"' EXIT
if gh api --include "repos/${GITHUB_REPOSITORY}/releases/tags/${release_tag}" > "${lookup_response}" 2>&1; then
	printf 'existing\n'
	exit
fi

lookup_status=$(awk '/^HTTP\/[0-9.]+ [0-9][0-9][0-9] / { print $2; exit }' "${lookup_response}")
if [[ "${lookup_status}" != "404" ]]; then
	cat "${lookup_response}" >&2
	printf 'failed to look up GitHub Release %s\n' "${release_tag}" >&2
	exit 1
fi

args=(
	release create "${release_tag}"
	--repo "${GITHUB_REPOSITORY}"
	--target "${target_sha}"
	--title "Jellyfin ${upstream_name} + legacy filter query fix"
	--notes-file -
)
if [[ "${prerelease}" == "true" ]]; then
	args+=(--prerelease)
fi

gh "${args[@]}" >/dev/null <<NOTES
This release builds [Jellyfin ${upstream_name}](https://github.com/jellyfin/jellyfin/releases/tag/${upstream_tag}) with the verified [legacy filter query fix](https://github.com/${GITHUB_REPOSITORY}/commit/${FIX_SHA}).

- Immutable image: \`${IMAGE_REPOSITORY}:legacy-filter-query-${upstream_tag}\`
- Rolling image: \`${IMAGE_REPOSITORY}:legacy-filter-query\`
- Platform: \`linux/amd64\`

Unraid users should track the rolling image tag. Apply the update manually from Docker Manager.
NOTES

printf 'created\n'
