#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
	printf 'usage: %s repository tag\n' "$0" >&2
	exit 2
fi

repository=$1
tag=$2
curl_bin=${CURL_BIN:-curl}
token=$(
	"${curl_bin}" --fail --silent --show-error --location \
		"https://ghcr.io/token?scope=repository:${repository}:pull" \
		| jq -er '.token'
)
status=$(
	"${curl_bin}" --silent --show-error --output /dev/null --write-out '%{http_code}' \
		-H "Authorization: Bearer ${token}" \
		-H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
		"https://ghcr.io/v2/${repository}/manifests/${tag}"
)

case "${status}" in
	200)
		printf 'true\n'
		;;
	404)
		printf 'false\n'
		;;
	*)
		printf 'GHCR returned HTTP %s for %s:%s\n' "${status}" "${repository}" "${tag}" >&2
		exit 1
		;;
esac
