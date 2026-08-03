# Legacy Filter Review Amendment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Amend the reviewed Jellyfin source and documentation commits, reconcile the dependent image-build branch and GHCR artifact, validate the result without deploying production, and promote the verified state to project memory.

**Architecture:** Keep the production query byte-for-byte unchanged and strengthen its existing SQLite regression test with two negative fixtures proven by mutation checks. Rebase the single workflow commit onto the amended source commit, update every embedded revision and tag-immutability claim, publish a replacement image through the existing pinned workflow, and use the resulting digest as the only immutable artifact identity.

**Tech Stack:** C# 14, .NET 10.0.302, EF Core 10, SQLite, xUnit, Git worktrees, GitHub Actions, Docker Buildx, GHCR, Unraid Docker, QMD

## Global Constraints

- Base commit remains `33a8cdfc0b77d7a2439aeb3472db5adda095b41b` on `master`, `origin/master`, and `upstream/master`.
- The amended fix branch remains exactly one commit above master.
- The production hunk in `BaseItemRepository.Querying.cs:561-572` remains byte-for-byte identical to source commit `2121f9bee116e7c10a482a1931f1dbf94818299d`.
- The amended fix commit adds only regression-test coverage.
- The build branch remains exactly one workflow commit above the amended fix commit.
- Rewrite published branches only with explicit force-with-lease expectations for old tips `2121f9bee116e7c10a482a1931f1dbf94818299d` and `bbb50cc4bdd06db8d749f6cf6cf0c87fbc5fbafd`.
- Preserve the old full-SHA image tag and package version as historical evidence.
- Treat image tags as mutable references and the workflow-recorded content digest as the immutable rollback identity.
- Do not push the local documentation branch, open a pull request, modify the Unraid template, or replace/restart the production Jellyfin container.
- Stop on a dirty worktree, changed remote lease, failed test, failed build, failed workflow, package mismatch, disposable-container failure, or production-state mismatch.

---

## File Map

- Modify: `tests/Jellyfin.Server.Implementations.Tests/Item/BaseItemRepositoryLegacyFilterTests.cs`
  - Add one non-tag value on a matching Movie and one tag on an excluded Audio item.
- Preserve unchanged: `Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs`
  - Temporarily mutate one predicate at a time only to prove the test fails, then restore exactly.
- Modify: `.github/workflows/build-legacy-filter-query-image.yml`
  - Replace the old fix SHA after rebasing and distinguish the commit tag from the immutable digest.
- Modify: `docs/superpowers/specs/2026-08-03-legacy-filter-image-build-design.md`
  - Replace the old fix SHA and correct all tag-immutability claims.
- Modify: `docs/superpowers/plans/2026-08-03-legacy-filter-image-build.md`
  - Replace the old fix SHA and use digest-qualified validation/rollback language.
- Preserve historical state in: `docs/superpowers/specs/2026-08-03-legacy-filter-review-amendment-design.md`
- Update after all gates: `/Users/felixfoertsch/.syncthing/dotfiles/knowledge/memory/project-unraid-jellyfin.md`
- Complete after all gates: `/Users/felixfoertsch/.syncthing/dotfiles/tools/todo/todo.kdl`

### Task 1: Expand And Prove The Source Regression Test

**Files:**
- Modify: `tests/Jellyfin.Server.Implementations.Tests/Item/BaseItemRepositoryLegacyFilterTests.cs:28-120`
- Temporarily mutate and restore: `Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs:567-568`

**Interfaces:**
- Consumes: `BaseItemRepository.GetQueryFiltersLegacy(InternalItemsQuery)` and the existing real in-memory SQLite fixture.
- Produces: an amended singular fix commit whose production tree matches `2121f9bee116e7c10a482a1931f1dbf94818299d` and whose test catches removal of either tag predicate.

- [ ] **Step 1: Verify the source worktree and branch base**

Run from `/Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/fix-legacy-filter-tag-query/`:

```bash
git status --short --branch
git rev-parse HEAD HEAD^ upstream/master origin/fix/legacy-filter-tag-query
git diff --check upstream/master..HEAD
```

Require a clean worktree, `HEAD=2121f9bee116e7c10a482a1931f1dbf94818299d`, `HEAD^=upstream/master=33a8cdfc0b77d7a2439aeb3472db5adda095b41b`, and the origin fix ref at the reviewed old SHA.

- [ ] **Step 2: Add the excluded type name and negative fixtures**

Add the field beside `_movieTypeName`:

```csharp
private readonly string _audioTypeName;
```

Initialize it beside `_movieTypeName`:

```csharp
_audioTypeName = itemTypeLookup.BaseItemKindNames[BaseItemKind.Audio];
```

Add these objects after `secondItem` and `secondTag` are created:

```csharp
var excludedItem = new BaseItemEntity
{
    Id = Guid.NewGuid(),
    Type = _audioTypeName,
    Name = "Excluded Audio",
    MediaType = "Audio",
    IsMovie = false,
    IsFolder = false,
    IsVirtualItem = false
};
var nonTagValue = new ItemValue
{
    ItemValueId = Guid.NewGuid(),
    Type = ItemValueType.Genre,
    Value = "Genre Leak",
    CleanValue = "genre leak"
};
var excludedTag = new ItemValue
{
    ItemValueId = Guid.NewGuid(),
    Type = ItemValueType.Tags,
    Value = "Excluded Tag",
    CleanValue = "excluded tag"
};
```

Extend the existing seed calls exactly:

```csharp
context.BaseItems.AddRange(firstItem, secondItem, excludedItem);
context.ItemValues.AddRange(firstTag, duplicateTag, secondTag, nonTagValue, excludedTag);
context.ItemValuesMap.AddRange(
    CreateMap(firstItem, firstTag),
    CreateMap(firstItem, duplicateTag),
    CreateMap(secondItem, secondTag),
    CreateMap(firstItem, nonTagValue),
    CreateMap(excludedItem, excludedTag));
```

Keep the literal expected result unchanged:

```csharp
Assert.Equal(["Alpha", "Beta"], result.Tags);
```

The production change that must fail this assertion is removal of either `.Where(iv => iv.Type == ItemValueType.Tags)` or `.Where(iv => matchingItemIds.Contains(iv.ItemId))`.

- [ ] **Step 3: Prove RED for the tag-type predicate**

Temporarily change the production chain from:

```csharp
.Where(iv => iv.Type == ItemValueType.Tags)
.Where(iv => matchingItemIds.Contains(iv.ItemId))
```

to:

```csharp
.Where(iv => matchingItemIds.Contains(iv.ItemId))
```

Run:

```bash
mise exec dotnet@10.0.302 -- dotnet test tests/Jellyfin.Server.Implementations.Tests/Jellyfin.Server.Implementations.Tests.csproj --configuration Release --no-restore --filter FullyQualifiedName~BaseItemRepositoryLegacyFilterTests
```

Require test failure because `result.Tags` contains `Genre Leak`. A compile error or unrelated failure does not satisfy RED.

- [ ] **Step 4: Restore the tag-type predicate and prove RED for matching items**

Restore the type predicate, then temporarily change the production chain to:

```csharp
.Where(iv => iv.Type == ItemValueType.Tags)
```

Run the focused test command again. Require test failure because `result.Tags` contains `Excluded Tag`.

- [ ] **Step 5: Restore production exactly and verify GREEN**

Restore both predicates:

```csharp
.Where(iv => iv.Type == ItemValueType.Tags)
.Where(iv => matchingItemIds.Contains(iv.ItemId))
```

Run:

```bash
git diff 2121f9bee116e7c10a482a1931f1dbf94818299d -- Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs
mise exec dotnet@10.0.302 -- dotnet test tests/Jellyfin.Server.Implementations.Tests/Jellyfin.Server.Implementations.Tests.csproj --configuration Release --no-restore --filter FullyQualifiedName~BaseItemRepositoryLegacyFilterTests
mise exec dotnet@10.0.302 -- dotnet test tests/Jellyfin.Server.Implementations.Tests/Jellyfin.Server.Implementations.Tests.csproj --configuration Release --no-restore --filter FullyQualifiedName~Jellyfin.Server.Implementations.Tests.Item
mise exec dotnet@10.0.302 -- dotnet build Jellyfin.Server.Implementations/Jellyfin.Server.Implementations.csproj --configuration Release --no-restore
mise exec dotnet@10.0.302 -- dotnet format --verify-no-changes --verbosity minimal
git diff --check
```

Require an empty production-file diff, focused test PASS, all 10 Item tests PASS, Release build with zero errors, format exit `0`, and whitespace exit `0`. Existing `NU1903` warnings remain baseline warnings.

- [ ] **Step 6: Amend the singular source commit**

Inspect before committing:

```bash
git status --short
git diff -- tests/Jellyfin.Server.Implementations.Tests/Item/BaseItemRepositoryLegacyFilterTests.cs
git log --oneline -10
```

Stage only the test and amend:

```bash
git add tests/Jellyfin.Server.Implementations.Tests/Item/BaseItemRepositoryLegacyFilterTests.cs
git diff --cached --check
git commit --amend --no-edit
```

Verify:

```bash
git rev-list --count upstream/master..HEAD
git diff --name-status upstream/master..HEAD
git diff 2121f9bee116e7c10a482a1931f1dbf94818299d HEAD -- Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs
git status --short --branch
```

Require one commit above master, exactly the original production file plus expanded test in the branch diff, an empty production-file comparison against old fix commit `2121f9b`, and a clean worktree. Record the new full fix SHA from `git rev-parse HEAD`.

### Task 2: Reconcile The Build Workflow Commit

**Files:**
- Modify: `.github/workflows/build-legacy-filter-query-image.yml:47-53,80-85,98-111`

**Interfaces:**
- Consumes: the amended fix commit full SHA from Task 1.
- Produces: a build branch exactly one workflow commit above the amended fix commit, with all labels and checks naming that amended fix SHA.

- [ ] **Step 1: Verify the build worktree and old topology**

Run from `/Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/build-legacy-filter-query-image/`:

```bash
git status --short --branch
git rev-parse HEAD HEAD^ origin/build/legacy-filter-query-image
git rev-list --count 2121f9bee116e7c10a482a1931f1dbf94818299d..HEAD
```

Require a clean worktree, `HEAD=origin/build/legacy-filter-query-image=bbb50cc4bdd06db8d749f6cf6cf0c87fbc5fbafd`, parent `2121f9bee116e7c10a482a1931f1dbf94818299d`, and count `1`.

- [ ] **Step 2: Rebase the workflow commit onto the amended fix**

Resolve the amended fix SHA from the fix worktree and rebase non-interactively:

```bash
fix_sha=$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/fix-legacy-filter-tag-query rev-parse HEAD)
git rebase --onto "$fix_sha" 2121f9bee116e7c10a482a1931f1dbf94818299d build/legacy-filter-query-image
```

Require one replayed workflow commit and no conflict.

- [ ] **Step 3: Update revision labels and digest terminology**

Replace every occurrence of old fix SHA `2121f9bee116e7c10a482a1931f1dbf94818299d` in the workflow with the exact `fix_sha` from Step 2.

Replace the summary body with:

```bash
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

Add `FIX_SHA` beside the existing summary environment variables:

```yaml
FIX_SHA: the exact amended fix commit full SHA
```

Use the literal full SHA value in YAML; do not derive the security check or label from a moving branch ref.

- [ ] **Step 4: Validate and amend the workflow commit**

Run:

```bash
mise exec actionlint@1.7.12 -- actionlint .github/workflows/build-legacy-filter-query-image.yml
git diff --check
git status --short
git log --oneline -3
```

Require actionlint and whitespace exit `0`, and only the workflow modified. Then inspect, stage, and amend:

```bash
git diff -- .github/workflows/build-legacy-filter-query-image.yml
git add .github/workflows/build-legacy-filter-query-image.yml
git diff --cached --check
git commit --amend --no-edit
```

Verify with runtime-derived SHAs:

```bash
fix_sha=$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/fix-legacy-filter-tag-query rev-parse HEAD)
test "$(git rev-parse HEAD^)" = "$fix_sha"
test "$(git rev-list --count "$fix_sha"..HEAD)" = "1"
git diff --name-status "$fix_sha"..HEAD
git status --short --branch
```

Require parent equality, count `1`, exactly one created workflow file relative to the amended fix, and a clean worktree. Record the new full build SHA from `git rev-parse HEAD`.

### Task 3: Correct And Amend The Documentation Commit

**Files:**
- Modify: `docs/superpowers/specs/2026-08-03-legacy-filter-image-build-design.md`
- Modify: `docs/superpowers/plans/2026-08-03-legacy-filter-image-build.md`
- Preserve: `docs/superpowers/specs/2026-08-03-legacy-filter-review-amendment-design.md`
- Preserve: `docs/superpowers/plans/2026-08-03-legacy-filter-review-amendment.md`

**Interfaces:**
- Consumes: amended fix and build full SHAs from Tasks 1-2.
- Produces: one amended local documentation head with current revision references and consistent digest-oriented artifact language.

- [ ] **Step 1: Replace active fix references**

Resolve the amended fix SHA:

```bash
fix_sha=$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/fix-legacy-filter-tag-query rev-parse HEAD)
```

In these two files, replace every exact old fix SHA `2121f9bee116e7c10a482a1931f1dbf94818299d` with the literal value of `fix_sha`:

```text
docs/superpowers/specs/2026-08-03-legacy-filter-image-build-design.md
docs/superpowers/plans/2026-08-03-legacy-filter-image-build.md
```

Do not replace the old SHA in the amendment design's `Current State`; that section intentionally records the pre-amendment state.

- [ ] **Step 2: Correct immutable-tag claims in the image-build design**

Use these meanings consistently:

```text
stable tag             mutable convenience reference
full-SHA tag           commit-addressed audit reference, still mutable
sha256 content digest  immutable validation, rollback, and deployment identity
```

Change the published-image paragraph to state that both tags resolve to the workflow-recorded digest immediately after publication, while only the digest identifies immutable content. Update GitHub checks, image checks, success criteria, and Guided Gates to use `stable and commit-addressed tags` rather than `stable and immutable tags`.

- [ ] **Step 3: Correct plan commands and summary language**

Update the embedded workflow summary in the plan to match Task 2 exactly: `Stable tag`, `Commit tag`, and `Immutable digest`.

Update the publication interface and verification prose to call the full-SHA tag commit-addressed. Add digest-qualified verification after reading the run's digest: Unraid must pull and inspect the exact `ghcr.io/felixfoertsch/jellyfin@sha256:...` value recorded by the run, not infer immutable identity from either tag.

Keep both tags and the digest in verification because tag-to-digest agreement remains an operational gate.

- [ ] **Step 4: Amend the local documentation head**

Run:

```bash
git status --short --branch
git diff --check
git diff -- docs/superpowers/specs/2026-08-03-legacy-filter-image-build-design.md docs/superpowers/plans/2026-08-03-legacy-filter-image-build.md
git log --oneline -10
```

Require only the two image-build documents modified and the already committed design/plan present in history. Stage only the two changed files and amend:

```bash
git add docs/superpowers/specs/2026-08-03-legacy-filter-image-build-design.md docs/superpowers/plans/2026-08-03-legacy-filter-image-build.md
git diff --cached --check
git commit --amend --no-edit
```

Verify no active image-build document calls a tag immutable:

```bash
git grep -n -E 'immutable (tag|GHCR tag)|stable and immutable|Immutable:.*legacy-filter-query-' HEAD -- docs/superpowers/specs/2026-08-03-legacy-filter-image-build-design.md docs/superpowers/plans/2026-08-03-legacy-filter-image-build.md
git status --short --branch
```

Require no matches and a clean local documentation worktree.

### Task 4: Review The Rewritten Local History

**Files:**
- Review only: all files changed by amended fix, build, and documentation commits.

**Interfaces:**
- Consumes: final local commits from Tasks 1-3.
- Produces: an independent ready/not-ready verdict before any remote rewrite.

- [ ] **Step 1: Verify branch topology and exact change scopes**

Run:

```bash
fix_sha=$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/fix-legacy-filter-tag-query rev-parse HEAD)
build_sha=$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/build-legacy-filter-query-image rev-parse HEAD)
test "$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/fix-legacy-filter-tag-query rev-list --count upstream/master..HEAD)" = "1"
test "$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/build-legacy-filter-query-image rev-parse HEAD^)" = "$fix_sha"
test "$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/build-legacy-filter-query-image rev-list --count "$fix_sha"..HEAD)" = "1"
git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/fix-legacy-filter-tag-query diff --check upstream/master..HEAD
git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/build-legacy-filter-query-image diff --check "$fix_sha"..HEAD
git -C /Users/felixfoertsch/Developer/netfelix/jellyfin diff --check 74445ecc28d1e03f4e5d946152d20c19bf90091d..HEAD
```

Require every command to exit `0`.

- [ ] **Step 2: Rerun source and workflow verification**

Run the complete source gate from Task 1 Step 5 and actionlint from Task 2 Step 4 again. Do not rely on earlier output.

- [ ] **Step 3: Request independent code review**

Give the reviewer these ranges:

```text
source: 33a8cdfc0b77d7a2439aeb3472db5adda095b41b..${fix_sha}
build:  ${fix_sha}..${build_sha}
docs:   74445ecc28d1e03f4e5d946152d20c19bf90091d..${docs_sha}
```

Resolve all three variables with `git rev-parse` immediately before dispatch. Require the reviewer to verify production equivalence, negative test coverage, SQL assertion stability, workflow pins/permissions/revisions, tag-versus-digest semantics, force-push safety, and no production deployment path.

- [ ] **Step 4: Resolve every Critical or Important finding**

Do not publish while any Critical or Important finding remains. Apply valid fixes to the corresponding amended commit, rerun that task's complete verification, and request a follow-up review of the changed range.

### Task 5: Rewrite The Published Branches And Build The Image

**Files:**
- No additional local file changes.

**Interfaces:**
- Consumes: independently approved local fix and build commits.
- Produces: rewritten GitHub feature branches and one successful workflow run for the exact new build SHA.

- [ ] **Step 1: Fetch and enforce remote leases**

Run from the repository root:

```bash
git fetch origin
test "$(git rev-parse origin/fix/legacy-filter-tag-query)" = "2121f9bee116e7c10a482a1931f1dbf94818299d"
test "$(git rev-parse origin/build/legacy-filter-query-image)" = "bbb50cc4bdd06db8d749f6cf6cf0c87fbc5fbafd"
```

Abort if either comparison fails.

- [ ] **Step 2: Force-with-lease push the amended fix branch**

Run:

```bash
git push --force-with-lease=refs/heads/fix/legacy-filter-tag-query:2121f9bee116e7c10a482a1931f1dbf94818299d origin fix/legacy-filter-tag-query:fix/legacy-filter-tag-query
```

Verify `origin/fix/legacy-filter-tag-query` equals the local amended fix SHA after fetching.

- [ ] **Step 3: Force-with-lease push the reconciled build branch**

Run:

```bash
git push --force-with-lease=refs/heads/build/legacy-filter-query-image:bbb50cc4bdd06db8d749f6cf6cf0c87fbc5fbafd origin build/legacy-filter-query-image:build/legacy-filter-query-image
```

Verify `origin/build/legacy-filter-query-image` equals the local amended build SHA after fetching.

- [ ] **Step 4: Identify the exact push-triggered workflow run**

Resolve the local build SHA and poll GitHub until the newest run reports it:

```bash
build_sha=$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/build-legacy-filter-query-image rev-parse HEAD)
run_id=$(gh run list --repo felixfoertsch/jellyfin --workflow build-legacy-filter-query-image.yml --branch build/legacy-filter-query-image --event push --limit 1 --json databaseId,headSha --jq 'select(.[0].headSha == "'"$build_sha"'") | .[0].databaseId')
test -n "$run_id"
```

If GitHub has not created the run yet, wait and query again. Never select the prior run `30806504479`.

- [ ] **Step 5: Watch and record the workflow result**

Run:

```bash
gh run watch "$run_id" --repo felixfoertsch/jellyfin --exit-status
gh run view "$run_id" --repo felixfoertsch/jellyfin --json headSha,conclusion,url
```

Require success and exact `headSha=build_sha`. Record the run URL and Buildx output digest from the run summary/log.

### Task 6: Validate GHCR And Unraid Without Deploying

**Files:**
- No repository file changes.
- Create transiently on Unraid only: container `jellyfin-filter-image-validation`.

**Interfaces:**
- Consumes: exact build SHA and digest from Task 5.
- Produces: package, anonymous pull, image metadata, disposable health, and production non-change evidence.

- [ ] **Step 1: Verify package visibility, tags, and digest**

Resolve the final local revisions and the digest attached to the new commit tag:

```bash
fix_sha=$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/fix-legacy-filter-tag-query rev-parse HEAD)
build_sha=$(git -C /Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/build-legacy-filter-query-image rev-parse HEAD)
image_digest=$(gh api /user/packages/container/jellyfin/versions --paginate --jq '.[] | select(.metadata.container.tags[] == "legacy-filter-query-'"${build_sha}"'") | .name')
test -n "$image_digest"
```

Use authenticated read-only GitHub package metadata to require:

```text
visibility = public
legacy-filter-query = new workflow digest
legacy-filter-query-${build_sha} = ${image_digest}
legacy-filter-query-bbb50cc4bdd06db8d749f6cf6cf0c87fbc5fbafd = old digest sha256:83b5bbf58ecb9d45206dfbafe7ad063cf61bd4a59bc2516003a41c9f147a512d
```

Read package metadata with:

```bash
gh api /user/packages/container/jellyfin
gh api /user/packages/container/jellyfin/versions --paginate
```

Do not delete or retag the old version.

- [ ] **Step 2: Capture production and template baselines**

Before pulling or creating a disposable container, capture:

```bash
ssh unraid "docker inspect jellyfin --format 'Image={{.Config.Image}} ImageID={{.Image}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} RestartCount={{.RestartCount}}'"
ssh unraid "sha256sum /boot/config/plugins/dockerMan/templates-user/my-Jellyfin.xml"
ssh unraid "docker container inspect jellyfin-filter-image-validation"
```

The third command must report that no exact-name validation container exists. Abort instead of removing an unexpected existing container.

- [ ] **Step 3: Pull tags and digest anonymously**

Run from a session without configured GHCR credentials on Unraid:

```bash
ssh unraid "docker pull --platform linux/amd64 ghcr.io/felixfoertsch/jellyfin:legacy-filter-query"
ssh unraid "docker pull --platform linux/amd64 ghcr.io/felixfoertsch/jellyfin:legacy-filter-query-${build_sha}"
ssh unraid "docker pull --platform linux/amd64 ghcr.io/felixfoertsch/jellyfin@${image_digest}"
```

Require all pulls to succeed anonymously.

- [ ] **Step 4: Verify image metadata and tag agreement**

Inspect the stable tag, new commit tag, and digest-qualified reference. Require:

- one image ID and one `RepoDigests` content digest;
- architecture `amd64`, OS `linux`;
- entrypoint `[/jellyfin/jellyfin]`;
- localhost `8096/health` check;
- `org.opencontainers.image.revision` equals the new build SHA;
- `de.felixfoertsch.jellyfin.fix-revision` equals the amended fix SHA.

- [ ] **Step 5: Run the disposable health gate by digest**

Start only the exact validation container with the digest-qualified image:

```bash
ssh unraid "docker run --detach --name jellyfin-filter-image-validation ghcr.io/felixfoertsch/jellyfin@${image_digest}"
```

Poll every three seconds for at most 90 seconds. Require `healthy`; on failure, capture its inspect output and logs. After success, remove only that exact container:

```bash
ssh unraid "docker rm --force jellyfin-filter-image-validation"
```

- [ ] **Step 6: Prove production did not change**

Repeat the production inspect and template checksum commands from Step 2. Require byte-for-byte equal outputs, a running/healthy production container, and no restart-count change caused by this workflow.

### Task 7: Promote Memory And Close Tracking

**Files:**
- Modify: `/Users/felixfoertsch/.syncthing/dotfiles/knowledge/memory/project-unraid-jellyfin.md`
- Modify: `/Users/felixfoertsch/.syncthing/dotfiles/tools/todo/todo.kdl`

**Interfaces:**
- Consumes: final amended SHAs, workflow run URL, image digest, review verdict, test/build output, and Unraid validation evidence.
- Produces: validated project memory and completed durable TODO state.

- [ ] **Step 1: Recheck memory and index before writing**

Read the current target and matching `MEMORY.md` section immediately before editing. Search active memory again for the final amended fix SHA, build SHA, and image digest. Abort on a conflicting concurrent edit and reconcile it first.

- [ ] **Step 2: Update the existing project memory**

Set frontmatter `updated: 2026-08-03`. Add a focused section that records:

- the amended fix and build full SHAs and their one-plus-one branch topology;
- the production query review result: no correctness or non-tag behavior defect found;
- expanded negative coverage and both mutation RED proofs;
- final focused/Item/build/format verification counts and baseline warnings;
- workflow run URL and final public image digest;
- old digest `sha256:83b5bbf58ecb9d45206dfbafe7ad063cf61bd4a59bc2516003a41c9f147a512d` retained under its old full-SHA tag;
- stable and full-SHA tags are mutable references; digest-qualified references are the rollback/deployment identity;
- anonymous pulls, metadata, disposable health, and unchanged production gates passed;
- provenance: user-requested review and approved amendment on 2026-08-03.

Do not copy command logs or the completed TODO text into memory.

- [ ] **Step 3: Validate memory and retrieval**

Run from `/Users/felixfoertsch/.syncthing/dotfiles/`:

```bash
scripts/memory-lint.sh knowledge/memory
qmd update
qmd embed
```

Then query the memory collection for the amended fix SHA plus `digest rollback identity`. Require `project-unraid-jellyfin.md` as the top relevant active result and read the returned section to confirm exact facts.

- [ ] **Step 4: Complete the durable TODO**

Add `done="2026-08-03"` to the exact Jellyfin review/amendment item in `tools/todo/todo.kdl`. Run:

```bash
git diff --check -- knowledge/memory/project-unraid-jellyfin.md tools/todo/todo.kdl
```

Require exit `0`. Do not mark complete if any source, publication, remote validation, memory lint, embedding, or retrieval gate failed.

## Completion Boundary

Completion means the amended source test proves both negative predicates by mutation, all source and workflow checks pass, both published branches match the reconciled linear history, the new public image is identified by its recorded digest, anonymous Unraid pull and disposable health pass, production remains unchanged, curated memory retrieves the final facts, and the durable TODO is dated complete.
