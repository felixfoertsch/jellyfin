# Legacy Filter Review Amendment Design

## Goal

Resolve the review findings without changing the verified production query: expand the source commit's regression coverage, correct image immutability claims, reconcile every dependent branch and published artifact, and preserve an auditable linear history.

## Current State

- `master`, `origin/master`, and `upstream/master` point to `33a8cdfc0b77d7a2439aeb3472db5adda095b41b`.
- `fix/legacy-filter-tag-query` contains singular source commit `2121f9bee116e7c10a482a1931f1dbf94818299d`.
- `build/legacy-filter-query-image` contains workflow commit `bbb50cc4bdd06db8d749f6cf6cf0c87fbc5fbafd` above that source commit.
- The existing GHCR image digest is `sha256:83b5bbf58ecb9d45206dfbafe7ad063cf61bd4a59bc2516003a41c9f147a512d`.
- The current documentation head is `8057ee4b3e597f564628ce18eac849d5d5b3d7ca` on `docs/legacy-filter-query-fix-design`.
- The source review found no production correctness defect. It found missing negative test coverage for the tag-type and matching-item predicates.
- The documentation review found an inconsistency: it correctly identifies the digest as immutable while still calling the full-SHA tag immutable. The workflow can overwrite that tag during a rerun because it rebuilds without cache from mutable transitive inputs.

## Chosen Approach

Reconcile the complete dependency chain rather than leaving pushed branches or package metadata stale.

1. Amend the source commit with test-only coverage. Keep the production query hunk byte-for-byte unchanged.
2. Recreate the build branch linearly from the amended source commit. Amend its single workflow commit with the amended source SHA and digest-oriented terminology.
3. Amend the current documentation commit with the new source references, corrected tag language, this design, and the implementation plan.
4. Force-with-lease push only the two already-published feature branches after verifying their expected remote tips.
5. Let the build-branch push publish a new image. Preserve the old full-SHA tag and package version as historical evidence.
6. Validate the new package and a disposable Unraid container without changing production.
7. Promote the final verified state into the existing Unraid Jellyfin project memory.

## Source Commit

Extend `BaseItemRepositoryLegacyFilterTests` with two negative fixtures:

- a non-`Tags` `ItemValue` mapped to a Movie that matches the query;
- a `Tags` `ItemValue` mapped to an item type excluded by `IncludeItemTypes`.

The expected tag result remains exactly `Alpha`, `Beta`. This protects the two predicates at `BaseItemRepository.Querying.cs:567-568` while retaining the existing clean-value grouping, minimum display value, ordering, and SQL-shape assertions.

No production source, schema, migration, public contract, or runtime configuration changes belong in the amendment.

## Test Proof

Use mutation checks to prove the expanded test detects both regressions:

1. Add both fixtures and assertions.
2. Temporarily remove the `ItemValueType.Tags` predicate and run the focused test. Require failure because the non-tag value leaks into `result.Tags`.
3. Restore the predicate.
4. Temporarily remove the `matchingItemIds` predicate and run the focused test. Require failure because the excluded item's tag leaks into `result.Tags`.
5. Restore the production file exactly.
6. Run the focused test, all Item repository tests, the Release build, format verification, and diff checks.

The mutations never enter a commit.

## Build Branch

Recreate `build/legacy-filter-query-image` from the amended fix commit, then apply and amend its existing workflow commit. The final branch contains exactly:

1. the amended fix commit;
2. one build-only workflow commit.

Update every hard-coded fix revision in the workflow to the amended fix commit's full SHA. Keep repository and action revisions pinned. Replace the workflow summary label `Immutable` for the full-SHA tag with `Commit tag`, and identify the Buildx output digest as the immutable artifact.

The workflow continues to publish:

- stable tag `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query`;
- commit-addressed tag `ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-${GITHUB_SHA}`.

Neither tag is the rollback identity. Validation and deployment references use the digest-qualified `ghcr.io/felixfoertsch/jellyfin@sha256:...` form recorded by the successful workflow run.

## Documentation

Update the image-build design and plan so they consistently distinguish:

- commit-pinned repository sources and action revisions;
- mutable transitive base images, hosted runner tooling, installers, and package feeds;
- mutable stable and commit-addressed tags;
- immutable content digests.

Replace the old source SHA throughout the active fix and image-build documents. Keep the old build SHA and digest only where explicitly identified as historical state.

## Publication

Before rewriting a remote branch, fetch origin and require its tip to equal the reviewed old SHA. Push with an explicit force-with-lease expectation so concurrent remote work fails safely instead of being overwritten.

Push the amended fix branch first, then the reconciled build branch. The build-branch push triggers one GitHub Actions run for the new build SHA. Do not push the local documentation branch unless separately requested.

The new workflow run may produce a different digest even though the production query is unchanged. Mutable transitive inputs make that expected. Record the exact run URL, build SHA, and published digest.

## Remote Validation

Require all of these gates:

- the workflow run succeeds for the exact pushed build SHA;
- actionlint, permissions, action pins, source pins, labels, and branch topology pass;
- the package remains public;
- stable and new commit-addressed tags resolve to the new digest;
- the old full-SHA tag remains available as historical evidence;
- Unraid can pull the new tags and digest without GHCR credentials;
- image architecture, entrypoint, health check, build label, and amended fix label match;
- an exact-name disposable container reaches `healthy` and is removed;
- the production `jellyfin` container and persistent template remain unchanged.

Do not deploy or repoint production during this work.

## Memory And Tracking

Update `knowledge/memory/project-unraid-jellyfin.md` with the final source and build SHAs, workflow run, image digest, verification result, remaining test characteristics, and the rule that rollback/deployment identity uses the digest rather than a tag. Cite this user-approved review and amendment as provenance.

Run memory lint, QMD update, QMD embedding, and a targeted retrieval check. Mark the durable TODO complete only after source, publication, remote validation, and memory gates pass.

## Failure Handling

- Abort an amendment if the relevant worktree is dirty.
- Abort a force push if the remote lease does not match the reviewed old tip.
- If the workflow fails, preserve logs and do not move production.
- If package or disposable-container validation fails, keep the old image available and do not mark the amendment complete.
- Never delete the old full-SHA tag or package version during this workflow.

## Guided Gates

- **GG-1:** Confirm the amended source commit changes only the test fixture and retains the exact production query hunk.
- **GG-2:** Confirm both intentional mutations make the focused test fail for the expected leaked value.
- **GG-3:** Confirm the final fix branch is one commit above master and the build branch is one additional workflow commit above the fix.
- **GG-4:** Confirm both force-with-lease expectations name the reviewed old remote tips before pushing.
- **GG-5:** Confirm the new workflow run, tags, digest, labels, anonymous pulls, and disposable health all match the amended SHAs.
- **GG-6:** Confirm the live Unraid template and production container remain unchanged.
- **GG-7:** Confirm curated-memory lint and targeted QMD retrieval pass before closing the TODO.
