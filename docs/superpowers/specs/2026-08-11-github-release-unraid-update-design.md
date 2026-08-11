# GitHub Release And Unraid Update Design

## Goal

For every newest published Jellyfin stable or prerelease, publish one patched container image and one corresponding GitHub Release in `felixfoertsch/jellyfin`. Make the rolling image compatible with Unraid Docker Manager's native update checker so it reports an available update before the user manually recreates the container.

## Current Failure

The automatic RC5 image build succeeded, but completion missed two required outputs:

- `felixfoertsch/jellyfin` has no GitHub Releases because the workflow contains no release-publication step and grants only read access to repository contents.
- FFUNRAID's template correctly uses `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query`, but Unraid records its remote digest as `null` and status as `undef`.

The Unraid failure is a media-type compatibility problem. The current GHCR tag serves `application/vnd.oci.image.manifest.v1+json`. Unraid requests only Docker manifest-list and Docker Schema 2 media types, so GHCR returns `404` for the same public tag. A normal OCI-aware registry client succeeds, but Unraid cannot derive `Docker-Content-Digest`.

## Architecture

Extend the existing `Build legacy filter fix image` workflow rather than adding another workflow.

The workflow remains responsible for this ordered publication transaction:

1. Select the newest non-draft upstream release across stable and prerelease entries.
2. Determine whether a Docker Schema 2 immutable image exists for that release.
3. Build the patched immutable image when it is missing or exists only as OCI.
4. Promote the immutable image to the rolling tag.
5. Ensure the corresponding GitHub Release exists.

Each step remains independently recoverable. A later scheduled run resumes after the last successful boundary without rebuilding a compatible immutable image.

## Docker Manifest Compatibility

Change the GHCR existence probe to request only:

- `application/vnd.docker.distribution.manifest.list.v2+json`
- `application/vnd.docker.distribution.manifest.v2+json`

GHCR returns `404` when a tag exists only as OCI, so the workflow treats the current RC5 image as incompatible and rebuilds it.

Publish the immutable image with an explicit BuildKit registry exporter using `oci-mediatypes=false`. Do not rely on BuildKit's effective default. Continue disabling provenance and SBOM attestations so the single-platform output remains one Docker Schema 2 manifest rather than an attestation index.

Promote with `docker buildx imagetools create --prefer-index=false` so the rolling tag retains the immutable image's top-level media type and digest.

## GitHub Release Contract

The release tag format is:

`<upstream-tag>-legacy-filter-query`

For RC5:

- tag: `v12.0-rc5-legacy-filter-query`
- title: `Jellyfin 12.0 RC5 + legacy filter query fix`
- release kind: prerelease

Stable upstream releases use the same tag suffix and become normal GitHub Releases.

After rolling promotion succeeds, use GitHub CLI with the workflow token to check for the release tag. If the release already exists, succeed without modifying it. If it is absent, create it against the workflow's `master` commit.

Release notes include:

- the upstream Jellyfin release and link;
- immutable and rolling GHCR image references;
- the verified fix commit and link;
- platform `linux/amd64`;
- a statement that Unraid users should track the rolling tag and apply updates manually.

Grant `contents: write` because GitHub Release and tag creation require it. Retain `packages: write`. Do not add secrets or third-party release actions.

## Failure Handling

- Never create the GitHub Release before immutable publication and rolling promotion succeed.
- If the Docker build fails, retain the prior rolling tag and create no release.
- If rolling promotion fails, retain the prior rolling tag and create no release.
- If release creation fails after image promotion, leave the images published; the next run retries release creation without rebuilding.
- If an immutable Docker-compatible image and GitHub Release already exist, perform no build and no duplicate release creation.
- Fail on malformed upstream release metadata or inconsistent prerelease metadata.

## Testing

Extend the existing shell regression suite to verify:

- the GHCR probe accepts only Docker manifest media types and rejects OCI-only tags as absent;
- the BuildKit output explicitly sets `oci-mediatypes=false`;
- the immutable image remains the only build output tag;
- rolling promotion precedes release creation;
- release tag and title follow the approved format;
- upstream prereleases use GitHub's prerelease flag while stable releases do not;
- existing releases skip creation;
- release creation has `contents: write` and runs only after successful promotion.

## Live Verification

Completion requires all of these checks:

1. GitHub Release `v12.0-rc5-legacy-filter-query` exists at `github.com/felixfoertsch/jellyfin/releases` and is marked prerelease.
2. Its title and notes match this design.
3. GHCR serves both RC5 immutable and rolling tags as Docker Schema 2 with the same digest.
4. FFUNRAID's native `dockerupdate check nonotify` records a non-null remote digest and `status: "false"` for `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query`.
5. FFUNRAID's Jellyfin template remains on the rolling tag.
6. The running Jellyfin container remains unchanged, running, and healthy; the user performs the update manually.
7. A second workflow dispatch skips build and duplicate release creation while succeeding.

## Scope

Included:

- Docker Schema 2 publication compatibility;
- automatic GitHub Release creation for newest stable and prerelease builds;
- RC5 rebuild and release publication;
- read-only FFUNRAID update-status verification.

Excluded:

- recreating, restarting, or updating the FFUNRAID Jellyfin container;
- changing the correct Unraid image tag;
- changing the filter-query fix;
- publishing historical releases;
- opening the upstream Jellyfin pull request.

## Guided Gates

- **GG-1:** Confirm the RC5 GitHub Release tag, title, prerelease flag, notes, and target commit.
- **GG-2:** Confirm immutable and rolling tags both return Docker Schema 2 and the same digest.
- **GG-3:** Confirm Unraid records `status: "false"` with a non-null remote digest while the running container image ID stays unchanged and healthy.
- **GG-4:** Confirm a second workflow run skips build and duplicate release creation.
