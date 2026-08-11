#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
	printf 'usage: %s [releases-json]\n' "$0" >&2
	exit 2
fi

if (( $# == 1 )); then
	jq -er \
		'[.[] | select(.draft == false and .published_at != null)] | sort_by(.published_at) | last | .tag_name' \
		"$1"
	exit
fi

api_url=${JELLYFIN_RELEASES_API_URL:-https://api.github.com/repos/jellyfin/jellyfin/releases?per_page=100}
headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
	headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

curl --fail --silent --show-error --location "${headers[@]}" "${api_url}" \
	| jq -er '[.[] | select(.draft == false and .published_at != null)] | sort_by(.published_at) | last | .tag_name'
