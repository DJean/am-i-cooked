# cooked

A small macOS terminal dashboard for AI coding usage and model discovery.

Track **Codex, Claude Code, and Cursor** allowances, estimate local token costs, explore model releases, compare prices and benchmarks, and export PNG cards. Built with Swift and system frameworks; no third-party package dependencies.

[中文说明](README.zh-CN.md) · [MIT license](LICENSE) · [Contributor guide](AGENTS.md)

## Preview

Every image below uses **synthetic data**: invented usage, model names, dates, prices, and benchmark scores. Terminal screenshots are rasterized from the application's real renderer; cards come from its real PNG exporters. They are demonstrations, not current pricing or benchmark claims.

### Usage

Automatically shows available providers. Missing installations stay hidden; detected providers can show sign-in or network errors.

![Usage dashboard with synthetic Codex, Claude, and Cursor data](docs/images/usage.png)

<details>
<summary>Expanded model cost details</summary>

![Synthetic usage details](docs/images/usage-details.png)

</details>

### Models

Browse release batches and model details; open a company to see its model list and historical release intervals.

![Model release timeline and details with synthetic data](docs/images/models.png)

![Company model list and release history with synthetic data](docs/images/company.png)

### Compare

Search and select models, then compare context limits, prices, and compatible benchmark results against a chosen reference.

![Model selection with synthetic data](docs/images/search.png)

![Model comparison with synthetic data](docs/images/compare.png)

### Export

Save usage, model, company, and comparison cards to Downloads. Exported data is not limited by terminal width or the current scroll position. Usage cards include local monthly estimates, so Cursor billing-cycle/team amounts are excluded.

<p>
  <img src="docs/images/usage-card.png" alt="Synthetic usage share card" width="280">
  <img src="docs/images/model-card.png" alt="Synthetic model share card" width="280">
  <img src="docs/images/company-card.png" alt="Synthetic company share card" width="280">
  <img src="docs/images/compare-card.png" alt="Synthetic comparison share card" width="560">
</p>

## Install and run

Requires **macOS 13 or later**, on Apple Silicon or Intel. Release binaries are universal; no Swift or Xcode installation is needed.

While the repository is **private**, first install and sign in to [GitHub CLI](https://cli.github.com/) with an account that can access it (`gh auth login`), then:

```sh
gh release download --repo DJean/am-i-cooked --pattern install --output - | sh
```

Once the owner makes the repository public, anyone can install without GitHub CLI or authentication:

```sh
curl -fsSL https://github.com/DJean/am-i-cooked/releases/latest/download/install | sh
```

The installer fetches the latest stable release, validates its SHA-256 checksum and version, and installs atomically to `~/.local/bin/cooked`. `COOKED_INSTALL_DIR` can override the destination for a separate installation; automatic updates are limited to the standard path. Add `~/.local/bin` to your shell's `PATH`, or run `~/.local/bin/cooked` directly. Sign in to Codex, Claude Code, or Cursor using their original tools; cooked does not perform those logins.

```sh
cooked                             # open the dashboard
cooked > usage.txt                 # one plain-text Usage snapshot
NO_COLOR=1 cooked                  # disable terminal colors
cooked --version
cooked --help
```

To build from source instead, install a Swift 6 toolchain (Xcode 16 or later), clone this repository, and run `./install --source` or `swift run -c release cooked`.

The interface uses up to 104 columns. Models needs at least 80×21; Usage height depends on the visible providers and expanded details. Resize when the app shows a size hint. Usage refreshes about every minute; public model data refreshes about every 30 minutes, with earlier retries after failures.

## Controls

| View | Key | Action |
| --- | --- | --- |
| Global | Ctrl+C | Quit |
| Usage / Models | Tab, a, d | Switch tabs |
| Usage / Models | q | Quit (outside search) |
| Usage | Space | Expand/collapse model cost details |
| Usage | s | Save usage card |
| Models | ↑↓ or j/k | Select release/model |
| Models | → / ← or Esc | Enter company / return to timeline |
| Models | Space | Page details, wrapping at the end |
| Models | c | Open comparison search with current model selected |
| Models | s / S | Save model / company card |
| Search | Type, ↑↓ | Filter and select results |
| Search | Enter | Toggle selection; clear query |
| Search | Backspace | Delete query character, or remove last selection if empty |
| Search | Ctrl+U / Esc | Clear query / cancel search |
| Search | Tab | Compare at least two selected models |
| Compare | ↑↓ / ←→ | Select metric / scroll model columns |
| Compare | b | Change reference model |
| Compare | c or Esc | Edit model selection |
| Compare | s | Save full comparison card |

Letter shortcuts also accept uppercase, except the distinct `s`/`S` exports. In search, letters are input, including `q` and `s`.

## Data and privacy

cooked has no analytics, account service, or hosted backend. Credentials are read locally and sent only to the corresponding provider API. It never logs in, refreshes tokens, or rewrites credentials. Provider requests reject cross-origin HTTP redirects. Release downloads use a separate HTTPS client for GitHub release assets; GitHub CLI handles authenticated downloads while the repository is private. Fetched usage data and parsing caches stay in memory.

| Provider | Read locally | Queried remotely | What is shown |
| --- | --- | --- | --- |
| Codex | `$CODEX_HOME/auth.json` and `sessions/**/*.jsonl` (default `~/.codex`) | `chatgpt.com/backend-api/wham/usage` | Quota windows, workspace credits, local cost estimate |
| Claude | Keychain item `Claude Code-credentials`, `~/.claude.json`, `~/.claude/projects/**/*.jsonl` | `api.anthropic.com/api/oauth/usage` | Quota windows, seat tier, local cost estimate |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, opened read-only | `cursor.com/api/usage-summary` | Server-reported allowance, used amount, billing-cycle reset |

Claude is hidden when both `~/.claude` and `~/.claude.json` are absent. Cursor is hidden without its database. Codex needs usable credentials or recent local usage. macOS may ask for Keychain access when Claude credentials are first read. Detected Claude/Cursor installations with missing or rejected credentials display sign-in instructions. Temporary failures retain the last successful result for this process; 429 responses respect `Retry-After`.

Session files are read locally, but only usage-related fields are decoded; conversations are not sent anywhere. Estimates cover retained logs on **this Mac**, not all devices. Claude request/message IDs avoid counting duplicate records twice. Today, week (starting Monday), and calendar month follow the local timezone. Missing prices retain token counts and produce an incomplete-estimate note. API-equivalent estimates are **not subscription bills**. Codex workspace credits are not dollars; Cursor billing cycles and team pools are not personal calendar-month spend and are excluded from local cost totals.

For Cursor, cooked selects a valid individual overall allowance, then a team pool, then team on-demand usage, with an individual-plan fallback. This is a summary of the returned bucket, not a reconstruction of every pool on Cursor's billing dashboard. Provider endpoints and local credential formats are undocumented and may change. Unknown responses are reported rather than treated as zero usage. Real account compatibility is not covered by the fixture tests.

Public sources require no credentials:

- [models.dev](https://models.dev): model metadata (`models.json`), prices (`api.json`), and company marks. Author prices are matched by model ID; deployment matches must be unambiguous. Benchmark comparisons require matching measurement conditions. Release intervals are historical, not predictions.
- [LiteLLM price catalog](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json): local token-cost estimates, including supported cache and long-context tiers.

No session files, fetched catalogs, or credentials are written to the project. Explicit exports write PNGs to Downloads, creating the directory if needed; names get a numeric suffix if a file already exists. Usage cards default to the neutral name `cooked user`, not your macOS login. Review cards before sharing: their figures reflect your usage. Every card footer displays `github.com/DJean/am-i-cooked`.


## Automatic updates

Interactive sessions check this repository's latest stable GitHub Release at launch and about once an hour. An installation at `~/.local/bin/cooked` updates only to a newer semantic version. The updater validates the release tag, manifest, asset origin, SHA-256 digest, and candidate version before an atomic replacement. A running session continues on its current version; reopen cooked to use the update. Failed downloads leave the installed binary intact.

Private releases need an accessible `gh` command and an existing GitHub login with repository access. No GitHub token is copied into cooked configuration or sent to a separate update server. Without access, updates are skipped; normal usage still works. Executables run from a checkout (including `swift run`), other installation paths, and symlink installations are not automatically replaced. `./install --source` installs to the standard path and does receive updates. Non-interactive snapshots do not check for updates.

## Development

```sh
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
TZ=UTC COOKED_DOC_SCREENSHOTS=docs/images swift test --filter DocumentationScreenshotTests
```

Default tests use temporary directories, fake credentials, injected HTTP replies, and synthetic model data. They do not need signed-in accounts. An optional public-schema test accepts `COOKED_CATALOG_FIXTURES=/path/to/fixtures` containing `models-dev-models.json` and `models-dev-api.json`; it is skipped otherwise.

- `Sources/Cooked`: terminal input, app state coordination, refresh scheduling, and export actions.
- `Sources/CookedCore`: providers, usage/cost models, catalog matching, navigation state, pure terminal rendering, and native PNG rendering.
- `Tests/CookedCoreTests`: parsing, calculations, failures, navigation, terminal bounds, exports, and distribution checks.

The two-target structure is intentional. Prefer small concrete types and injected I/O over a plugin framework or additional abstraction layers. [AGENTS.md](AGENTS.md) documents the working conventions.

To publish a version, update `Build.version` in `Sources/CookedCore/UsageModels.swift`, regenerate affected screenshots, commit the changes, and push the matching tag:

```sh
git push origin main
git tag vX.Y.Z
git push origin vX.Y.Z
```

The release workflow runs tests, builds an Apple Silicon + Intel binary, strips debug symbols, ad-hoc signs it, and packages `cooked`, `install`, `manifest.json`, and `SHA256SUMS`. It uploads all assets to a draft GitHub Release before publishing. Each version stays in this repository's [Releases](https://github.com/DJean/am-i-cooked/releases); binaries are not committed into Git history. The repository remains private until its owner changes visibility.

`./release X.Y.Z` runs the same packaging locally into ignored `dist/X.Y.Z/`, requiring a clean tree and a version matching `Build.version`. It does not upload by itself. Release binaries are ad-hoc signed, not notarized by Apple.

## License

[MIT](LICENSE). Runtime provider data, names, and marks remain subject to their respective owners' terms; the code license does not relicense those materials.
