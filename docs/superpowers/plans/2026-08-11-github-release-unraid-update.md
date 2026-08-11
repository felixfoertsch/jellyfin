# GitHub Release And Unraid Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish each newest patched Jellyfin image as a GitHub Release and as a Docker Schema 2 rolling image that Unraid reports as an available update.

**Architecture:** Extend the existing scheduled workflow. The GHCR compatibility probe and explicit BuildKit exporter force Docker Schema 2 output, while a tested Bash publisher creates one idempotent GitHub Release only after rolling promotion succeeds.

**Tech Stack:** GitHub Actions, Bash, GitHub CLI, `curl`, `jq`, Docker Buildx, GHCR, Unraid Docker Manager

## Global Constraints

- Tag RC5 as `v12.0-rc5-legacy-filter-query` with title `Jellyfin 12.0 RC5 + legacy filter query fix` and mark it prerelease.
- Stable upstream releases use `<upstream-tag>-legacy-filter-query` and become normal GitHub Releases.
- Publish only the newest non-draft upstream release; never backfill historical releases.
- Publish immutable and rolling images as Docker Schema 2, not OCI.
- Build only `linux/amd64`, keep provenance and SBOM disabled, and retain fix SHA `a44a26b287a328927c6d7bffa0a253b0d1a807dd`.
- Create a GitHub Release only after immutable publication and rolling promotion succeed.
- Retry missing release creation without rebuilding a compatible immutable image.
- Do not recreate, restart, or update FFUNRAID's Jellyfin container.
- Keep the correct Unraid template image `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query` unchanged.

---

## File Structure

- `scripts/ghcr-tag-exists.sh`: define "exists" as a Docker-manifest-compatible tag, matching Unraid's accepted media types.
- `scripts/publish-patched-release.sh`: idempotently create the approved GitHub Release from validated upstream metadata.
- `scripts/test-release-automation.sh`: fixture and workflow-contract coverage for media types, release naming, prerelease behavior, ordering, and idempotency.
- `.github/workflows/build-legacy-filter-query-image.yml`: explicit Docker Schema 2 export, upstream metadata outputs, release publication, and summary reporting.

### Task 1: Unraid-Compatible Docker Manifest

**Files:**
- Modify: `scripts/ghcr-tag-exists.sh`
- Modify: `scripts/test-release-automation.sh`
- Modify: `.github/workflows/build-legacy-filter-query-image.yml`

**Interfaces:**
- Consumes: GHCR repository/tag and the existing image build inputs.
- Produces: `true` only for a Docker manifest response, plus Docker Schema 2 immutable and rolling tags.

- [ ] **Step 1: Add failing media-type tests**

Extend the mock curl in `scripts/test-release-automation.sh` so it writes all arguments to `MOCK_CURL_ARGS_FILE` when set. After the current 200 probe assertion, add:

```bash
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
```

Add workflow assertions for:

```bash
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
```

Also fail if the build step still contains `push: true` or `tags:` because the explicit registry exporter owns publication.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash scripts/test-release-automation.sh`

Expected: FAIL because the probe accepts OCI and the workflow lacks `oci-mediatypes=false`.

- [ ] **Step 3: Restrict the GHCR probe to Unraid-compatible types**

Replace the probe's `Accept` header with exactly:

```bash
-H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
```

Retain the current semantics: HTTP 200 emits `true`, HTTP 404 emits `false`, and every other response fails visibly.

- [ ] **Step 4: Use an explicit Docker Schema 2 registry exporter**

In the Buildx step, remove `push: true` and `tags:`. Add:

```yaml
          outputs: |
            type=registry,name=ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-${{ steps.release.outputs.tag }},oci-mediatypes=false
```

Keep `provenance: false`, `sbom: false`, and all existing labels/build arguments. Keep rolling promotion with `--prefer-index=false`.

- [ ] **Step 5: Run local and live pre-publication checks**

Run: `bash scripts/test-release-automation.sh`

Expected: `release automation tests passed`.

Run: `scripts/ghcr-tag-exists.sh felixfoertsch/jellyfin legacy-filter-query-v12.0-rc5`

Expected before the compatibility rebuild: `false`, because the current RC5 tag exists only as OCI.

Run: `bash -n scripts/ghcr-tag-exists.sh scripts/test-release-automation.sh`

Expected: no output.

Run: `git diff --check`

Expected: no output.

- [ ] **Step 6: Commit Docker manifest compatibility**

```bash
git add scripts/ghcr-tag-exists.sh scripts/test-release-automation.sh .github/workflows/build-legacy-filter-query-image.yml
git commit -m "publish unraid-compatible docker manifests"
```

### Task 2: Idempotent GitHub Release Publication

**Files:**
- Create: `scripts/publish-patched-release.sh`
- Modify: `scripts/test-release-automation.sh`
- Modify: `.github/workflows/build-legacy-filter-query-image.yml`

**Interfaces:**
- Consumes: positional arguments `upstream_tag`, `upstream_name`, `prerelease`, `target_sha`; environment `GH_TOKEN`, `GITHUB_REPOSITORY`, `IMAGE_REPOSITORY`, and `FIX_SHA`.
- Produces: stdout `existing` or `created`; GitHub Release `<upstream-tag>-legacy-filter-query` after successful image promotion.

- [ ] **Step 1: Add failing publisher tests**

Create the mock GitHub CLI:

```bash
mkdir -p "${TEMP_DIR}/release-bin"
cat > "${TEMP_DIR}/release-bin/gh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_GH_LOG:?MOCK_GH_LOG is required}"
printf '%s' "$1" >> "${MOCK_GH_LOG}"
shift
for arg in "$@"; do
	printf ' %s' "${arg}" >> "${MOCK_GH_LOG}"
done
printf '\n' >> "${MOCK_GH_LOG}"

if [[ "$*" == view\ * ]]; then
	[[ "${MOCK_RELEASE_EXISTS}" == "true" ]]
	exit
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
```

Add these assertions to `scripts/test-release-automation.sh`:

```bash
release_log=${TEMP_DIR}/release.log
release_notes=${TEMP_DIR}/release-notes.md
result=$(
	PATH="${TEMP_DIR}/release-bin:${PATH}" \
	MOCK_GH_LOG="${release_log}" \
	MOCK_NOTES_FILE="${release_notes}" \
	MOCK_RELEASE_EXISTS=false \
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
```

Add stable and existing-release assertions:

```bash
: > "${release_log}"
PATH="${TEMP_DIR}/release-bin:${PATH}" \
	MOCK_GH_LOG="${release_log}" \
	MOCK_NOTES_FILE="${release_notes}" \
	MOCK_RELEASE_EXISTS=false \
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
	MOCK_RELEASE_EXISTS=true \
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/test-release-automation.sh`

Expected: FAIL because `scripts/publish-patched-release.sh` does not exist.

- [ ] **Step 3: Implement the publisher**

Create `scripts/publish-patched-release.sh`:

```bash
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
```

Make it executable.

- [ ] **Step 4: Add validated upstream metadata outputs**

Extend `Select newest upstream release` after selecting `tag`:

```bash
metadata=$(gh api "repos/jellyfin/jellyfin/releases/tags/${tag}")
name=$(jq -er '.name | select(type == "string" and length > 0 and (test("[\\r\\n]") | not))' <<< "${metadata}")
prerelease=$(jq -er '.prerelease | select(type == "boolean")' <<< "${metadata}")
echo "name=${name}" >> "${GITHUB_OUTPUT}"
echo "prerelease=${prerelease}" >> "${GITHUB_OUTPUT}"
```

Keep `GITHUB_TOKEN` available as `GH_TOKEN` for GitHub CLI.

- [ ] **Step 5: Add release publication after promotion**

Change workflow permissions to:

```yaml
permissions:
  contents: write
  packages: write
```

Immediately after rolling promotion, add:

```yaml
      - name: Publish GitHub Release
        if: steps.promote.outcome == 'success'
        id: github_release
        shell: bash
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PRERELEASE: ${{ steps.release.outputs.prerelease }}
          RELEASE_NAME: ${{ steps.release.outputs.name }}
          RELEASE_TAG: ${{ steps.release.outputs.tag }}
        run: |
          set -euo pipefail
          result=$(automation/scripts/publish-patched-release.sh \
            "${RELEASE_TAG}" \
            "${RELEASE_NAME}" \
            "${PRERELEASE}" \
            "${GITHUB_SHA}")
          echo "result=${result}" >> "${GITHUB_OUTPUT}"
```

Add `GITHUB_RELEASE_OUTCOME` and `GITHUB_RELEASE_RESULT` to the summary environment. Report `created`, `existing`, or a failed/skipped release publication distinctly.

- [ ] **Step 6: Add workflow contract assertions**

Assert the workflow contains `contents: write`, the exact release tag suffix, `Publish GitHub Release`, `steps.promote.outcome == 'success'`, and `scripts/publish-patched-release.sh`. Compare line numbers and fail unless rolling promotion precedes release publication.

- [ ] **Step 7: Run all local checks**

Run: `bash scripts/test-release-automation.sh`

Expected: `release automation tests passed`.

Run: `bash -n scripts/select-latest-jellyfin-release.sh scripts/ghcr-tag-exists.sh scripts/publish-patched-release.sh scripts/test-release-automation.sh`

Expected: no output.

Run: `scripts/select-latest-jellyfin-release.sh`

Expected: `v12.0-rc5`.

Run: `git diff --check`

Expected: no output.

- [ ] **Step 8: Commit release publication**

```bash
git add scripts/publish-patched-release.sh scripts/test-release-automation.sh .github/workflows/build-legacy-filter-query-image.yml
git commit -m "publish patched jellyfin github releases"
```

### Task 3: RC5 Publication And Unraid Verification

**Files:**
- Modify after verification: `/Users/felixfoertsch/.syncthing/dotfiles/tools/todo/todo.kdl`
- Modify only after explicit approval: `/Users/felixfoertsch/.syncthing/dotfiles/knowledge/memory/project-unraid-jellyfin.md`

**Interfaces:**
- Consumes: verified workflow on fork `master`, public GHCR tags, and FFUNRAID's native update checker.
- Produces: GitHub RC5+patch prerelease, Docker Schema 2 tags, Unraid `status: "false"`, and an idempotent second run.

- [ ] **Step 1: Review and push the linear branch**

Fetch `upstream/master` and `origin/master`. Rebase the branch onto current `origin/master` if it advanced. Run the full shell suite and `git diff --check`, then push `HEAD:master` without force.

- [ ] **Step 2: Dispatch the compatibility rebuild**

Run:

```bash
gh workflow run build-legacy-filter-query-image.yml --repo felixfoertsch/jellyfin --ref master
```

Monitor the exact returned run through completion. Require successful source checkout, patch application, Docker Schema 2 build, rolling promotion, and GitHub Release publication.

- [ ] **Step 3: Verify the GitHub Release**

Run:

```bash
gh release view v12.0-rc5-legacy-filter-query \
  --repo felixfoertsch/jellyfin \
  --json tagName,name,isDraft,isPrerelease,publishedAt,targetCommitish,url,body
```

Require the approved tag/title, `isDraft=false`, `isPrerelease=true`, the pushed `master` commit as target, and every release-note reference from Task 2.

- [ ] **Step 4: Verify Docker media types and digest equality**

Request each tag with Docker-only `Accept` headers through GHCR's bearer-token flow. Require HTTP 200, `content-type: application/vnd.docker.distribution.manifest.v2+json`, and identical non-empty `Docker-Content-Digest` headers for:

- `legacy-filter-query-v12.0-rc5`
- `legacy-filter-query`

- [ ] **Step 5: Verify Unraid update detection without updating**

Record the current container image ID and health. Run:

```bash
ssh unraid '/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/dockerupdate check nonotify'
```

Read `/var/lib/docker/unraid-update-status.json` with `jq`. Require the Jellyfin entry to have a non-null remote digest different from local and `status: "false"`. Re-read container state and require the same image ID, `running`, and `healthy`. Confirm the template remains on `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query`.

- [ ] **Step 6: Verify idempotent second dispatch**

Dispatch the workflow again. Require successful release/image detection, skipped source/patch/build steps, successful rolling promotion, and successful GitHub Release step with result `existing`. Confirm the release `publishedAt` value did not change.

- [ ] **Step 7: Update durable state**

Update the matching TODO with fork commit, both workflow run URLs, GitHub Release URL, Docker digest/media type, and Unraid local/remote/status evidence. Before marking it done, propose an exact update to existing project memory and obtain explicit scoped approval. After approval, update memory, lint, refresh/embed QMD, confirm retrieval, then mark the TODO done.
