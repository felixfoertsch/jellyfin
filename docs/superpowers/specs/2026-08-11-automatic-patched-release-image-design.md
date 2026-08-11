# Automatic Patched Release Image Design

## Goal

Automatically build `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query` from the newest published Jellyfin release, including release candidates and stable releases, with the verified legacy tag-filter query fix applied on top.

The automation builds only the newest upstream release. It does not backfill older releases or attempt to detect whether upstream has incorporated the fix.

## Root Cause

The existing `Build legacy filter fix image` workflow is a branch-only manual build:

- its only trigger is a push to `build/legacy-filter-query-image`;
- the workflow does not exist on the fork's default `master` branch, from which GitHub runs scheduled workflows;
- it checks out its own branch SHA rather than an upstream release tag;
- it pins the RC4-era server-adjacent inputs.

Jellyfin `v12.0-rc5` published at `2026-08-11 00:33`, but no event could start the fork workflow. The absence of a run is therefore expected from the current configuration rather than a failed release check.

## Architecture

Add the automation to the fork's default `master` branch. Preserve `workflow_dispatch` for immediate and recovery runs, and poll upstream releases every six hours because GitHub cannot subscribe a fork workflow directly to another repository's release events.

Keep release selection separate from image construction:

1. A tested Bash script queries the GitHub releases API.
2. It excludes drafts, considers stable and prerelease entries equally, sorts by `published_at`, and emits the newest release tag.
3. The workflow checks whether the corresponding release-specific GHCR tag exists.
4. An existing tag ends the run successfully without rebuilding.
5. A missing tag starts the patch and image build.

The release-specific tag is an idempotency marker and an auditable immutable reference. Each successful build publishes both:

- `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-<upstream-tag>`;
- `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query`.

Only the newest release selected in a run can be built. Older releases remain untouched.

## Source Assembly

For the selected upstream tag:

1. Check out `jellyfin/jellyfin` at the exact release tag with full history.
2. Fetch the fork's singular fix commit `a44a26b287a328927c6d7bffa0a253b0d1a807dd` and cherry-pick it onto the release checkout.
3. Check out `jellyfin/jellyfin-web` at the identical release tag.
4. Check out the packaging repository at its reviewed pinned revision.
5. Verify that the patched server contains the fix commit before building.

The workflow builds the existing `linux/amd64` image with Jellyfin's packaging Dockerfile and preserves the current runtime contract. Labels record the upstream release, patched server revision, and fix revision.

## Failure Handling

The workflow fails instead of silently substituting another source when:

- the releases API returns no eligible published release;
- the selected release lacks a matching Jellyfin Web tag;
- the fix cannot be cherry-picked onto the selected release;
- the fix ancestry/content verification fails;
- the image build or publication fails.

A failed run leaves the existing rolling image unchanged because Docker publishes the new tags only after a successful build. Concurrency permits one release build at a time and cancels a stale run when a newer invocation starts.

## Security And Permissions

Use the workflow-provided `GITHUB_TOKEN`. Grant only `contents: read` and `packages: write`. Pin third-party actions by full commit SHA. Do not persist checkout credentials. Do not add secrets.

## Testing

Test the release-selection script with fixture JSON before changing the workflow:

- RC5 wins when it is newer than the latest stable release;
- a newer stable release wins over an older release candidate;
- drafts are ignored;
- release API order does not affect selection;
- an empty eligible set fails clearly.

Validate the workflow statically and exercise the patch path against `v12.0-rc5`. The first live run must publish the RC5-specific tag and move the rolling tag. A second dispatch must detect the existing RC5 tag and skip the build.

## Scope

Included:

- automatic newest-release detection for stable and prerelease releases;
- exact matching server and web source selection;
- applying the existing verified fix;
- idempotent GHCR publication;
- regression coverage and live RC5 verification.

Excluded:

- rebuilding historical releases;
- changing the filter-query fix;
- determining whether upstream has merged an equivalent fix;
- changing the Unraid template or running container;
- opening the upstream Jellyfin pull request.

## Guided Gates

- **GG-1:** Confirm the first live run selects `v12.0-rc5`, applies `a44a26b287a328927c6d7bffa0a253b0d1a807dd`, and completes successfully.
- **GG-2:** Confirm the RC5-specific GHCR tag and rolling `legacy-filter-query` tag resolve to the same image digest.
- **GG-3:** Dispatch the workflow again and confirm it skips the image build because the RC5-specific tag exists.
- **GG-4:** Confirm no Unraid template or running container changed during this work.
