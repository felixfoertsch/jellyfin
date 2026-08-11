#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
	printf 'usage: %s [releases-json]\n' "$0" >&2
	exit 2
fi

select_latest() {
	jq -er '
		def valid_published_at:
			(type == "string")
			and test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$")
			and (. as $value | try (fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ") == $value) catch false);

		if type != "array" then
			error("release response must be an array")
		elif all(.[]; (
			type == "object"
			and (.tag_name | type == "string" and length > 0)
			and (.draft | type == "boolean")
			and (.prerelease | type == "boolean")
			and (.published_at | valid_published_at)
		)) then
			.
		else
			error("release metadata is malformed")
		end
		| map(select(.draft == false))
		| sort_by(.published_at)
		| last
		| .tag_name
	' "$@"
}

if (( $# == 1 )); then
	select_latest "$1"
	exit
fi

api_url=${JELLYFIN_RELEASES_API_URL:-https://api.github.com/repos/jellyfin/jellyfin/releases?per_page=100}
headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
	headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

temp_dir=$(mktemp -d)
trap 'rm -rf "${temp_dir}"' EXIT
release_files=()
page=0

while [[ -n "${api_url}" ]]; do
	page=$((page + 1))
	headers_file="${temp_dir}/headers-${page}"
	release_file="${temp_dir}/releases-${page}.json"
	curl --fail --silent --show-error --location --dump-header "${headers_file}" --output "${release_file}" "${headers[@]}" "${api_url}"
	release_files+=("${release_file}")
	api_url=$(awk 'BEGIN { IGNORECASE = 1 } /^link:/ { count = split(substr($0, index($0, ":") + 1), links, ","); for (i = 1; i <= count; i++) if (links[i] ~ /rel="next"/) { match(links[i], /<[^>]+>/); print substr(links[i], RSTART + 1, RLENGTH - 2); exit } }' "${headers_file}")
done

jq -s 'add' "${release_files[@]}" | select_latest
