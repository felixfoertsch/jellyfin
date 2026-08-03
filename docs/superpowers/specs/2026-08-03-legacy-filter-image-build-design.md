# Legacy Filter Fix Image Build Design

## Goal

Build and publish a reproducible `linux/amd64` Jellyfin image containing the verified legacy tag-filter fix from `github.com/felixfoertsch/jellyfin`, while preserving the upstream-ready fix branch as exactly one commit ahead of upstream.

## Current State

- Fork: `github.com/felixfoertsch/jellyfin`
- Fork `master` and upstream `master`: `33a8cdfc0b77d7a2439aeb3472db5adda095b41b`
- Upstream-ready fix branch: `fix/legacy-filter-tag-query`
- Singular fix commit: `2121f9bee116e7c10a482a1931f1dbf94818299d`
- The fix branch contains only the production query change and deterministic SQLite regression test.
- Unraid currently runs a validated local RC4 overlay image. The new GHCR image is a separate full build and does not replace it until validation passes.

## Branch Model

`fix/legacy-filter-tag-query` remains unchanged and exactly one commit ahead of upstream.

Create `build/legacy-filter-query-image` at fix commit `2121f9bee116e7c10a482a1931f1dbf94818299d`. Add the GitHub Actions workflow as one additional commit on this build-only branch. The workflow triggers only on pushes to that exact branch.

This isolates contribution code from private-fork image automation:

- the fix branch remains suitable for an upstream pull request;
- the build branch contains the same source fix plus private-fork CI;
- no CI workflow enters the upstream contribution.

## Build Architecture

Use Jellyfin's official packaging Dockerfile rather than overlaying a compiled assembly on a mutable official image.

The workflow checks out these immutable revisions:

- Jellyfin server: the triggering build-branch commit, whose history must contain fix commit `2121f9bee116e7c10a482a1931f1dbf94818299d`
- Jellyfin Web: `a66fb60b2c4fccfcc0cbf08662c9d1e8f583de51`
- Jellyfin packaging: `846b546838941cefac00cfe5ac08d9adf6dff26c`

The packaging checkout provides `docker/Dockerfile`. The server checkout goes to `jellyfin-server/`; the web checkout goes to `jellyfin-web/`, matching the packaging build context.

Build only `linux/amd64`, the Unraid host architecture. Preserve the official runtime layout, `/jellyfin/jellyfin` entrypoint, Jellyfin FFmpeg integration, and localhost health check.

## Workflow Trigger And Concurrency

The workflow runs on:

- `push` to `build/legacy-filter-query-image`

Use a branch-specific concurrency group with `cancel-in-progress: true`. A corrected workflow push supersedes an older in-progress build.

Do not add a schedule, pull-request trigger, or broad branch pattern. GitHub's existing run-retry function covers transient reruns without another source commit.

## Published Images

Publish both tags from the same Buildx invocation:

- `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query`
- `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-${GITHUB_SHA}`

The stable tag is the Unraid-friendly reference. The full-SHA tag is the immutable rollback and audit reference. Both tags must resolve to the same digest.

Add OCI labels for:

- source repository;
- workflow/build revision `${GITHUB_SHA}`;
- fixed server commit `2121f9bee116e7c10a482a1931f1dbf94818299d`;
- version `12.0.0-legacy-filter-query`;
- descriptive title identifying the legacy tag-filter fix image.

## Permissions And Publication

The workflow grants only:

- `contents: read`
- `packages: write`

Use the repository-provided `GITHUB_TOKEN` for GHCR login. Add no personal access token or long-lived registry secret.

The resulting `jellyfin` container package must be public. After the first successful publication, set package visibility to public through authenticated GitHub tooling and verify an anonymous pull. Do not store GitHub credentials on Unraid.

## Failure Handling

The workflow fails before image publication when:

- the build branch does not descend from the exact fix commit;
- a pinned checkout cannot resolve;
- Buildx cannot produce `linux/amd64`;
- GHCR authentication or publication fails.

No floating dependency ref silently changes the build. Updating server, web, or packaging revisions requires a reviewed workflow commit and creates a new immutable image tag.

## Verification

Repository checks:

- `fix/legacy-filter-tag-query` remains one commit ahead of `master`.
- Its commit remains `2121f9bee116e7c10a482a1931f1dbf94818299d`.
- The build branch contains only that fix commit plus one workflow commit.
- Workflow syntax and action pins are valid.

GitHub checks:

- the exact push-triggered workflow run succeeds;
- its head SHA equals the build branch head;
- stable and immutable tags resolve to one digest;
- package visibility is public.

Image checks on Unraid:

- anonymous `docker pull` succeeds for the immutable tag;
- architecture is `amd64` and OS is `linux`;
- entrypoint, health check, labels, and fixed revision match this design;
- a disposable container reaches healthy state without production mounts.

Production deployment remains a separate decision. Do not change the live Unraid template during this work.

## Testing

The workflow reuses the already verified source commit and focuses on packaging correctness. Before pushing the build branch, rerun the focused Item repository tests and Release build against the fix branch. After publication, validate image metadata and startup behavior on Unraid.

No application source or regression test changes belong in the workflow commit.

## Success Criteria

- The upstream fix branch remains a singular commit.
- The build branch publishes a full official-style `linux/amd64` image.
- Stable and immutable GHCR tags point to one digest.
- Unraid can pull the image anonymously.
- Image metadata proves the exact build and fix revisions.
- The current production container and template remain unchanged.

## Guided Gates

- **GG-1:** Confirm `fix/legacy-filter-tag-query` remains exactly one commit ahead of current upstream before creating the build branch.
- **GG-2:** Review the workflow diff, pinned revisions, permissions, tags, and labels before pushing it.
- **GG-3:** Confirm the GitHub Actions run and both published tags use the expected build SHA and digest.
- **GG-4:** Confirm anonymous Unraid pull, image metadata, and disposable-container health before considering production deployment.
