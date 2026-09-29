# Working on cooked

## Purpose and naming

`am-i-cooked` is the repository/Swift package; `cooked` is the command and product name. `Cooked` is the executable target, and `CookedCore` contains reusable logic. Keep these names consistent rather than inventing additional branding.

This is a macOS terminal application with two tabs: Usage (Codex, Claude Code, Cursor) and Models (public catalogs, comparison, PNG export). Support macOS 13+, Swift 6, and system frameworks only unless a concrete need justifies a dependency.

## Structure

- `Sources/Cooked/Cooked.swift`: terminal lifecycle, input/event loop, orchestration. Keep UI state on the main actor; cancel background work at exit.
- `Sources/CookedCore/*Provider.swift`: each service's discovery, read-only credentials, quota decoding and status. Missing providers return `nil`; transient errors must not silently become zero usage.
- `HTTPClient.swift`, `Command.swift`, `ProviderSupport.swift`: small I/O boundaries and provider helpers. Inject transports/commands in tests.
- `UsageModels.swift`, `Cost.swift`: snapshots, usage parsing, public-price estimates. Keep money, credits, billing periods and team/personal scopes distinct.
- `ModelCatalog.swift`, `CompanyConfiguration.swift`: public metadata, source matching and typed company configuration.
- `TimelineState.swift`, `ModelCompare.swift`, `ReleaseCadence.swift`: navigation/comparison and date calculations.
- `Rendering.swift`, `TimelineRenderer.swift`: terminal output from explicit state; no network or credential access.
- `CardCanvas.swift`, `ShareCard.swift`, `ModelShareCard.swift`, `LabMarks.swift`: native exports and public marks.
- `Distribution.swift`, `install`, `release`: GitHub Releases distribution, atomic installation and updates. `.github/workflows/release.yml` publishes tagged versions with checksums.

## Design rules

Prefer the smallest change that solves the actual problem. Avoid frameworks, dependency containers, protocol layers and configuration files without a concrete use. Preserve the boundary between I/O, domain calculations and rendering. Keep public Swift names in camelCase and service field spelling at decoding boundaries.

Providers can refresh concurrently; do not overlap refreshes for the same provider. Keep caches in memory. Never sum workspace credits or team/billing-cycle allowances into personal calendar-period dollars. Unknown prices must remain unknown. Parse usage metadata only; retain duplicate/replay protection and overflow checks.

Terminal rendering must fit row/column budgets, clean untrusted control characters, and handle wide characters and `NO_COLOR`. Exports render complete data independently of terminal scroll state. Preserve keyboard semantics documented in the README.

## Privacy and provenance

Never commit or print real credentials, session logs, private endpoints, personal absolute paths, account payloads, or employer material. Use generic fixture names, `example.com`/`.invalid`, and clearly fake tokens. Do not run providers against a real account just to create documentation or tests.

Credentials are read-only and sent only to the matching service. Do not add login/token refresh, credential writes, analytics or usage-data uploads. GitHub release downloads may use existing `gh` authentication; never extract or log its token. Do not embed local usernames or organization names in default exports. Public model marks/data retain their owners' rights; do not copy unlicensed assets or code.

Screenshots must come from deterministic synthetic fixtures passed through the actual renderers. Do not use desktop captures containing personal accounts. Keep `.build/`, `.swiftpm/`, `dist/`, credentials and logs out of Git. Check staged files and history before any first publication. Keep the GitHub repository private until its owner explicitly requests public visibility.

## Checks and documentation

Run relevant tests after behavior changes; before a repository-wide release check, run:

```sh
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

Tests must be hermetic by default: inject HTTP responses, use temporary directories and fake credentials, and clean up fixtures. The optional downloaded-schema test is skipped unless `COOKED_CATALOG_FIXTURES` is set. Add regression tests for material correctness/privacy bugs; avoid tests that merely mirror implementation.

Regenerate documentation images when UI changes affect them:

```sh
TZ=UTC COOKED_DOC_SCREENSHOTS=docs/images swift test --filter DocumentationScreenshotTests
```

Keep README.md and README.zh-CN.md aligned with behavior. Document limitations accurately; do not promise real-service compatibility based only on fixture tests. Versioned binaries belong in this repository's GitHub Releases, not Git history. The owner has enabled automatic updates from that source. Keep manifest/tag/binary versions consistent and preserve SHA-256 checks, newer-version checks, safe replacement and provider credential isolation. Do not publish a new version or change repository visibility unless that action is part of the user's task.
