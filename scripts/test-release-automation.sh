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

if [[ ${MOCK_CURL_ARGS_FILE+x} ]]; then
	printf '%s\n' "$@" > "${MOCK_CURL_ARGS_FILE}"
fi

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

curl_args=${TEMP_DIR}/ghcr-curl-args
CURL_BIN="${TEMP_DIR}/curl" \
	MOCK_CURL_ARGS_FILE="${curl_args}" \
	MOCK_REGISTRY_STATUS=200 \
	"${ROOT_DIR}/scripts/ghcr-tag-exists.sh" \
	felixfoertsch/jellyfin legacy-filter-query-v12.0-rc5 >/dev/null

if ! grep -Fq 'application/vnd.docker.distribution.manifest.v2+json' "${curl_args}"; then
	printf 'FAIL: GHCR probe does not request Docker Schema 2\n' >&2
	exit 1
fi
if grep -Fq 'application/vnd.oci.' "${curl_args}"; then
	printf 'FAIL: GHCR probe accepts OCI media types that Unraid rejects\n' >&2
	exit 1
fi

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

mkdir -p "${TEMP_DIR}/release-bin"
cat > "${TEMP_DIR}/release-bin/gh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_GH_LOG:?MOCK_GH_LOG is required}"
command=$1
printf '%s' "${command}" >> "${MOCK_GH_LOG}"
shift
for arg in "$@"; do
	printf ' %s' "${arg}" >> "${MOCK_GH_LOG}"
done
printf '\n' >> "${MOCK_GH_LOG}"

if [[ "${command}" == "api" ]]; then
	: "${MOCK_LOOKUP_STATUS:?MOCK_LOOKUP_STATUS is required}"
	printf 'HTTP/2.0 %s Fixture\n\n' "${MOCK_LOOKUP_STATUS}"
	if [[ "${MOCK_LOOKUP_STATUS}" == "200" ]]; then
		exit
	fi
	exit 1
fi
if [[ "$*" == create\ * ]]; then
	: "${MOCK_NOTES_FILE:?MOCK_NOTES_FILE is required}"
	cat > "${MOCK_NOTES_FILE}"
	exit
fi

printf 'unexpected gh command\n' >&2
exit 1
BASH
chmod +x "${TEMP_DIR}/release-bin/gh"

release_log=${TEMP_DIR}/release.log
release_notes=${TEMP_DIR}/release-notes.md
result=$(
	PATH="${TEMP_DIR}/release-bin:${PATH}" \
	MOCK_GH_LOG="${release_log}" \
	MOCK_NOTES_FILE="${release_notes}" \
	MOCK_LOOKUP_STATUS=404 \
	GH_TOKEN=fixture \
	GITHUB_REPOSITORY=felixfoertsch/jellyfin \
	IMAGE_REPOSITORY=ghcr.io/felixfoertsch/jellyfin \
	FIX_SHA=a44a26b287a328927c6d7bffa0a253b0d1a807dd \
	"${ROOT_DIR}/scripts/publish-patched-release.sh" \
	v12.0-rc5 '12.0 RC5' true fixture-target
)
assert_equal "created" "${result}" "missing RC release is created"

for required in \
	'release create v12.0-rc5-legacy-filter-query' \
	'--title Jellyfin 12.0 RC5 + legacy filter query fix' \
	'--target fixture-target' \
	'--prerelease'
do
	if ! grep -Fq -- "${required}" "${release_log}"; then
		printf 'FAIL: RC release command lacks: %s\n' "${required}" >&2
		exit 1
	fi
done

for required in \
	'https://github.com/jellyfin/jellyfin/releases/tag/v12.0-rc5' \
	'ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-v12.0-rc5' \
	'ghcr.io/felixfoertsch/jellyfin:legacy-filter-query' \
	'https://github.com/felixfoertsch/jellyfin/commit/a44a26b287a328927c6d7bffa0a253b0d1a807dd' \
	'linux/amd64' \
	'Apply the update manually'
do
	if ! grep -Fq -- "${required}" "${release_notes}"; then
		printf 'FAIL: release notes lack: %s\n' "${required}" >&2
		exit 1
	fi
done

: > "${release_log}"
PATH="${TEMP_DIR}/release-bin:${PATH}" \
	MOCK_GH_LOG="${release_log}" \
	MOCK_NOTES_FILE="${release_notes}" \
	MOCK_LOOKUP_STATUS=404 \
	GH_TOKEN=fixture \
	GITHUB_REPOSITORY=felixfoertsch/jellyfin \
	IMAGE_REPOSITORY=ghcr.io/felixfoertsch/jellyfin \
	FIX_SHA=a44a26b287a328927c6d7bffa0a253b0d1a807dd \
	"${ROOT_DIR}/scripts/publish-patched-release.sh" \
	v12.0.0 '12.0.0' false fixture-target >/dev/null
if grep -Fq -- '--prerelease' "${release_log}"; then
	printf 'FAIL: stable release is marked prerelease\n' >&2
	exit 1
fi

: > "${release_log}"
result=$(
	PATH="${TEMP_DIR}/release-bin:${PATH}" \
	MOCK_GH_LOG="${release_log}" \
	MOCK_NOTES_FILE="${release_notes}" \
	MOCK_LOOKUP_STATUS=200 \
	GH_TOKEN=fixture \
	GITHUB_REPOSITORY=felixfoertsch/jellyfin \
	IMAGE_REPOSITORY=ghcr.io/felixfoertsch/jellyfin \
	FIX_SHA=a44a26b287a328927c6d7bffa0a253b0d1a807dd \
	"${ROOT_DIR}/scripts/publish-patched-release.sh" \
	v12.0-rc5 '12.0 RC5' true fixture-target
)
assert_equal "existing" "${result}" "existing release is unchanged"
if grep -Fq 'release create' "${release_log}"; then
	printf 'FAIL: existing release is recreated\n' >&2
	exit 1
fi

for status in 401 500; do
	: > "${release_log}"
	if lookup_failure=$(
		PATH="${TEMP_DIR}/release-bin:${PATH}" \
		MOCK_GH_LOG="${release_log}" \
		MOCK_NOTES_FILE="${release_notes}" \
		MOCK_LOOKUP_STATUS="${status}" \
		GH_TOKEN=fixture \
		GITHUB_REPOSITORY=felixfoertsch/jellyfin \
		IMAGE_REPOSITORY=ghcr.io/felixfoertsch/jellyfin \
		FIX_SHA=a44a26b287a328927c6d7bffa0a253b0d1a807dd \
		"${ROOT_DIR}/scripts/publish-patched-release.sh" \
		v12.0-rc5 '12.0 RC5' true fixture-target 2>&1
	); then
		printf 'FAIL: HTTP %s lookup failure must fail\n' "${status}" >&2
		exit 1
	fi
	if [[ "${lookup_failure}" != *'failed to look up GitHub Release'* ]]; then
		printf 'FAIL: HTTP %s lookup failure is not visible\n' "${status}" >&2
		exit 1
	fi
	if grep -Fq 'release create' "${release_log}"; then
		printf 'FAIL: HTTP %s lookup failure attempts release creation\n' "${status}" >&2
		exit 1
	fi
done

assert_publisher_rejects_control_character() {
	local message=$1
	shift

	: > "${release_log}"
	if PATH="${TEMP_DIR}/release-bin:${PATH}" \
		MOCK_GH_LOG="${release_log}" \
		MOCK_NOTES_FILE="${release_notes}" \
		MOCK_LOOKUP_STATUS=404 \
		GH_TOKEN=fixture \
		GITHUB_REPOSITORY=felixfoertsch/jellyfin \
		IMAGE_REPOSITORY=ghcr.io/felixfoertsch/jellyfin \
		FIX_SHA=a44a26b287a328927c6d7bffa0a253b0d1a807dd \
		"${ROOT_DIR}/scripts/publish-patched-release.sh" "$@" >/dev/null 2>&1; then
		printf 'FAIL: %s\n' "${message}" >&2
		exit 1
	fi
	if [[ -s "${release_log}" ]]; then
		printf 'FAIL: %s reaches GitHub CLI\n' "${message}" >&2
		exit 1
	fi
}

assert_publisher_rejects_control_character \
	"control characters in upstream tags are rejected" \
	$'v12.0-rc5\nunsafe' '12.0 RC5' true fixture-target
assert_publisher_rejects_control_character \
	"control characters in upstream names are rejected" \
	v12.0-rc5 $'12.0 RC5\runsafe' true fixture-target
assert_publisher_rejects_control_character \
	"control characters in prerelease values are rejected" \
	v12.0-rc5 '12.0 RC5' $'true\037unsafe' fixture-target
assert_publisher_rejects_control_character \
	"control characters in target SHAs are rejected" \
	v12.0-rc5 '12.0 RC5' true $'fixture-target\nunsafe'

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

for required in \
	'outputs: |' \
	'type=registry,name=ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-${{ steps.release.outputs.tag }},oci-mediatypes=false' \
	'provenance: false' \
	'sbom: false'
do
	if ! grep -Fq -- "${required}" "${workflow}"; then
		printf 'FAIL: workflow lacks Docker Schema 2 contract: %s\n' "${required}" >&2
		exit 1
	fi
done

build_step=$(awk '
	/^      - name: Build and push$/ { in_build = 1 }
	in_build && /^      - name: / { exit }
	in_build { print }
' "${workflow}")
if grep -Fq 'push: true' <<< "${build_step}" || grep -Eq '^[[:space:]]*tags:' <<< "${build_step}"; then
	printf 'FAIL: workflow build step delegates publication outside the registry exporter\n' >&2
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

for required in \
	'contents: write' \
	'legacy-filter-query' \
	'name: Publish GitHub Release' \
	"if: steps.promote.outcome == 'success'" \
	'scripts/publish-patched-release.sh'
do
	if ! grep -Fq -- "${required}" "${workflow}"; then
		printf 'FAIL: workflow lacks GitHub Release contract: %s\n' "${required}" >&2
		exit 1
	fi
done

promotion_line=$(grep -nF 'name: Promote rolling image tag' "${workflow}" | cut -d: -f1)
build_line=$(grep -nF 'name: Build and push' "${workflow}" | cut -d: -f1)
if (( promotion_line <= build_line )); then
	printf 'FAIL: workflow promotes the rolling tag before immutable publication\n' >&2
	exit 1
fi

github_release_line=$(grep -nF 'name: Publish GitHub Release' "${workflow}" | cut -d: -f1)
if (( github_release_line <= promotion_line )); then
	printf 'FAIL: workflow publishes the GitHub Release before rolling promotion\n' >&2
	exit 1
fi

printf 'release automation tests passed\n'
