# Legacy Filter Fix Image Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a source-pinned, auditable public `linux/amd64` Jellyfin image containing singular fix commit `a44a26b287a328927c6d7bffa0a253b0d1a807dd` without changing the upstream-ready fix branch.

**Architecture:** Create `build/legacy-filter-query-image` from the exact fix commit and add one branch-scoped GitHub Actions workflow commit. The workflow combines that server source with pinned Jellyfin Web and packaging revisions, publishes stable and commit-addressed GHCR tags, records their content digest, then the production host validates anonymous pull, metadata, and disposable-container health without changing its live Jellyfin template.

**Tech Stack:** GitHub Actions, Docker Buildx, GHCR, Jellyfin 12/.NET 10, Unraid Docker

## Global Constraints

- `fix/legacy-filter-tag-query` remains unchanged at singular commit `a44a26b287a328927c6d7bffa0a253b0d1a807dd`, exactly one commit ahead of `master`.
- Build branch `build/legacy-filter-query-image` starts at the fix commit and contains exactly one additional workflow commit.
- Pin Jellyfin Web to `a66fb60b2c4fccfcc0cbf08662c9d1e8f583de51` and packaging to `846b546838941cefac00cfe5ac08d9adf6dff26c`.
- Build only `linux/amd64` with the official packaging Dockerfile and runtime contract.
- Publish `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query` and `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-${GITHUB_SHA}` from one build.
- Grant only `contents: read` and `packages: write`; use only `GITHUB_TOKEN` for GHCR.
- The resulting package is public and anonymously pullable from Unraid.
- The official packaging Dockerfile retains mutable transitive OS/runtime/package inputs; the workflow records the immutable published digest and does not claim byte-for-byte rebuild reproducibility.
- Do not modify application source, tests, the live Unraid template, or the running production container.

---

## File Map

- Create on build branch: `.github/workflows/build-legacy-filter-query-image.yml`
  - Builds and publishes the pinned full image from the branch source.
- Preserve unchanged: all application and test files.
- Preserve unchanged: `fix/legacy-filter-tag-query` and Unraid's live Jellyfin template.

### Task 1: Create And Verify The Build-Only Workflow Branch

**Files:**
- Create: `.github/workflows/build-legacy-filter-query-image.yml`

**Interfaces:**
- Consumes: fix commit `a44a26b287a328927c6d7bffa0a253b0d1a807dd`, pinned web and packaging revisions, repository `GITHUB_TOKEN`.
- Produces: branch `build/legacy-filter-query-image` with one workflow commit and no source changes.

- [ ] **Step 1: Reconfirm the contribution branch contract**

Fetch both remotes, then run:

```bash
git rev-parse upstream/master origin/master fix/legacy-filter-tag-query
git rev-list --count upstream/master..fix/legacy-filter-tag-query
git diff --check upstream/master...fix/legacy-filter-tag-query
```

Expected:

- both master refs equal `33a8cdfc0b77d7a2439aeb3472db5adda095b41b`;
- fix ref equals `a44a26b287a328927c6d7bffa0a253b0d1a807dd`;
- count is exactly `1`;
- diff check exits `0`.

- [ ] **Step 2: Rerun source verification before packaging**

From the existing fix worktree:

```bash
mise exec dotnet@10.0.302 -- dotnet test tests/Jellyfin.Server.Implementations.Tests/Jellyfin.Server.Implementations.Tests.csproj --configuration Release --no-restore --filter "FullyQualifiedName~Jellyfin.Server.Implementations.Tests.Item"
mise exec dotnet@10.0.302 -- dotnet build Jellyfin.Server.Implementations/Jellyfin.Server.Implementations.csproj --configuration Release --no-restore
```

Expected: 10 Item tests pass and Release build reports zero errors. Existing `NU1903` warnings remain baseline warnings.

- [ ] **Step 3: Create an isolated build worktree**

Create branch `build/legacy-filter-query-image` at exact fix commit `a44a26b287a328927c6d7bffa0a253b0d1a807dd` in:

```text
/Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/build-legacy-filter-query-image/
```

Verify:

```bash
git rev-parse HEAD
git status --short --branch
```

Expected: exact fix SHA and a clean named build branch.

- [ ] **Step 4: Add the branch-scoped workflow**

Create `.github/workflows/build-legacy-filter-query-image.yml` with:

```yaml
name: Build legacy filter fix image

on:
  push:
    branches:
      - build/legacy-filter-query-image

permissions:
  contents: read
  packages: write

concurrency:
  group: build-legacy-filter-query-image
  cancel-in-progress: true

jobs:
  build:
    name: Build linux/amd64 image
    runs-on: ubuntu-24.04
    timeout-minutes: 60

    steps:
      - name: Checkout pinned packaging
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: jellyfin/jellyfin-packaging
          ref: 846b546838941cefac00cfe5ac08d9adf6dff26c
          persist-credentials: false

      - name: Checkout fixed server
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: ${{ github.repository }}
          ref: ${{ github.sha }}
          path: jellyfin-server
          fetch-depth: 0
          persist-credentials: false

      - name: Checkout pinned web
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: jellyfin/jellyfin-web
          ref: a66fb60b2c4fccfcc0cbf08662c9d1e8f583de51
          path: jellyfin-web
          persist-credentials: false

      - name: Verify fixed server ancestry
        shell: bash
        run: |
          set -euo pipefail
          git -C jellyfin-server merge-base --is-ancestor \
            a44a26b287a328927c6d7bffa0a253b0d1a807dd \
            HEAD

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0

      - name: Log in to GHCR
        uses: docker/login-action@abd2ef45e78c5afb21d64d4ca52ee8550d9572c7 # v4.5.1
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a # v7.3.0
        with:
          context: .
          file: docker/Dockerfile
          platforms: linux/amd64
          push: true
          pull: true
          no-cache: true
          provenance: false
          sbom: false
          tags: |
            ghcr.io/felixfoertsch/jellyfin:legacy-filter-query
            ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-${{ github.sha }}
          labels: |
            org.opencontainers.image.source=https://github.com/${{ github.repository }}
            org.opencontainers.image.revision=${{ github.sha }}
            org.opencontainers.image.version=12.0.0-legacy-filter-query
            org.opencontainers.image.title=Jellyfin legacy tag-filter fix
            de.felixfoertsch.jellyfin.fix-revision=a44a26b287a328927c6d7bffa0a253b0d1a807dd
          build-args: |
            PACKAGE_ARCH=amd64
            DOTNET_ARCH=x64
            IMAGE_ARCH=amd64
            TARGET_ARCH=amd64
            JELLYFIN_VERSION=12.0.0-legacy-filter-query
            CONFIG=Release
            DOTNET_VERSION=10.0
            NODEJS_VERSION=24
            OS_VERSION=trixie
            FFMPEG_PACKAGE=jellyfin-ffmpeg8

      - name: Publish image summary
        shell: bash
        env:
          BUILD_DIGEST: ${{ steps.build.outputs.digest }}
          BUILD_SHA: ${{ github.sha }}
          FIX_SHA: a44a26b287a328927c6d7bffa0a253b0d1a807dd
        run: |
          {
            echo "## Legacy filter fix image"
            echo
            echo "- Stable tag: ghcr.io/felixfoertsch/jellyfin:legacy-filter-query"
            echo "- Commit tag: \`ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-${BUILD_SHA}\`"
            echo "- Immutable digest: \`${BUILD_DIGEST}\`"
            echo "- Build revision: \`${BUILD_SHA}\`"
            echo "- Fix revision: ${FIX_SHA}"
          } >> "${GITHUB_STEP_SUMMARY}"
```

- [ ] **Step 5: Validate workflow syntax and scope**

Run:

```bash
mise exec actionlint@1.7.12 -- actionlint .github/workflows/build-legacy-filter-query-image.yml
git diff --check
git status --short
```

Expected: actionlint and whitespace checks pass; status lists only the new workflow.

Inspect the workflow and confirm:

- trigger names only `build/legacy-filter-query-image`;
- permissions contain only `contents: read` and `packages: write`;
- all external actions use full commit pins;
- web and packaging refs match the Global Constraints;
- both image tags are published by one build step;
- the fix-ancestry check uses exact commit `a44a26b`.

- [ ] **Step 6: Commit the workflow only**

```bash
git add .github/workflows/build-legacy-filter-query-image.yml
git commit -m "build legacy filter fix image"
```

Verify:

```bash
git rev-list --count a44a26b287a328927c6d7bffa0a253b0d1a807dd..HEAD
git diff --stat a44a26b287a328927c6d7bffa0a253b0d1a807dd..HEAD
git status --short --branch
```

Expected: one commit, one created workflow file, clean build branch.

### Task 2: Publish And Validate The GHCR Image

**Files:**
- No repository file changes.
- Create transiently on Unraid: disposable validation container `jellyfin-filter-image-validation`.

**Interfaces:**
- Consumes: reviewed build branch and GitHub Actions workflow from Task 1.
- Produces: public stable and commit-addressed GHCR tags resolving to one recorded digest plus verified anonymous Unraid pull and startup evidence.

- [ ] **Step 1: Push the build branch**

```bash
git push --set-upstream origin build/legacy-filter-query-image
```

Expected: new branch on `github.com/felixfoertsch/jellyfin`; no pull request.

- [ ] **Step 2: Identify and watch the exact workflow run**

```bash
run_id=$(gh run list --repo felixfoertsch/jellyfin --workflow build-legacy-filter-query-image.yml --branch build/legacy-filter-query-image --limit 1 --json databaseId --jq '.[0].databaseId')
run_head=$(gh run view "$run_id" --repo felixfoertsch/jellyfin --json headSha --jq '.headSha')
test "$run_head" = "$(git rev-parse HEAD)"
```

Require `headSha` to equal local `git rev-parse HEAD`. Watch that run with:

```bash
gh run watch "$run_id" --repo felixfoertsch/jellyfin --exit-status
```

Expected: checkout, ancestry, Buildx, GHCR login, build, push, and summary steps all succeed.

- [ ] **Step 3: Read and record the published digest**

```bash
gh run view "$run_id" --repo felixfoertsch/jellyfin --json headSha,conclusion,url
gh run view "$run_id" --repo felixfoertsch/jellyfin --log
build_sha=$(gh run view "$run_id" --repo felixfoertsch/jellyfin --json headSha --jq '.headSha')
```

Record the full build SHA, workflow URL, and `sha256:` image digest from the build output or summary. The digest-qualified image reference is the immutable validation, rollback, and deployment identity; do not infer it from a tag or local image ID.

- [ ] **Step 4: Make the package public**

Inspect the user container package through authenticated GitHub tooling, then set public visibility:

```bash
gh api --method PATCH /user/packages/container/jellyfin/visibility -f visibility=public
gh api /user/packages/container/jellyfin
```

Expected: package metadata reports `visibility: public`. If the package was already public, keep it public and continue.

- [ ] **Step 5: Pull both tags and the digest anonymously on Unraid**

Set the full build SHA from Task 2 Step 3, then run:

```bash
build_sha=$(gh run list --repo felixfoertsch/jellyfin --workflow build-legacy-filter-query-image.yml --branch build/legacy-filter-query-image --limit 1 --json headSha --jq '.[0].headSha')
image_digest=$(gh api /user/packages/container/jellyfin/versions --paginate --jq '.[] | select(.metadata.container.tags[] == "legacy-filter-query-'"${build_sha}"'") | .name')
test -n "$image_digest"
ssh unraid "docker pull --platform linux/amd64 ghcr.io/felixfoertsch/jellyfin:legacy-filter-query"
ssh unraid "docker pull --platform linux/amd64 ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-$build_sha"
ssh unraid "docker pull --platform linux/amd64 ghcr.io/felixfoertsch/jellyfin@${image_digest}"
```

Expected: all three pulls succeed without configuring GHCR credentials on Unraid.

- [ ] **Step 6: Verify both tags, the digest, and image metadata**

Inspect both tags and the digest-qualified reference and require:

- identical image ID and `RepoDigests` digest;
- architecture `amd64`, OS `linux`;
- entrypoint `[/jellyfin/jellyfin]`;
- localhost `8096/health` health check;
- `org.opencontainers.image.revision` equals the full build SHA;
- custom fix label equals `a44a26b287a328927c6d7bffa0a253b0d1a807dd`.

Use:

```bash
build_sha=$(gh run list --repo felixfoertsch/jellyfin --workflow build-legacy-filter-query-image.yml --branch build/legacy-filter-query-image --limit 1 --json headSha --jq '.[0].headSha')
image_digest=$(gh api /user/packages/container/jellyfin/versions --paginate --jq '.[] | select(.metadata.container.tags[] == "legacy-filter-query-'"${build_sha}"'") | .name')
ssh unraid "docker image inspect ghcr.io/felixfoertsch/jellyfin:legacy-filter-query ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-$build_sha ghcr.io/felixfoertsch/jellyfin@${image_digest}"
```

- [ ] **Step 7: Verify disposable-container health**

Confirm no existing container has the exact validation name, then start without production mounts or ports:

```bash
build_sha=$(gh run list --repo felixfoertsch/jellyfin --workflow build-legacy-filter-query-image.yml --branch build/legacy-filter-query-image --limit 1 --json headSha --jq '.[0].headSha')
image_digest=$(gh api /user/packages/container/jellyfin/versions --paginate --jq '.[] | select(.metadata.container.tags[] == "legacy-filter-query-'"${build_sha}"'") | .name')
ssh unraid "docker run --detach --name jellyfin-filter-image-validation ghcr.io/felixfoertsch/jellyfin@${image_digest}"
```

Poll `docker inspect jellyfin-filter-image-validation` until health is `healthy` or 90 seconds elapse. On failure, capture `docker logs jellyfin-filter-image-validation` and report the blocker.

```bash
health=""
for attempt in $(seq 1 30); do
	health=$(ssh unraid "docker inspect jellyfin-filter-image-validation --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'")
	if [ "$health" = "healthy" ]; then
		break
	fi
	sleep 3
done
test "$health" = "healthy"
```

After a healthy result, remove only that exact validation container:

```bash
ssh unraid "docker rm --force jellyfin-filter-image-validation"
```

Expected: the disposable container reaches healthy and is removed; production `jellyfin` remains untouched.

- [ ] **Step 8: Run final non-deployment gates**

Verify:

```bash
ssh unraid "docker inspect jellyfin --format 'Image={{.Config.Image}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} RestartCount={{.RestartCount}}'"
ssh unraid "grep '<Repository>' /boot/config/plugins/dockerMan/templates-user/my-Jellyfin.xml"
```

Expected: production remains on its existing local fixed image, running and healthy with zero unexpected restarts; the template was not changed by this plan.

## Completion Boundary

Completion means the public GHCR package contains both tags at the workflow-recorded digest, anonymous Unraid tag and digest pulls succeed, metadata and disposable health pass, and production remains unchanged. Repointing production to the digest-qualified image is a separate approved action.
