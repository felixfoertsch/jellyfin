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

assert_failure() {
	local fixture=$1
	local message=$2

	if "${ROOT_DIR}/scripts/select-latest-jellyfin-release.sh" "${fixture}" >/dev/null 2>&1; then
		printf 'FAIL: %s\n' "${message}" >&2
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
assert_failure "${TEMP_DIR}/empty.json" "empty eligible release set must fail"

cat > "${TEMP_DIR}/invalid-published-at.json" <<'JSON'
[
	{"tag_name":"v12.0.0","draft":false,"prerelease":false,"published_at":"not-a-timestamp"}
]
JSON
assert_failure "${TEMP_DIR}/invalid-published-at.json" "invalid published_at must fail"

cat > "${TEMP_DIR}/impossible-published-at.json" <<'JSON'
[
	{"tag_name":"v12.0.0","draft":false,"prerelease":false,"published_at":"2026-02-30T12:00:00Z"}
]
JSON
assert_failure "${TEMP_DIR}/impossible-published-at.json" "impossible published_at must fail"

cat > "${TEMP_DIR}/empty-published-at.json" <<'JSON'
[
	{"tag_name":"v12.0.0","draft":false,"prerelease":false,"published_at":""}
]
JSON
assert_failure "${TEMP_DIR}/empty-published-at.json" "empty published_at must fail"

cat > "${TEMP_DIR}/invalid-tag-name.json" <<'JSON'
[
	{"tag_name":42,"draft":false,"prerelease":false,"published_at":"2026-08-20T12:00:00Z"}
]
JSON
assert_failure "${TEMP_DIR}/invalid-tag-name.json" "non-string tag_name must fail"

cat > "${TEMP_DIR}/empty-tag-name.json" <<'JSON'
[
	{"tag_name":"","draft":false,"prerelease":false,"published_at":"2026-08-20T12:00:00Z"}
]
JSON
assert_failure "${TEMP_DIR}/empty-tag-name.json" "empty tag_name must fail"

mkdir -p "${TEMP_DIR}/bin"
cat > "${TEMP_DIR}/bin/curl" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

headers_file=
release_file=
url=
while (( $# > 0 )); do
	case "$1" in
		--dump-header)
			headers_file=$2
			shift 2
			;;
		--output)
			release_file=$2
			shift 2
			;;
		*)
			url=$1
			shift
			;;
	esac
done

case "${url}" in
	https://example.test/releases?page=1)
		printf 'HTTP/1.1 200 OK\r\nLink: <https://example.test/releases?page=2>; rel="next"\r\n\r\n' > "${headers_file}"
		printf '[{"tag_name":"v12.0.0","draft":false,"prerelease":false,"published_at":"2026-08-20T12:00:00Z"}]\n' > "${release_file}"
		;;
	https://example.test/releases?page=2)
		printf 'HTTP/1.1 200 OK\r\n\r\n' > "${headers_file}"
		printf '[{"tag_name":"v12.0.1","draft":false,"prerelease":false,"published_at":"2026-08-21T12:00:00Z"}]\n' > "${release_file}"
		;;
	*)
		printf 'FAIL: unexpected URL: %s\n' "${url}" >&2
		exit 1
		;;
esac
BASH
chmod +x "${TEMP_DIR}/bin/curl"

assert_equal \
	"v12.0.1" \
	"$(PATH="${TEMP_DIR}/bin:${PATH}" JELLYFIN_RELEASES_API_URL='https://example.test/releases?page=1' "${ROOT_DIR}/scripts/select-latest-jellyfin-release.sh")" \
	"pagination follows a capitalized Link header"

cat > "${TEMP_DIR}/curl" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *'/token?'* ]]; then
	if [[ ${MOCK_TOKEN_RESPONSE+x} ]]; then
		printf '%s\n' "${MOCK_TOKEN_RESPONSE}"
	else
		printf '{"token":"fixture-token"}\n'
	fi
	exit
fi

printf '%s' "${MOCK_REGISTRY_STATUS}"
BASH
chmod +x "${TEMP_DIR}/curl"

assert_equal \
	"true" \
	"$(CURL_BIN="${TEMP_DIR}/curl" MOCK_REGISTRY_STATUS=200 "${ROOT_DIR}/scripts/ghcr-tag-exists.sh" felixfoertsch/jellyfin legacy-filter-query-v12.0-rc5)" \
	"existing GHCR tag returns true"

assert_equal \
	"false" \
	"$(CURL_BIN="${TEMP_DIR}/curl" MOCK_REGISTRY_STATUS=404 "${ROOT_DIR}/scripts/ghcr-tag-exists.sh" felixfoertsch/jellyfin legacy-filter-query-v12.0-rc5)" \
	"missing GHCR tag returns false"

if CURL_BIN="${TEMP_DIR}/curl" MOCK_REGISTRY_STATUS=500 \
	"${ROOT_DIR}/scripts/ghcr-tag-exists.sh" felixfoertsch/jellyfin legacy-filter-query-v12.0-rc5 >/dev/null 2>&1; then
	printf 'FAIL: unexpected registry status must fail\n' >&2
	exit 1
fi

if malformed_token_output=$(CURL_BIN="${TEMP_DIR}/curl" MOCK_TOKEN_RESPONSE='{"token":123}' \
	MOCK_REGISTRY_STATUS=200 "${ROOT_DIR}/scripts/ghcr-tag-exists.sh" felixfoertsch/jellyfin legacy-filter-query-v12.0-rc5 2>&1); then
	printf 'FAIL: numeric GHCR token must fail\n' >&2
	exit 1
fi

if [[ "${malformed_token_output}" != *'GHCR token response must contain a non-empty string token'* ]]; then
	printf 'FAIL: numeric GHCR token error must be visible\n' >&2
	exit 1
fi

if CURL_BIN="${TEMP_DIR}/curl" MOCK_TOKEN_RESPONSE='{"token":""}' \
	MOCK_REGISTRY_STATUS=200 "${ROOT_DIR}/scripts/ghcr-tag-exists.sh" felixfoertsch/jellyfin legacy-filter-query-v12.0-rc5 >/dev/null 2>&1; then
	printf 'FAIL: empty GHCR token must fail\n' >&2
	exit 1
fi

workflow=${ROOT_DIR}/.github/workflows/build-legacy-filter-query-image.yml
if [[ ! -f "${workflow}" ]]; then
	printf 'FAIL: release workflow is missing\n' >&2
	exit 1
fi

if grep -Eq '\[\[[[:space:]]+-v[[:space:]]' "${BASH_SOURCE[0]}"; then
	printf 'FAIL: release automation tests use the Bash 4.2-only -v test\n' >&2
	exit 1
fi

for required in \
	'schedule:' \
	'workflow_dispatch:' \
	'scripts/select-latest-jellyfin-release.sh' \
	'scripts/ghcr-tag-exists.sh' \
	'repository: jellyfin/jellyfin' \
	'repository: jellyfin/jellyfin-web' \
	'git cherry-pick' \
	'legacy-filter-query-${{ steps.release.outputs.tag }}' \
	'ghcr.io/felixfoertsch/jellyfin:legacy-filter-query'
do
	if ! grep -Fq -- "${required}" "${workflow}"; then
		printf 'FAIL: workflow lacks required contract: %s\n' "${required}" >&2
		exit 1
	fi
done

build_tags=$(awk '
	/^      - name: Build and push$/ { in_build = 1 }
	in_build && /^          tags: \|$/ { in_tags = 1; next }
	in_tags && /^          labels: \|$/ { exit }
	in_tags { print }
' "${workflow}")
if grep -Eq '^[[:space:]]*ghcr\.io/felixfoertsch/jellyfin:legacy-filter-query[[:space:]]*$' <<< "${build_tags}"; then
	printf 'FAIL: workflow build tags include the rolling tag\n' >&2
	exit 1
fi

for required in \
	'name: Promote rolling image tag' \
	"if: steps.image.outputs.exists == 'true' || steps.build.outcome == 'success'" \
	'docker buildx imagetools create' \
	'--prefer-index=false' \
	'--tag "${IMAGE_REPOSITORY}:legacy-filter-query"' \
	'"${IMAGE_REPOSITORY}:legacy-filter-query-${RELEASE_TAG}"' \
	'Existing immutable image: rolling tag promotion succeeded' \
	'Publication failed or was skipped' \
	'Rolling promotion failed or was skipped'
do
	if ! grep -Fq -- "${required}" "${workflow}"; then
		printf 'FAIL: workflow lacks promotion contract: %s\n' "${required}" >&2
		exit 1
	fi
done

promotion_line=$(grep -nF 'name: Promote rolling image tag' "${workflow}" | cut -d: -f1)
build_line=$(grep -nF 'name: Build and push' "${workflow}" | cut -d: -f1)
if (( promotion_line <= build_line )); then
	printf 'FAIL: workflow promotes the rolling tag before immutable publication\n' >&2
	exit 1
fi

printf 'release automation tests passed\n'
