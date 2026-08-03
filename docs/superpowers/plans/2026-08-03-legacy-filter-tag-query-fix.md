# Legacy Filter Tag Query Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the pathological correlated SQLite query generated for legacy tag filters while preserving returned tag values, distinctness, and ordering.

**Architecture:** Keep the existing legacy filter endpoint and repository contract. Change only the proven slow tags LINQ expression: group `ItemValueMap` rows directly instead of projecting the `ItemValue` navigation before grouping, which lets EF Core emit one aggregate query rather than duplicated correlated `MIN` subqueries. Protect both SQL shape and public result semantics with an in-memory SQLite repository test, then validate the identical change against the unchanged production library on Jellyfin v12.0-rc4.

**Tech Stack:** C# 14, .NET 10.0.302, EF Core 10, SQLite, xUnit, Docker, Unraid

## Global Constraints

- The final upstream branch starts at current `upstream/master` and contains only the focused test and tags query rewrite.
- Preserve `QueryFiltersLegacy.Tags` values, case-folded distinctness through `CleanValue`, minimum original `Value` selection, and ascending ordering.
- Do not change years, official ratings, genres, endpoint contracts, plugins, authentication, or database schema.
- The regression test must fail on unmodified upstream because the generated tags SQL contains duplicated correlated aggregate translation, not because of wall-clock timing.
- Production validation uses the unchanged library and exact request path captured privately on 2026-08-03; private user IDs, library IDs, SQL, and filter values never enter Git.
- The temporary RC4 image must derive from exact official image ID `sha256:92161eb68b27ff6f1e61a9685f56b2798bd36d840311c140077279cde4853d62` and preserve every runtime setting and mount.

---

## File Map

- Modify: `Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs`
  - Rewrite only the tags grouping source.
- Create: `tests/Jellyfin.Server.Implementations.Tests/Item/BaseItemRepositoryLegacyFilterTests.cs`
  - Seed tag variants, capture executed SQLite SQL, assert semantics and one direct aggregate join shape.
- Create privately on Unraid: `/mnt/cache/appdata/jellyfin/diagnostics/legacy-filter-fix-<UTC>/`
  - Preserve template, response counts, timings, checksums, and health evidence; do not commit it.

### Task 1: Add The Regression Test And Minimal Query Rewrite

**Files:**
- Create: `tests/Jellyfin.Server.Implementations.Tests/Item/BaseItemRepositoryLegacyFilterTests.cs`
- Modify: `Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs:561-568`

**Interfaces:**
- Consumes: `BaseItemRepository.GetQueryFiltersLegacy(InternalItemsQuery)` and existing SQLite repository-test construction.
- Produces: unchanged `QueryFiltersLegacy`; only the generated SQL shape for `Tags` changes.

- [ ] **Step 1: Write a failing SQLite repository test**

Create a test fixture following `BaseItemRepositoryGroupingTests`: open one in-memory `SqliteConnection`, call `EnsureCreated`, mock `IDbContextFactory<JellyfinDbContext>`, and construct the real `BaseItemRepository`.

Add a test-only `DbCommandInterceptor` that records `command.CommandText` from `ReaderExecuting`. Seed two eligible `BaseItemEntity` rows, three `ItemValue` tag rows, and their `ItemValueMap` relationships:

```csharp
var firstTag = new ItemValue
{
    ItemValueId = Guid.NewGuid(),
    Type = ItemValueType.Tags,
    Value = "Alpha",
    CleanValue = "alpha"
};
var duplicateTag = new ItemValue
{
    ItemValueId = Guid.NewGuid(),
    Type = ItemValueType.Tags,
    Value = "alpha",
    CleanValue = "alpha"
};
var secondTag = new ItemValue
{
    ItemValueId = Guid.NewGuid(),
    Type = ItemValueType.Tags,
    Value = "Beta",
    CleanValue = "beta"
};
```

Invoke `GetQueryFiltersLegacy` with an `InternalItemsQuery` that includes the seeded item type and no user exclusions. Assert:

```csharp
Assert.Equal(["Alpha", "Beta"], result.Tags);
var tagsCommand = Assert.Single(interceptor.Commands.Where(command => command.Contains("GROUP BY", StringComparison.Ordinal)));
Assert.Equal(1, CountOccurrences(tagsCommand, "INNER JOIN \"ItemValues\""));
Assert.DoesNotContain("SELECT (", tagsCommand, StringComparison.Ordinal);
```

The helper counts exact non-overlapping ordinal occurrences. The semantic assertion proves clean-value grouping, minimum original value selection, de-duplication, and ordering; the SQL assertions reject the correlated navigation pre-projection.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
mise exec dotnet@10.0.302 -- dotnet test tests/Jellyfin.Server.Implementations.Tests/Jellyfin.Server.Implementations.Tests.csproj --configuration Release --filter FullyQualifiedName~BaseItemRepositoryLegacyFilterTests
```

Expected: the result semantics already pass, but the SQL-shape assertion fails because the current tags query contains three `INNER JOIN "ItemValues"` occurrences and begins with a correlated `SELECT (` aggregate.

- [ ] **Step 3: Implement the minimal tags query rewrite**

Replace only the tags query's pre-projected grouping:

```csharp
var tags = context.ItemValuesMap
    .Where(ivm => ivm.ItemValue.Type == ItemValueType.Tags)
    .Where(ivm => matchingItemIds.Contains(ivm.ItemId))
    .GroupBy(ivm => ivm.ItemValue.CleanValue)
    .Select(g => g.Min(ivm => ivm.ItemValue.Value))
    .OrderBy(t => t)
    .ToArray();
```

Leave the genres query and all other code unchanged.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Step 2 command again.

Expected: PASS; the command contains one direct `ItemValues` join and returns exactly `Alpha`, `Beta`.

- [ ] **Step 5: Run repository verification**

```bash
mise exec dotnet@10.0.302 -- dotnet test tests/Jellyfin.Server.Implementations.Tests/Jellyfin.Server.Implementations.Tests.csproj --configuration Release --no-restore --filter FullyQualifiedName~Jellyfin.Server.Implementations.Tests.Item
mise exec dotnet@10.0.302 -- dotnet build Jellyfin.Server.Implementations/Jellyfin.Server.Implementations.csproj --configuration Release --no-restore
mise exec dotnet@10.0.302 -- dotnet format --verify-no-changes --verbosity minimal
git diff --check
```

Expected: all tests and build pass with zero errors; formatting and whitespace checks exit `0`. Existing dependency vulnerability warnings remain baseline warnings, not new failures.

- [ ] **Step 6: Commit the coherent fix**

```bash
git add Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs tests/Jellyfin.Server.Implementations.Tests/Item/BaseItemRepositoryLegacyFilterTests.cs
git commit -m "avoid correlated legacy tag filter query"
```

Expected: one commit containing only the production rewrite and regression test.

### Task 2: Validate And Deploy The Identical RC4 Fix

**Files:**
- Apply production hunk to: RC4 validation branch `validation/v12.0-rc4-legacy-filter-tags`
- Create privately: `/mnt/cache/appdata/jellyfin/diagnostics/legacy-filter-fix-<UTC>/`
- Modify remotely: `/boot/config/plugins/dockerMan/templates-user/my-Jellyfin.xml`

**Interfaces:**
- Consumes: reviewed production hunk and test evidence from Task 1.
- Produces: temporary local RC4 image with the identical repository change, production timing evidence, and responsive Jellyfin service.

- [ ] **Step 1: Apply only the reviewed production hunk to RC4**

Create `validation/v12.0-rc4-legacy-filter-tags` at tag `v12.0-rc4`. Apply only the tags query hunk from Task 1; exclude its test if test fixtures differ and exclude all diagnostic instrumentation. Build `Jellyfin.Server.Implementations.csproj`, run the focused existing Item tests, verify the diff, and commit as `avoid correlated legacy tag filter query`.

- [ ] **Step 2: Build an exact-base temporary image**

Build the modified RC4 assembly with .NET `10.0.302`. Copy only `Jellyfin.Server.Implementations.dll` over official image ID `sha256:92161eb68b27ff6f1e61a9685f56b2798bd36d840311c140077279cde4853d62`, tag it `jellyfin-local:12.0-rc4-filter-fix-<commit7>`, and verify the in-image SHA-256 equals the local assembly SHA-256.

- [ ] **Step 3: Capture preflight and deploy through the Unraid template**

Create one UTC evidence directory, back up the exact template, verify `PRAGMA quick_check`, official image identity, `/config` source `/mnt/cache/appdata/jellyfin`, both `/dev/dri` mappings, three bounded local health samples, and the public endpoint. Replace only `<Repository>`, run Unraid Docker Manager `update_container`, then recheck the same runtime gates.

- [ ] **Step 4: Run the exact production request once**

Issue the authenticated legacy request for the known YouTube parent with a 30-second abort. Record duration and only the four result counts. Gate passes when HTTP is `200`, duration is below 5 seconds, and counts equal the diagnostic baseline: Years `20`, OfficialRatings `0`, Tags `60767`, Genres `12`.

- [ ] **Step 5: Verify sustained responsiveness**

Run `/Items/Filters2` for the same parent and three `/Users/Public` probes. Verify no fresh SQLite lock, failed-command, or authentication errors; Docker stays healthy with fewer than 100 PIDs and without sustained CPU saturation after requests complete.

- [ ] **Step 6: Keep the temporary fixed image active pending upstream review**

Leave the template on the immutable local fixed image only after every gate passes. Keep the exact template backup and official preview image available for immediate rollback. Do not delete the image or evidence directory.

### Task 3: Prepare The Upstream Contribution

**Files:**
- No additional production files.
- Review: Task 1 commit and production evidence.

**Interfaces:**
- Consumes: clean upstream-master commit and production validation evidence.
- Produces: reviewed commit and draft pull-request text; publication remains behind Guided Gate 4.

- [ ] **Step 1: Rebase and rerun verification**

Fetch `upstream/master`, rebase `fix/legacy-filter-tag-query`, then rerun Task 1 Step 5.

- [ ] **Step 2: Draft the pull request**

Explain the duplicated correlated aggregate translation, direct-grouping rewrite, deterministic SQL-shape regression, unchanged result counts, and observed `111.574s` before versus validated timing after. Include Jellyfin's required AI-assistance disclosure. Exclude private identifiers, SQL parameters, diagnostic branches, image details, and production logs.

- [ ] **Step 3: Stop at Guided Gate 4**

Present the final diff, commit, verification output, production before/after timing, and draft PR text for human review. Do not push the fix branch or create the pull request before explicit approval.

## Success Criteria

- The deterministic regression test fails before and passes after the one-expression rewrite.
- The upstream diff changes only the tags query and adds focused coverage.
- Production returns identical filter counts in under 5 seconds.
- Jellyfin remains healthy and responsive with the temporary fixed RC4 image.
- The upstream contribution remains unpublished until Guided Gate 4 approval.
