# Automatic Patched Release Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the newest published Jellyfin stable or prerelease image automatically with the verified legacy tag-filter query fix applied.

**Architecture:** A scheduled workflow on fork `master` delegates newest-release selection and GHCR idempotency checks to small tested Bash scripts. When the newest release-specific image is absent, the workflow checks out matching server and web release tags, cherry-picks the fixed commit, builds with pinned Jellyfin packaging, and publishes immutable and rolling GHCR tags.

**Tech Stack:** GitHub Actions, Bash, `curl`, `jq`, Git, Docker Buildx, GHCR

## Global Constraints

- Build only the newest non-draft release by `published_at`, considering stable and prerelease releases equally.
- Do not backfill older releases.
- Apply fix commit `a44a26b287a328927c6d7bffa0a253b0d1a807dd` without modifying it.
- Use matching `jellyfin/jellyfin` and `jellyfin/jellyfin-web` release tags.
- Keep Jellyfin packaging pinned at `846b546838941cefac00cfe5ac08d9adf6dff26c`.
- Build and publish only `linux/amd64`.
- Publish `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-<upstream-tag>` and update `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query` only after a successful build.
- Fail visibly on malformed metadata, missing matching web source, patch conflicts, verification errors, registry errors, build failures, or publication failures.
- Do not modify the Unraid template or running container.

---

## File Structure

- `scripts/select-latest-jellyfin-release.sh`: fetch or read release JSON and emit exactly one newest eligible tag.
- `scripts/ghcr-tag-exists.sh`: query GHCR and emit `true` or `false`, while treating unexpected registry responses as errors.
- `scripts/test-release-automation.sh`: fixture-driven regression tests for both scripts and static trigger/orchestration assertions for the workflow.
- `.github/workflows/build-legacy-filter-query-image.yml`: schedule, source assembly, patch application, Docker build, and GHCR publication.

### Task 1: Newest Release Selection

**Files:**
- Create: `scripts/select-latest-jellyfin-release.sh`
- Create: `scripts/test-release-automation.sh`

**Interfaces:**
- Consumes: optional path argument containing GitHub releases API JSON; otherwise `GITHUB_TOKEN` and `JELLYFIN_RELEASES_API_URL`.
- Produces: one release tag on stdout, such as `v12.0-rc5`; non-zero exit for invalid input or no eligible release.

- [ ] **Step 1: Write the failing release-selection tests**

Create `scripts/test-release-automation.sh` with strict Bash mode, a temporary directory cleanup trap, and these fixture assertions:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/test-release-automation.sh`

Expected: FAIL because `scripts/select-latest-jellyfin-release.sh` does not exist.

- [ ] **Step 3: Implement the minimal selector**

Create `scripts/select-latest-jellyfin-release.sh`:

```bash
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
```

- [ ] **Step 4: Make scripts executable and rerun tests**

Run: `chmod +x scripts/select-latest-jellyfin-release.sh scripts/test-release-automation.sh`

Run: `bash scripts/test-release-automation.sh`

Expected: PASS with exit status 0.

- [ ] **Step 5: Verify live selection**

Run: `scripts/select-latest-jellyfin-release.sh`

Expected: `v12.0-rc5`.

- [ ] **Step 6: Commit the selector and tests**

```bash
git add scripts/select-latest-jellyfin-release.sh scripts/test-release-automation.sh
git commit -m "select newest jellyfin release"
```

### Task 2: GHCR Idempotency Probe

**Files:**
- Create: `scripts/ghcr-tag-exists.sh`
- Modify: `scripts/test-release-automation.sh`

**Interfaces:**
- Consumes: repository path and image tag arguments; optional `CURL_BIN` for deterministic tests.
- Produces: `true` for HTTP 200, `false` for HTTP 404, and non-zero exit for token or registry errors.

- [ ] **Step 1: Add failing registry probe tests**

Append a mock curl executable and assertions to `scripts/test-release-automation.sh` before its final success output:

```bash
cat > "${TEMP_DIR}/curl" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *'/token?'* ]]; then
	printf '{"token":"fixture-token"}\n'
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/test-release-automation.sh`

Expected: FAIL because `scripts/ghcr-tag-exists.sh` does not exist.

- [ ] **Step 3: Implement the registry probe**

Create `scripts/ghcr-tag-exists.sh`:

```bash
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
```

- [ ] **Step 4: Make the probe executable and rerun tests**

Run: `chmod +x scripts/ghcr-tag-exists.sh`

Run: `bash scripts/test-release-automation.sh`

Expected: PASS with exit status 0.

- [ ] **Step 5: Verify the current RC5 marker is absent before the first build**

Run: `scripts/ghcr-tag-exists.sh felixfoertsch/jellyfin legacy-filter-query-v12.0-rc5`

Expected before the repair run: `false`.

- [ ] **Step 6: Commit the idempotency probe**

```bash
git add scripts/ghcr-tag-exists.sh scripts/test-release-automation.sh
git commit -m "detect published patched release images"
```

### Task 3: Scheduled Patched Image Workflow

**Files:**
- Create on `master`: `.github/workflows/build-legacy-filter-query-image.yml`
- Modify: `scripts/test-release-automation.sh`

**Interfaces:**
- Consumes: selector output `release_tag`, registry probe output `image_exists`, matching upstream server/web tags, and fix SHA.
- Produces: release-specific and rolling GHCR tags, OCI labels, and a GitHub step summary.

- [ ] **Step 1: Add failing workflow contract tests**

Append these assertions to `scripts/test-release-automation.sh`:

```bash
workflow=${ROOT_DIR}/.github/workflows/build-legacy-filter-query-image.yml
if [[ ! -f "${workflow}" ]]; then
	printf 'FAIL: release workflow is missing\n' >&2
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
	if ! grep -Fq "${required}" "${workflow}"; then
		printf 'FAIL: workflow lacks required contract: %s\n' "${required}" >&2
		exit 1
	fi
done

printf 'release automation tests passed\n'
```

- [ ] **Step 2: Run the test to verify it fails on `master`**

Run: `bash scripts/test-release-automation.sh`

Expected: FAIL with `release workflow is missing`.

- [ ] **Step 3: Create the scheduled workflow triggers and constants**

Create `.github/workflows/build-legacy-filter-query-image.yml` with this header:

```yaml
name: Build legacy filter fix image

on:
  schedule:
    - cron: '17 */6 * * *'
  workflow_dispatch:

permissions:
  contents: read
  packages: write

concurrency:
  group: build-legacy-filter-query-image
  cancel-in-progress: true

env:
  FIX_SHA: a44a26b287a328927c6d7bffa0a253b0d1a807dd
  PACKAGING_SHA: 846b546838941cefac00cfe5ac08d9adf6dff26c
  IMAGE_REPOSITORY: ghcr.io/felixfoertsch/jellyfin
```

- [ ] **Step 4: Add release detection and the idempotency gate**

Add one `build` job on `ubuntu-24.04` with `timeout-minutes: 60`. Its first checkout uses `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1`, `path: automation`, and `persist-credentials: false`. Add these steps:

```yaml
      - name: Select newest upstream release
        id: release
        shell: bash
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          tag=$(automation/scripts/select-latest-jellyfin-release.sh)
          echo "tag=${tag}" >> "${GITHUB_OUTPUT}"
          echo "version=${tag#v}" >> "${GITHUB_OUTPUT}"

      - name: Check for existing release image
        id: image
        shell: bash
        env:
          RELEASE_TAG: ${{ steps.release.outputs.tag }}
        run: |
          set -euo pipefail
          exists=$(automation/scripts/ghcr-tag-exists.sh \
            felixfoertsch/jellyfin \
            "legacy-filter-query-${RELEASE_TAG}")
          echo "exists=${exists}" >> "${GITHUB_OUTPUT}"
```

All remaining checkout, patch, build, and summary steps use `if: steps.image.outputs.exists == 'false'`.

- [ ] **Step 5: Add exact source checkouts**

Add packaging, server, and web checkouts with the pinned checkout action:

```yaml
      - name: Checkout pinned packaging
        if: steps.image.outputs.exists == 'false'
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: jellyfin/jellyfin-packaging
          ref: ${{ env.PACKAGING_SHA }}
          path: packaging
          persist-credentials: false

      - name: Checkout release server
        if: steps.image.outputs.exists == 'false'
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: jellyfin/jellyfin
          ref: ${{ steps.release.outputs.tag }}
          path: packaging/jellyfin-server
          fetch-depth: 0
          persist-credentials: false

      - name: Checkout matching release web
        if: steps.image.outputs.exists == 'false'
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: jellyfin/jellyfin-web
          ref: ${{ steps.release.outputs.tag }}
          path: packaging/jellyfin-web
          persist-credentials: false
```

- [ ] **Step 6: Add patch application and content verification**

Add a patch step that fetches the exact fork commit, cherry-picks it, verifies the resulting tree contains the patch, and records the patched SHA:

```yaml
      - name: Apply legacy filter query fix
        if: steps.image.outputs.exists == 'false'
        id: patch
        shell: bash
        run: |
          set -euo pipefail
          git -C packaging/jellyfin-server fetch --no-tags \
            "https://github.com/${GITHUB_REPOSITORY}.git" \
            "${FIX_SHA}"
          git -C packaging/jellyfin-server \
            -c user.name='github-actions[bot]' \
            -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
            cherry-pick FETCH_HEAD
          git -C packaging/jellyfin-server show "${FIX_SHA}" --format= --binary \
            | git -C packaging/jellyfin-server apply --reverse --check
          echo "sha=$(git -C packaging/jellyfin-server rev-parse HEAD)" >> "${GITHUB_OUTPUT}"
```

- [ ] **Step 7: Add the image build and publication**

Add the pinned Buildx setup, GHCR login, and build steps:

```yaml
      - name: Set up Docker Buildx
        if: steps.image.outputs.exists == 'false'
        uses: docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0

      - name: Log in to GHCR
        if: steps.image.outputs.exists == 'false'
        uses: docker/login-action@abd2ef45e78c5afb21d64d4ca52ee8550d9572c7 # v4.5.1
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        if: steps.image.outputs.exists == 'false'
        id: build
        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a # v7.3.0
        with:
          context: packaging
          file: packaging/docker/Dockerfile
          platforms: linux/amd64
          push: true
          pull: true
          no-cache: true
          provenance: false
          sbom: false
          tags: |
            ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-${{ steps.release.outputs.tag }}
            ghcr.io/felixfoertsch/jellyfin:legacy-filter-query
          labels: |
            org.opencontainers.image.source=https://github.com/${{ github.repository }}
            org.opencontainers.image.revision=${{ steps.patch.outputs.sha }}
            org.opencontainers.image.version=${{ steps.release.outputs.version }}-legacy-filter-query
            org.opencontainers.image.title=Jellyfin legacy tag-filter fix
            de.felixfoertsch.jellyfin.upstream-release=${{ steps.release.outputs.tag }}
            de.felixfoertsch.jellyfin.fix-revision=${{ env.FIX_SHA }}
          build-args: |
            PACKAGE_ARCH=amd64
            DOTNET_ARCH=x64
            IMAGE_ARCH=amd64
            TARGET_ARCH=amd64
            JELLYFIN_VERSION=${{ steps.release.outputs.version }}-legacy-filter-query
            CONFIG=Release
            DOTNET_VERSION=10.0
            NODEJS_VERSION=24
            OS_VERSION=trixie
            FFMPEG_PACKAGE=jellyfin-ffmpeg8
```

Add a summary step that always reports the selected release and distinguishes an idempotent skip from a published build:

```yaml
      - name: Publish image summary
        if: always() && steps.release.outcome == 'success' && steps.image.outcome == 'success'
        shell: bash
        env:
          BUILD_DIGEST: ${{ steps.build.outputs.digest }}
          IMAGE_EXISTS: ${{ steps.image.outputs.exists }}
          PATCHED_SHA: ${{ steps.patch.outputs.sha }}
          RELEASE_TAG: ${{ steps.release.outputs.tag }}
        run: |
          {
            echo "## Legacy filter fix image"
            echo
            echo "- Upstream release: ${RELEASE_TAG}"
            echo "- Fix revision: ${FIX_SHA}"
            if [[ "${IMAGE_EXISTS}" == "true" ]]; then
              echo "- Result: already published"
            else
              echo "- Release tag: \`${IMAGE_REPOSITORY}:legacy-filter-query-${RELEASE_TAG}\`"
              echo "- Rolling tag: \`${IMAGE_REPOSITORY}:legacy-filter-query\`"
              echo "- Immutable digest: \`${BUILD_DIGEST}\`"
              echo "- Patched server revision: \`${PATCHED_SHA}\`"
            fi
          } >> "${GITHUB_STEP_SUMMARY}"
```

- [ ] **Step 8: Run all local checks**

Run: `bash scripts/test-release-automation.sh`

Expected: `release automation tests passed`.

Run: `scripts/select-latest-jellyfin-release.sh`

Expected: `v12.0-rc5`.

Run: `git diff --check`

Expected: no output.

- [ ] **Step 9: Commit the workflow**

```bash
git add .github/workflows/build-legacy-filter-query-image.yml scripts/test-release-automation.sh
git commit -m "automate patched jellyfin release builds"
```

### Task 4: Live RC5 Verification

**Files:**
- Modify after verification: `/Users/felixfoertsch/.syncthing/dotfiles/tools/todo/todo.kdl`

**Interfaces:**
- Consumes: committed workflow on fork `master` and public GHCR package.
- Produces: successful RC5 run evidence, matching tag digests, and an idempotent skip run.

- [ ] **Step 1: Rebase the implementation onto current upstream master**

Fetch both remotes. Rebase the coherent implementation commits onto `upstream/master`; never merge. Rerun `bash scripts/test-release-automation.sh` and `git diff --check` after the rebase.

- [ ] **Step 2: Push fork master**

Push the verified linear history to `origin/master` without force. Confirm `.github/workflows/build-legacy-filter-query-image.yml` exists on the repository default branch.

- [ ] **Step 3: Dispatch and observe RC5**

Run: `gh workflow run build-legacy-filter-query-image.yml --repo felixfoertsch/jellyfin --ref master`

Capture the resulting run ID with `gh run list`, then monitor that same run through completion. Confirm its summary selects `v12.0-rc5`, records the patch SHA and fix SHA, and publishes a digest.

- [ ] **Step 4: Verify immutable and rolling tags**

Run both probes:

```bash
docker buildx imagetools inspect ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-v12.0-rc5
docker buildx imagetools inspect ghcr.io/felixfoertsch/jellyfin:legacy-filter-query
```

Expected: both report the same manifest digest and `linux/amd64` platform.

- [ ] **Step 5: Verify idempotent second dispatch**

Dispatch the workflow again on `master`. Confirm the second run succeeds, reports `already published`, and contains no Docker build/push step execution.

- [ ] **Step 6: Verify repository and deployment boundaries**

Confirm the fork contains a linear `master`, the fix branch remains unchanged, and no Unraid configuration or running container was touched.

- [ ] **Step 7: Complete the durable TODO only after all gates pass**

Update the matching `unraid` item in `/Users/felixfoertsch/.syncthing/dotfiles/tools/todo/todo.kdl` with concise verified release tag, workflow run URLs, and image digest, then add `done="2026-08-11"`.

Before marking it done, identify any durable architecture fact or lesson and offer exact scoped curated-memory promotion to the user. Do not write memory without explicit approval.
