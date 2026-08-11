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

if [[ -z "${upstream_tag}" || -z "${upstream_name}" || -z "${target_sha}" ]]; then
	printf 'release arguments must not be empty\n' >&2
	exit 2
fi
if [[ "${prerelease}" != "true" && "${prerelease}" != "false" ]]; then
	printf 'prerelease must be true or false\n' >&2
	exit 2
fi

release_tag=${upstream_tag}-legacy-filter-query
if gh release view "${release_tag}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
	printf 'existing\n'
	exit
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

gh "${args[@]}" <<NOTES
This release builds [Jellyfin ${upstream_name}](https://github.com/jellyfin/jellyfin/releases/tag/${upstream_tag}) with the verified [legacy filter query fix](https://github.com/${GITHUB_REPOSITORY}/commit/${FIX_SHA}).

- Immutable image: \`${IMAGE_REPOSITORY}:legacy-filter-query-${upstream_tag}\`
- Rolling image: \`${IMAGE_REPOSITORY}:legacy-filter-query\`
- Platform: \`linux/amd64\`

Unraid users should track the rolling image tag. Apply the update manually from Docker Manager.
NOTES

printf 'created\n'
