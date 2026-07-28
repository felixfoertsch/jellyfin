# Legacy Filter Query Diagnosis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove which `GetQueryFiltersLegacy` query causes the two-minute RC3 stall and capture its exact generated SQL without changing request semantics.

**Architecture:** A disposable branch based on the exact Jellyfin `v12.0-rc3` tag adds phase-level timing and SQL logging around the four existing query materializations. A branch-only GitHub Actions workflow combines that server revision with pinned RC3 web assets and the official RC3 packaging Dockerfile, then an immutable GHCR image is deployed once through the Unraid template, observed, and rolled back. This plan ends at Guided Gate 1; the evidence determines a separate test-and-fix plan against current upstream `master`.

**Tech Stack:** C# 14, .NET 10, EF Core 10, SQLite, xUnit, GitHub Actions, Docker Buildx, GHCR, Unraid Docker Manager

---

## File Map

- Modify: `Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs`
  - Temporary phase timing and generated-SQL logging only.
- Create: `.github/workflows/temporary-rc3-image.yml`
  - Temporary `linux/amd64` image build from pinned RC3 server, web, and packaging revisions.
- Preserve unchanged: `docs/superpowers/specs/2026-07-28-legacy-filter-query-fix-design.md`
  - Approved design remains on its separate documentation branch.
- Do not create a test in this disposable branch.
  - The instrumentation does not alter query behavior, and a logger test cannot reproduce the production query plan. The final fix branch must start with a deterministic failing regression test after diagnosis identifies the mechanism.

## Fixed Revisions And Runtime Facts

- Server RC3: `fc43f151a2418cc112e116050a99dd6318917ab0`
- Web RC3: `4983aec1e8cd85adaa2b8024a8c30bd31ca78d7f`
- RC3 packaging: `846b546838941cefac00cfe5ac08d9adf6dff26c`
- Official production image before and after diagnosis: `jellyfin/jellyfin:preview`
- Verified official production image ID: `sha256:2bcce80cd1f080c000b94536eb90118709f08974e3ff71b109bb6b74c24027d8`
- Unraid container: `jellyfin`
- Unraid template: `/boot/config/plugins/dockerMan/templates-user/my-Jellyfin.xml`
- Production database: `/mnt/cache/appdata/jellyfin/data/jellyfin.db`
- Production logs: `/mnt/cache/appdata/jellyfin/log/`
- Private evidence root: `/mnt/cache/appdata/jellyfin/diagnostics/`

### Task 1: Create The Isolated RC3 Diagnostic Worktree

**Files:**
- No repository file changes.

- [ ] **Step 1: Confirm the documentation branch is clean**

Run from `/Users/felixfoertsch/Developer/netfelix/jellyfin/`:

```fish
git status --short --branch
```

Expected: branch `docs/legacy-filter-query-fix-design` with no changed or untracked files.

- [ ] **Step 2: Add the canonical upstream remote**

```fish
git remote add upstream https://github.com/jellyfin/jellyfin.git
```

Expected: no output. If `upstream` already exists, verify it instead of replacing it:

```fish
git remote get-url upstream
```

Expected: `https://github.com/jellyfin/jellyfin.git`.

- [ ] **Step 3: Fetch current upstream master and the exact RC3 tag**

```fish
git fetch upstream master tag v12.0-rc3
```

Expected: `upstream/master` and local tag `v12.0-rc3` update successfully.

- [ ] **Step 4: Verify the RC3 tag identity**

```fish
git rev-parse v12.0-rc3^{commit}
```

Expected exactly:

```text
fc43f151a2418cc112e116050a99dd6318917ab0
```

- [ ] **Step 5: Create an isolated worktree using the worktree skill**

Invoke `superpowers:using-git-worktrees`, then create branch `diagnosis/v12.0-rc3-legacy-filters` at `v12.0-rc3`. Use this exact worktree when the skill confirms the location is safe:

```text
/Users/felixfoertsch/Developer/netfelix/jellyfin/.worktrees/diagnosis-v12.0-rc3-legacy-filters/
```

Expected branch point:

```fish
git rev-parse HEAD
```

```text
fc43f151a2418cc112e116050a99dd6318917ab0
```

- [ ] **Step 6: Confirm the target method matches the diagnosed RC3 implementation**

```fish
git diff --exit-code v12.0-rc3 -- Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs
```

Expected: no output and exit status `0`.

### Task 2: Add Disposable Phase Instrumentation

**Files:**
- Modify: `Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs:3-14`
- Modify: `Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs:495-545`

- [ ] **Step 1: Add the required diagnostic namespaces**

Add `System.Diagnostics` and `Microsoft.Extensions.Logging` while retaining the file's existing ordering:

```csharp
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using Jellyfin.Data.Enums;
using Jellyfin.Database.Implementations;
using Jellyfin.Database.Implementations.Entities;
using Jellyfin.Extensions;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Model.Querying;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
```

- [ ] **Step 2: Replace only `GetQueryFiltersLegacy` with instrumented equivalent queries**

Keep every LINQ expression unchanged. Split each expression into an `IQueryable`, render SQL before starting the timer, materialize exactly once, and log the result count afterward:

```csharp
    /// <inheritdoc />
    public QueryFiltersLegacy GetQueryFiltersLegacy(InternalItemsQuery filter)
    {
        ArgumentNullException.ThrowIfNull(filter);
        PrepareFilterQuery(filter);

        using var context = _dbProvider.CreateDbContext();
        var baseQuery = PrepareItemQuery(context, filter);
        baseQuery = TranslateQuery(baseQuery, context, filter);

        var matchingItemIds = baseQuery.Select(e => e.Id);

        var yearsQuery = baseQuery
            .Where(e => e.ProductionYear != null && e.ProductionYear > 0)
            .Select(e => e.ProductionYear!.Value)
            .Distinct()
            .OrderBy(y => y);

        _logger.LogInformation(
            "GetQueryFiltersLegacy phase {Phase} SQL:{NewLine}{Query}",
            "Years",
            Environment.NewLine,
            yearsQuery.ToQueryString());
        _logger.LogInformation("GetQueryFiltersLegacy phase {Phase} started", "Years");

        var yearsStartTimestamp = Stopwatch.GetTimestamp();
        var years = yearsQuery.ToArray();

        _logger.LogInformation(
            "GetQueryFiltersLegacy phase {Phase} completed in {Elapsed:g} with {ResultCount} results",
            "Years",
            Stopwatch.GetElapsedTime(yearsStartTimestamp),
            years.Length);

        var officialRatingsQuery = baseQuery
            .Where(e => e.OfficialRating != null && e.OfficialRating != string.Empty)
            .Select(e => e.OfficialRating!)
            .Distinct()
            .OrderBy(r => r);

        _logger.LogInformation(
            "GetQueryFiltersLegacy phase {Phase} SQL:{NewLine}{Query}",
            "OfficialRatings",
            Environment.NewLine,
            officialRatingsQuery.ToQueryString());
        _logger.LogInformation("GetQueryFiltersLegacy phase {Phase} started", "OfficialRatings");

        var officialRatingsStartTimestamp = Stopwatch.GetTimestamp();
        var officialRatings = officialRatingsQuery.ToArray();

        _logger.LogInformation(
            "GetQueryFiltersLegacy phase {Phase} completed in {Elapsed:g} with {ResultCount} results",
            "OfficialRatings",
            Stopwatch.GetElapsedTime(officialRatingsStartTimestamp),
            officialRatings.Length);

        var tagsQuery = context.ItemValuesMap
            .Where(ivm => ivm.ItemValue.Type == ItemValueType.Tags)
            .Where(ivm => matchingItemIds.Contains(ivm.ItemId))
            .Select(ivm => ivm.ItemValue)
            .GroupBy(iv => iv.CleanValue)
            .Select(g => g.Min(iv => iv.Value))
            .OrderBy(t => t);

        _logger.LogInformation(
            "GetQueryFiltersLegacy phase {Phase} SQL:{NewLine}{Query}",
            "Tags",
            Environment.NewLine,
            tagsQuery.ToQueryString());
        _logger.LogInformation("GetQueryFiltersLegacy phase {Phase} started", "Tags");

        var tagsStartTimestamp = Stopwatch.GetTimestamp();
        var tags = tagsQuery.ToArray();

        _logger.LogInformation(
            "GetQueryFiltersLegacy phase {Phase} completed in {Elapsed:g} with {ResultCount} results",
            "Tags",
            Stopwatch.GetElapsedTime(tagsStartTimestamp),
            tags.Length);

        var genresQuery = context.ItemValuesMap
            .Where(ivm => ivm.ItemValue.Type == ItemValueType.Genre)
            .Where(ivm => matchingItemIds.Contains(ivm.ItemId))
            .Select(ivm => ivm.ItemValue)
            .GroupBy(iv => iv.CleanValue)
            .Select(g => g.Min(iv => iv.Value))
            .OrderBy(g => g);

        _logger.LogInformation(
            "GetQueryFiltersLegacy phase {Phase} SQL:{NewLine}{Query}",
            "Genres",
            Environment.NewLine,
            genresQuery.ToQueryString());
        _logger.LogInformation("GetQueryFiltersLegacy phase {Phase} started", "Genres");

        var genresStartTimestamp = Stopwatch.GetTimestamp();
        var genres = genresQuery.ToArray();

        _logger.LogInformation(
            "GetQueryFiltersLegacy phase {Phase} completed in {Elapsed:g} with {ResultCount} results",
            "Genres",
            Stopwatch.GetElapsedTime(genresStartTimestamp),
            genres.Length);

        return new QueryFiltersLegacy
        {
            Years = years,
            OfficialRatings = officialRatings,
            Tags = tags,
            Genres = genres
        };
    }
```

- [ ] **Step 3: Confirm the diagnostic diff contains no query rewrite**

```fish
git diff -- Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs
```

Expected: only two using directives, four expression-to-variable splits, and logging/timing statements. The `Where`, `Select`, `Distinct`, `GroupBy`, `Min`, and `OrderBy` expressions must remain textually equivalent to RC3.

### Task 3: Compile And Verify The Instrumented Server

**Files:**
- Verify: `Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs`

- [ ] **Step 1: Restore the pinned solution dependencies**

```fish
dotnet restore Jellyfin.sln
```

Expected: restore succeeds without package-source or compatibility errors.

- [ ] **Step 2: Build the modified server implementation project**

```fish
dotnet build Jellyfin.Server.Implementations/Jellyfin.Server.Implementations.csproj --configuration Release --no-restore
```

Expected: `Build succeeded` with zero errors.

- [ ] **Step 3: Run the focused item repository tests**

```fish
dotnet test tests/Jellyfin.Server.Implementations.Tests/Jellyfin.Server.Implementations.Tests.csproj --configuration Release --no-restore --filter 'FullyQualifiedName~Jellyfin.Server.Implementations.Tests.Item'
```

Expected: all selected tests pass.

- [ ] **Step 4: Verify formatting**

```fish
dotnet format --verify-no-changes --verbosity minimal
```

Expected: exit status `0` and no files changed.

- [ ] **Step 5: Verify whitespace and branch scope**

```fish
git diff --check
```

Expected: no output.

```fish
git status --short
```

Expected exactly one modified file:

```text
 M Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs
```

- [ ] **Step 6: Commit the disposable instrumentation**

```fish
git add Jellyfin.Server.Implementations/Item/BaseItemRepository.Querying.cs
git commit -m "instrument legacy filter query phases"
```

Expected: one commit containing only the instrumented query file.

### Task 4: Add The Pinned Temporary Image Workflow

**Files:**
- Create: `.github/workflows/temporary-rc3-image.yml`

- [ ] **Step 1: Create the branch-limited GHCR workflow**

Create `.github/workflows/temporary-rc3-image.yml` with this exact content:

```yaml
name: Temporary RC3 image

on:
  push:
    branches:
      - diagnosis/v12.0-rc3-legacy-filters
      - validation/v12.0-rc3-legacy-filters
  workflow_dispatch:

permissions:
  contents: read
  packages: write

concurrency:
  group: temporary-rc3-image-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    name: Build linux/amd64 image
    runs-on: ubuntu-24.04
    timeout-minutes: 60

    steps:
      - name: Determine immutable image tag
        id: image
        shell: bash
        run: |
          set -euo pipefail

          case "${GITHUB_REF_NAME}" in
            diagnosis/v12.0-rc3-legacy-filters)
              variant="diagnostic"
              ;;
            validation/v12.0-rc3-legacy-filters)
              variant="validation"
              ;;
            *)
              printf 'Unsupported branch: %s\n' "${GITHUB_REF_NAME}" >&2
              exit 1
              ;;
          esac

          tag="12.0-rc3-filter-${variant}-${GITHUB_SHA}"
          echo "tag=${tag}" >> "${GITHUB_OUTPUT}"
          echo "image=ghcr.io/felixfoertsch/jellyfin:${tag}" >> "${GITHUB_OUTPUT}"

      - name: Checkout pinned RC3 packaging
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: jellyfin/jellyfin-packaging
          ref: 846b546838941cefac00cfe5ac08d9adf6dff26c
          persist-credentials: false

      - name: Checkout branch server
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: ${{ github.repository }}
          ref: ${{ github.sha }}
          path: jellyfin-server
          fetch-depth: 0
          persist-credentials: false

      - name: Checkout matching RC3 web
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: jellyfin/jellyfin-web
          ref: 4983aec1e8cd85adaa2b8024a8c30bd31ca78d7f
          path: jellyfin-web
          persist-credentials: false

      - name: Verify RC3 server ancestry
        shell: bash
        run: |
          set -euo pipefail
          git -C jellyfin-server merge-base --is-ancestor \
            fc43f151a2418cc112e116050a99dd6318917ab0 \
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
          tags: ${{ steps.image.outputs.image }}
          labels: |
            org.opencontainers.image.source=https://github.com/${{ github.repository }}
            org.opencontainers.image.revision=${{ github.sha }}
            org.opencontainers.image.version=12.0-rc3
            org.opencontainers.image.title=Jellyfin RC3 legacy-filter test image
          build-args: |
            PACKAGE_ARCH=amd64
            DOTNET_ARCH=x64
            IMAGE_ARCH=amd64
            TARGET_ARCH=amd64
            JELLYFIN_VERSION=12.0-rc3
            CONFIG=Release
            DOTNET_VERSION=10.0
            NODEJS_VERSION=24
            OS_VERSION=trixie
            FFMPEG_PACKAGE=jellyfin-ffmpeg8

      - name: Publish image summary
        shell: bash
        run: |
          {
            echo '## Temporary Jellyfin image'
            echo
            echo '- Image: `${{ steps.image.outputs.image }}`'
            echo '- Digest: `${{ steps.build.outputs.digest }}`'
            echo '- Platform: `linux/amd64`'
            echo '- Server revision: `${{ github.sha }}`'
            echo '- RC3 web revision: `4983aec1e8cd85adaa2b8024a8c30bd31ca78d7f`'
            echo '- Packaging revision: `846b546838941cefac00cfe5ac08d9adf6dff26c`'
          } >> "${GITHUB_STEP_SUMMARY}"
```

- [ ] **Step 2: Confirm the workflow cannot publish from the eventual fix branch**

```fish
git diff -- .github/workflows/temporary-rc3-image.yml
```

Expected: push branches contain only `diagnosis/v12.0-rc3-legacy-filters` and `validation/v12.0-rc3-legacy-filters`; permissions contain only `contents: read` and `packages: write`.

- [ ] **Step 3: Verify whitespace**

```fish
git diff --check
```

Expected: no output.

- [ ] **Step 4: Commit the temporary build workflow**

```fish
git add .github/workflows/temporary-rc3-image.yml
git commit -m "build temporary rc3 diagnostic image"
```

Expected: one commit containing only the workflow.

### Task 5: Publish And Inspect The Diagnostic Image

**Files:**
- No additional repository file changes.

- [ ] **Step 1: Confirm branch ancestry and cleanliness**

```fish
git merge-base --is-ancestor fc43f151a2418cc112e116050a99dd6318917ab0 HEAD
```

Expected exit status: `0`.

```fish
git status --short --branch
```

Expected: clean `diagnosis/v12.0-rc3-legacy-filters` branch.

- [ ] **Step 2: Push the disposable branch to the fork**

```fish
git push --set-upstream origin diagnosis/v12.0-rc3-legacy-filters
```

Expected: the branch is created on `felixfoertsch/jellyfin`; no pull request is opened.

- [ ] **Step 3: Identify the triggered workflow run**

```fish
gh run list --workflow temporary-rc3-image.yml --branch diagnosis/v12.0-rc3-legacy-filters --limit 1 --json databaseId,headSha,status,conclusion
```

Expected: one run whose `headSha` equals local `git rev-parse HEAD`.

- [ ] **Step 4: Watch the exact run to completion**

Set the run ID from the previous response:

```fish
set run_id (gh run list --workflow temporary-rc3-image.yml --branch diagnosis/v12.0-rc3-legacy-filters --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch $run_id --exit-status
```

Expected: every checkout, ancestry, build, and push step succeeds.

- [ ] **Step 5: Define the immutable image name from the built commit**

```fish
set diagnostic_sha (git rev-parse HEAD)
set diagnostic_image ghcr.io/felixfoertsch/jellyfin:12.0-rc3-filter-diagnostic-$diagnostic_sha
string length $diagnostic_sha
```

Expected SHA length: `40`.

- [ ] **Step 6: Make the new GHCR package public once**

Open:

```text
https://github.com/users/felixfoertsch/packages/container/jellyfin/settings
```

Under **Danger Zone → Change visibility**, select **Public**, enter `jellyfin`, and confirm. This is intentional because the source fork and temporary diagnostic code are already public, and anonymous pulling avoids storing a GitHub personal access token on Unraid. GitHub does not allow changing a public package back to private.

- [ ] **Step 7: Verify Unraid can pull the immutable image anonymously**

```fish
ssh unraid "docker pull --platform linux/amd64 '$diagnostic_image'"
```

Expected: pull succeeds and reports the immutable tag without an authentication error.

- [ ] **Step 8: Inspect the image runtime contract on Unraid**

```fish
ssh unraid "docker image inspect '$diagnostic_image' --format 'Architecture={{.Architecture}} OS={{.Os}} Entrypoint={{json .Config.Entrypoint}} Healthcheck={{json .Config.Healthcheck}} Revision={{index .Config.Labels \"org.opencontainers.image.revision\"}}'"
```

Expected:

- architecture `amd64`;
- OS `linux`;
- entrypoint `/jellyfin/jellyfin`;
- health check for `http://localhost:8096/health`; and
- revision equal to `$diagnostic_sha`.

### Task 6: Capture Production Preflight And Rollback State

**Files:**
- Create remotely: `/mnt/cache/appdata/jellyfin/diagnostics/legacy-filter-$run_stamp/`
- Copy remotely: `my-Jellyfin.xml.preview`
- Create remotely: `preflight-container.txt`, `preflight-health.txt`, `database-quick-check.txt`

- [ ] **Step 1: Define one UTC evidence directory for the run**

```fish
set run_stamp (date -u +%Y%m%dT%H%M%SZ)
set evidence_dir /mnt/cache/appdata/jellyfin/diagnostics/legacy-filter-$run_stamp
set template /boot/config/plugins/dockerMan/templates-user/my-Jellyfin.xml
```

Expected: `$run_stamp` is a compact UTC timestamp and `$evidence_dir` is under the private Jellyfin diagnostics directory.

- [ ] **Step 2: Verify the evidence parent before creating the run directory**

```fish
ssh unraid "ls -ld /mnt/cache/appdata/jellyfin/diagnostics"
```

Expected: the diagnostics directory exists under `/mnt/cache/appdata/jellyfin/`.

- [ ] **Step 3: Create the run evidence directory**

```fish
ssh unraid "mkdir '$evidence_dir'"
```

Expected: no output.

- [ ] **Step 4: Back up the exact live Unraid template**

```fish
ssh unraid "cp '$template' '$evidence_dir/my-Jellyfin.xml.preview'"
```

Expected: no output.

- [ ] **Step 5: Capture the official RC3 container identity**

```fish
ssh unraid "docker inspect jellyfin --format 'Image={{.Config.Image}} ImageID={{.Image}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} RestartCount={{.RestartCount}} ConfigSource={{range .Mounts}}{{if eq .Destination \"/config\"}}{{.Source}}{{end}}{{end}}' | tee '$evidence_dir/preflight-container.txt'"
```

Expected:

- image `jellyfin/jellyfin:preview`;
- image ID `sha256:2bcce80cd1f080c000b94536eb90118709f08974e3ff71b109bb6b74c24027d8`;
- status `running`;
- health `healthy`;
- restart count `0`; and
- config source `/mnt/cache/appdata/jellyfin`.

- [ ] **Step 6: Capture three bounded health samples**

Run this command three times:

```fish
ssh unraid "docker exec jellyfin sh -c 'curl --max-time 15 --silent --show-error --output /dev/null --write-out \"health %{http_code} %{time_total}\\n\" http://127.0.0.1:8096/health' | tee -a '$evidence_dir/preflight-health.txt'"
```

Expected each time: HTTP `200` in less than 15 seconds.

- [ ] **Step 7: Verify the production database before deployment**

```fish
ssh unraid "sqlite3 /mnt/cache/appdata/jellyfin/data/jellyfin.db 'PRAGMA quick_check;' | tee '$evidence_dir/database-quick-check.txt'"
```

Expected exactly: `ok`.

- [ ] **Step 8: Stop if any preflight gate failed**

Do not change the template when the image identity, mount, health, or database check differs from the expected state. Report the discrepancy and keep official RC3 running.

### Task 7: Deploy The Diagnostic Image Through Unraid

**Files:**
- Modify remotely: `/boot/config/plugins/dockerMan/templates-user/my-Jellyfin.xml`
- Preserve remotely: `$evidence_dir/my-Jellyfin.xml.preview`

- [ ] **Step 1: Replace only the template repository value**

```fish
ssh unraid "sed -i 's#<Repository>jellyfin/jellyfin:preview</Repository>#<Repository>$diagnostic_image</Repository>#' '$template'"
```

Expected: no output.

- [ ] **Step 2: Verify the template contains the immutable diagnostic image exactly once**

```fish
ssh unraid "grep -c '<Repository>$diagnostic_image</Repository>' '$template'"
```

Expected exactly: `1`.

- [ ] **Step 3: Apply the template through Unraid Docker Manager**

```fish
ssh unraid "/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container jellyfin"
```

Expected: Unraid recreates `jellyfin` using the template without changing its mounts or devices.

- [ ] **Step 4: Verify the deployed image and runtime state**

```fish
ssh unraid "docker inspect jellyfin --format 'Image={{.Config.Image}} ImageID={{.Image}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} RestartCount={{.RestartCount}} ConfigSource={{range .Mounts}}{{if eq .Destination \"/config\"}}{{.Source}}{{end}}{{end}}'"
```

Expected:

- image equals `$diagnostic_image`;
- status `running`;
- health reaches `healthy`;
- restart count `0`; and
- config source remains `/mnt/cache/appdata/jellyfin`.

- [ ] **Step 5: Verify device mappings remain present**

```fish
ssh unraid "docker inspect jellyfin --format '{{range .HostConfig.Devices}}{{.PathOnHost}} -> {{.PathInContainer}}{{println}}{{end}}'"
```

Expected: `/dev/dri` and `/dev/dri/renderD128` mappings remain present.

- [ ] **Step 6: Verify local and public endpoints before diagnosis**

```fish
ssh unraid "docker exec jellyfin sh -c 'curl --max-time 15 --fail --silent --show-error --output /dev/null --write-out \"local %{http_code} %{time_total}\\n\" http://127.0.0.1:8096/health'"
```

Expected: local HTTP `200`.

```fish
curl --max-time 15 --fail --silent --show-error --output /dev/null --write-out 'public %{http_code} %{time_total}\n' https://netfelix.jetzt/System/Info/Public
```

Expected: public HTTP `200`.

- [ ] **Step 7: Roll back immediately if any deployment gate failed**

If Tasks 7.3 through 7.6 fail, skip the diagnostic request and execute Task 9 immediately.

### Task 8: Run One Request And Capture Private Evidence

**Files:**
- Create remotely: `$evidence_dir/filters-response.json`
- Create remotely: `$evidence_dir/request-metrics.txt`
- Create remotely: `$evidence_dir/jellyfin-log-delta.log`
- Create remotely: `$evidence_dir/filter-counts.json`

- [ ] **Step 1: Locate the active Jellyfin log and record its current byte offset**

```fish
set log_file (ssh unraid "ls -1t /mnt/cache/appdata/jellyfin/log/log_*.log | head -n 1")
set log_offset (ssh unraid "stat -c %s '$log_file'")
set log_start (math $log_offset + 1)
```

Expected: `$log_file` is the current `log_YYYYMMDD.log`; `$log_offset` and `$log_start` are positive integers.

- [ ] **Step 2: Verify a Jellyfin API key exists without printing it**

```fish
ssh unraid "test -n \"\$(sqlite3 /mnt/cache/appdata/jellyfin/data/jellyfin.db 'select AccessToken from ApiKeys limit 1;')\""
```

Expected exit status: `0` and no output.

- [ ] **Step 3: Run the known authenticated legacy-filter request once**

Recover the exact known request path from the private Jellyfin logs, then extract its `userId` and `parentId` locally. Do not write either identifier into the repository or public Action logs.

```fish
set filter_request (ssh unraid "grep -hEo '/Items/Filters\\?userId=[0-9a-f]{32}&parentId=[0-9a-f]{32}&includeItemTypes=Episode' /mnt/cache/appdata/jellyfin/log/log_*.log | tail -n 1")
set FILTER_USER_ID (string replace -r '^.*userId=([0-9a-f]{32})&parentId=.*$' '$1' $filter_request)
set FILTER_PARENT_ID (string replace -r '^.*parentId=([0-9a-f]{32})&includeItemTypes=.*$' '$1' $filter_request)
```

Expected: `$filter_request` is the previously reproduced endpoint path. Validate that each extracted value is a lowercase UUID without separators:

```fish
string match --regex --quiet '^[0-9a-f]{32}$' $FILTER_USER_ID
string match --regex --quiet '^[0-9a-f]{32}$' $FILTER_PARENT_ID
```

Expected exit status for both checks: `0`.

```fish
ssh unraid "curl --max-time 180 --fail-with-body --silent --show-error --header \"Authorization: MediaBrowser Token=\$(sqlite3 /mnt/cache/appdata/jellyfin/data/jellyfin.db 'select AccessToken from ApiKeys limit 1;')\" --output '$evidence_dir/filters-response.json' --write-out 'http_code=%{http_code}\\ntime_total=%{time_total}\\n' 'http://127.0.0.1:8096/Items/Filters?userId=$FILTER_USER_ID&parentId=$FILTER_PARENT_ID&includeItemTypes=Episode' > '$evidence_dir/request-metrics.txt'"
```

Expected: HTTP `200`; the request may take about 121 seconds. A timeout, non-200 status, restart, or transport failure is diagnostic evidence but requires immediate rollback.

- [ ] **Step 4: Capture the complete multiline log delta**

```fish
ssh unraid "tail -c +$log_start '$log_file' > '$evidence_dir/jellyfin-log-delta.log'"
```

Expected: the private log delta contains SQL, start, and completion records for the request.

- [ ] **Step 5: Record response counts without exposing filter values**

```fish
ssh unraid "jq '{Years: (.Years | length), OfficialRatings: (.OfficialRatings | length), Tags: (.Tags | length), Genres: (.Genres | length)}' '$evidence_dir/filters-response.json' > '$evidence_dir/filter-counts.json'"
```

Expected: valid JSON with four numeric counts.

- [ ] **Step 6: Confirm all four phase names appear in the private log**

```fish
ssh unraid "grep 'GetQueryFiltersLegacy phase' '$evidence_dir/jellyfin-log-delta.log'"
```

Expected: SQL and start records for `Years`, `OfficialRatings`, `Tags`, and `Genres`, plus a completion record for each phase that returned before the request deadline.

### Task 9: Restore Official RC3 Immediately

**Files:**
- Restore remotely: `/boot/config/plugins/dockerMan/templates-user/my-Jellyfin.xml`

- [ ] **Step 1: Restore the exact pre-diagnosis template**

```fish
ssh unraid "cp '$evidence_dir/my-Jellyfin.xml.preview' '$template'"
```

Expected: no output.

- [ ] **Step 2: Verify the restored repository value**

```fish
ssh unraid "grep -c '<Repository>jellyfin/jellyfin:preview</Repository>' '$template'"
```

Expected exactly: `1`.

- [ ] **Step 3: Apply the restored template through Unraid Docker Manager**

```fish
ssh unraid "/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container jellyfin"
```

Expected: Unraid recreates `jellyfin` from official preview.

- [ ] **Step 4: Verify the known official RC3 image and container state**

```fish
ssh unraid "docker inspect jellyfin --format 'Image={{.Config.Image}} ImageID={{.Image}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} RestartCount={{.RestartCount}} ConfigSource={{range .Mounts}}{{if eq .Destination \"/config\"}}{{.Source}}{{end}}{{end}}'"
```

Expected:

- image `jellyfin/jellyfin:preview`;
- image ID `sha256:2bcce80cd1f080c000b94536eb90118709f08974e3ff71b109bb6b74c24027d8`;
- status `running`;
- health `healthy`;
- restart count `0`; and
- config source `/mnt/cache/appdata/jellyfin`.

- [ ] **Step 5: Verify local and public recovery**

```fish
ssh unraid "docker exec jellyfin sh -c 'curl --max-time 15 --fail --silent --show-error --output /dev/null --write-out \"local %{http_code} %{time_total}\\n\" http://127.0.0.1:8096/health'"
```

Expected: local HTTP `200`.

```fish
curl --max-time 15 --fail --silent --show-error --output /dev/null --write-out 'public %{http_code} %{time_total}\n' https://netfelix.jetzt/System/Info/Public
```

Expected: public HTTP `200`.

- [ ] **Step 6: Recheck database integrity after restoration**

```fish
ssh unraid "sqlite3 /mnt/cache/appdata/jellyfin/data/jellyfin.db 'PRAGMA quick_check;'"
```

Expected exactly: `ok`.

### Task 10: Evaluate Guided Gate 1

**Files:**
- Read privately: `$evidence_dir/request-metrics.txt`
- Read privately: `$evidence_dir/filter-counts.json`
- Read privately: `$evidence_dir/jellyfin-log-delta.log`
- Do not add evidence to Git.

- [ ] **Step 1: Read request timing and result counts**

```fish
ssh unraid "cat '$evidence_dir/request-metrics.txt'"
ssh unraid "cat '$evidence_dir/filter-counts.json'"
```

Expected: HTTP `200`, one total duration, and four result counts.

- [ ] **Step 2: Extract phase completion timings**

```fish
ssh unraid "grep 'GetQueryFiltersLegacy phase .* completed in' '$evidence_dir/jellyfin-log-delta.log'"
```

Expected: one completion line per phase. Their elapsed durations should account for the endpoint's total duration apart from normal request overhead.

- [ ] **Step 3: Review only the generated SQL for the dominant phase**

Use the phase markers in `$evidence_dir/jellyfin-log-delta.log` to read the SQL block immediately preceding the dominant phase's start marker. Keep the SQL private because EF Core can render request parameters.

Expected: the query structure provides a concrete explanation for SQLite's pathological execution. If it does not, do not infer a fix; design a second disposable observability iteration limited to that phase.

- [ ] **Step 4: Apply the Guided Gate 1 decision**

Gate passes only when:

- one named phase accounts for essentially the entire stall;
- the exact generated query or its SQLite plan explains the cost;
- the diagnostic instrumentation did not change filter semantics; and
- official RC3 is restored and healthy.

If the gate passes, report the phase, causal query structure, private evidence path, and restoration checks to the user. Then write a separate TDD implementation plan for `fix/legacy-filter-query` against current `upstream/master`.

If the gate fails, report exactly which evidence is missing and remain on the disposable diagnostic branch. Do not create the fix branch and do not alter any production query.

## Completion Boundary

This plan does not implement or propose the Jellyfin fix. Completion means that Guided Gate 1 has either identified one causal query mechanism with reviewable evidence or has explicitly established the next narrow diagnostic question. The final upstream test, correction, benchmark comparison, AI disclosure, and pull request belong to the subsequent fix plan.
