# Legacy Filter Query Fix Design

## Goal

Identify the exact query inside `GetQueryFiltersLegacy` that causes the reproducible two-minute `/Items/Filters` stall, correct only the proven defect, and prepare an explainable upstream Jellyfin contribution with deterministic regression coverage.

The custom Jellyfin image is a temporary diagnostic and validation artifact. This work does not create or maintain a Jellyfin fork as a separate product.

## Known Evidence

- Jellyfin `v12.0-rc3` takes about 121 seconds for the affected request.
- A tested unstable build takes about 120 to 123 seconds for the same request.
- The managed stack reaches `BaseItemRepository.GetQueryFiltersLegacy` and waits in the EF Core SQLite execution path.
- Approximate direct SQLite queries complete in less than half a second, so they do not reproduce the generated EF query behavior.
- `GetQueryFiltersLegacy` executes four materializations for years, official ratings, tags, and genres.
- Current upstream `master` still contains this four-query implementation and has no focused test for the method.
- Unrelated services and plugins have been excluded as the initiating cause.

## Scope

The final upstream contribution contains only:

- the smallest production-code change that corrects the diagnosed query behavior;
- a focused regression test that protects the causal mechanism and result semantics; and
- any test-fixture data strictly required by that test.

Temporary diagnostic branches may contain timing and generated-SQL instrumentation. Diagnostic code, image workflows, private identifiers, and production evidence must not appear in the upstream pull request.

## Non-Goals

- Refactoring all legacy filter queries for consistency.
- Replacing EF Core, SQLite, or the legacy filter endpoint.
- Maintaining custom Jellyfin releases after the fix is accepted or superseded.
- Changing plugins, metadata, libraries, authentication, or unrelated database code.
- Adding a CI wall-clock threshold that varies with runner performance.

## Repository And Branch Model

The fork at `github.com/felixfoertsch/jellyfin` uses these isolated branches:

- `diagnosis/v12.0-rc3-legacy-filters` starts at the exact `v12.0-rc3` tag and contains disposable instrumentation plus its temporary image workflow.
- `fix/legacy-filter-query` starts at current upstream `master` and contains only the final fix and regression test.
- `validation/v12.0-rc3-legacy-filters` starts at `v12.0-rc3`, receives the final production-code change, and contains the temporary clean-image workflow.

An `upstream` remote points to `github.com/jellyfin/jellyfin`. The fix branch is rebased onto current upstream `master` before final verification. Diagnostic and validation branches never merge into the fix branch.

## Diagnostic Instrumentation

Instrumentation surrounds each of the four query materializations without changing their behavior:

1. Render the query with EF Core `ToQueryString()` before execution.
2. Log a distinct phase name and start marker.
3. Execute the original materialization unchanged.
4. Log elapsed monotonic time and result count on completion.
5. Allow exceptions to propagate through Jellyfin's existing error handling.

The phases are `Years`, `OfficialRatings`, `Tags`, and `Genres`. One authenticated request against the known affected library provides the comparison. The diagnosis selects a phase only when it accounts for essentially the entire observed stall and its generated SQL or query plan explains the pathological behavior.

If timings do not isolate one phase, the next diagnostic iteration changes only the observability around those phases. It does not introduce a speculative production fix.

## Temporary Image Pipeline

GitHub Actions builds temporary `linux/amd64` images from the diagnostic and validation branches. The workflow adapts Jellyfin's official packaging Dockerfile and preserves the official runtime layout, entrypoint, FFmpeg integration, and matching RC3 web assets.

Images use immutable commit-addressed tags derived from `GITHUB_SHA`:

- `ghcr.io/felixfoertsch/jellyfin:12.0-rc3-filter-diagnostic-${GITHUB_SHA}`
- `ghcr.io/felixfoertsch/jellyfin:12.0-rc3-filter-validation-${GITHUB_SHA}`

The workflow publishes with the repository-provided `GITHUB_TOKEN`. It introduces no long-lived registry secret and does not run on the final fix branch.

## Unraid Deployment Safety

Every temporary image deploy goes through `/boot/config/plugins/dockerMan/templates-user/my-Jellyfin.xml` and the Unraid Docker Manager update mechanism. The deployment uses an immutable image tag or digest and preserves all existing mounts, devices, plugins, ports, and environment variables.

Before invoking the affected endpoint:

- confirm the container is healthy with zero unexpected restarts;
- confirm local and public health endpoints respond successfully; and
- confirm the expected diagnostic or validation image digest is running.

Only the known authenticated `/Items/Filters` request is issued. Generated SQL, user IDs, library IDs, and detailed logs remain private.

After each experiment, restore `jellyfin/jellyfin:preview` through the same template workflow and verify the known RC3 image digest, container health, and endpoints. Keep the existing database and template rollback snapshot intact. If a temporary image fails startup, health, or migration checks, restore RC3 before issuing the filter request.

## Fix Selection

The diagnosis determines the correction; the design does not preselect a speculative rewrite. The accepted correction must satisfy all of these constraints:

- It changes only the query proven to cause the stall.
- It preserves filter values, distinctness, ordering, and existing filtering semantics.
- It relies on supported EF Core and SQLite behavior.
- A maintainer can explain the causal relationship without understanding unrelated repository internals.
- It adds no compatibility layer, dependency, or unrelated abstraction.

Neighboring queries remain unchanged unless the evidence proves that the same expression must change to preserve correctness.

## Regression Testing

The regression test uses Jellyfin's existing xUnit and SQLite repository-test conventions. It constructs the smallest data shape that exercises the diagnosed relationship and query translation.

The test first fails on unmodified upstream `master` for the diagnosed structural reason. Depending on the proven mechanism, the deterministic assertion targets generated SQL shape, query count, SQLite execution plan, or cancellation behavior. Wall-clock timing is supporting evidence, not the CI pass condition.

The test also asserts unchanged public behavior:

- expected years and official ratings;
- expected tags and genres;
- no duplicate values; and
- existing sort order.

Verification includes the focused test, the relevant repository test project, formatting checks, and Jellyfin's required build checks.

## Production Validation

After the fix passes on current upstream `master`, apply the identical production-code change to the RC3 validation branch and build a clean image without diagnostic logging.

Run the same authenticated endpoint against the unchanged production library. Record endpoint duration and returned filter counts, compare them with the established RC3 baseline, and verify that results remain equivalent. Restore official RC3 immediately afterward.

Real-library timings support the performance claim. Deterministic repository tests protect the fix from regression.

## Contribution Shape

The final branch contains one coherent commit with the regression test and production fix. The commit and pull request explain:

1. the precise generated-query defect;
2. why it creates pathological SQLite execution;
3. how the minimal expression change removes that behavior;
4. why returned values remain equivalent; and
5. the observed before-and-after timing.

The pull request discloses AI assistance according to Jellyfin's policy. The contributor reviews every changed line and can independently explain the diagnosis, correction, and test. Temporary workflows, diagnostic logs, production identifiers, and this planning document are excluded from the upstream pull request.

## Success Criteria

- One filter phase and its causal query behavior are proven with direct evidence.
- The regression test fails before the fix and passes afterward for a deterministic reason.
- The final production change is limited to the affected query.
- Relevant tests, formatting, and builds pass on current upstream `master`.
- The clean RC3 validation image returns equivalent filter data without the two-minute stall.
- Official RC3 is restored and healthy after validation.
- The contributor can explain every line submitted upstream.

## Guided Gates

- **GG-1:** Review the diagnostic log and confirm that one named phase accounts for the stall before authorizing a fix.
- **GG-2:** Review the proposed production diff and its causal explanation before building the validation image.
- **GG-3:** Confirm equivalent filter results and acceptable endpoint timing on the real library.
- **GG-4:** Review the final commit and pull request text, including the AI-assistance disclosure, before publication.
