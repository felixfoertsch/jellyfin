#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

assert_equal() {
	local expected=$1
	local actual=$2
	local message=$3

	if [[ "${actual}" != "${expected}" ]]; then
		printf 'FAIL: %s\nexpected: %s\nactual: %s\n' "${message}" "${expected}" "${actual}" >&2
		exit 1
	fi
}

cat > "${TEMP_DIR}/rc-newest.json" <<'JSON'
[
	{"tag_name":"v12.0-rc4","draft":false,"prerelease":true,"published_at":"2026-08-02T22:23:46Z"},
	{"tag_name":"v10.11.11","draft":false,"prerelease":false,"published_at":"2026-06-06T16:18:54Z"},
	{"tag_name":"v12.0-rc5","draft":false,"prerelease":true,"published_at":"2026-08-11T00:33:56Z"}
]
JSON

assert_equal \
	"v12.0-rc5" \
	"$("${ROOT_DIR}/scripts/select-latest-jellyfin-release.sh" "${TEMP_DIR}/rc-newest.json")" \
	"newest prerelease wins regardless of API order"

cat > "${TEMP_DIR}/stable-newest.json" <<'JSON'
[
	{"tag_name":"v12.0-rc5","draft":false,"prerelease":true,"published_at":"2026-08-11T00:33:56Z"},
	{"tag_name":"v12.0.0","draft":false,"prerelease":false,"published_at":"2026-08-20T12:00:00Z"}
]
JSON

assert_equal \
	"v12.0.0" \
	"$("${ROOT_DIR}/scripts/select-latest-jellyfin-release.sh" "${TEMP_DIR}/stable-newest.json")" \
	"newer stable release wins"

cat > "${TEMP_DIR}/draft.json" <<'JSON'
[
	{"tag_name":"v12.0.0","draft":true,"prerelease":false,"published_at":"2026-08-20T12:00:00Z"},
	{"tag_name":"v12.0-rc5","draft":false,"prerelease":true,"published_at":"2026-08-11T00:33:56Z"}
]
JSON

assert_equal \
	"v12.0-rc5" \
	"$("${ROOT_DIR}/scripts/select-latest-jellyfin-release.sh" "${TEMP_DIR}/draft.json")" \
	"draft releases are ignored"

printf '[]\n' > "${TEMP_DIR}/empty.json"
if "${ROOT_DIR}/scripts/select-latest-jellyfin-release.sh" "${TEMP_DIR}/empty.json" >/dev/null 2>&1; then
	printf 'FAIL: empty eligible release set must fail\n' >&2
	exit 1
fi
