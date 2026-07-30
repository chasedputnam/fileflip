# File-Flip

**Doc of record. Last verified: 2026-07-28.**

File-Flip is a native macOS menu-bar application that converts a file when you change only its filename extension in Finder. Rename `photo.jpg` to `photo.png`; File-Flip detects the file's actual contents, converts it locally, validates the result, and publishes it only after every safety check passes. By default, the original `photo.jpg` is restored beside the converted `photo.png`; an optional replace mode keeps the original in private backup storage instead.

The application never uploads file contents or metadata. It monitors only folders selected by the user.

> **Distribution status:** the source tree builds and runs locally, but it does not include a signed and notarized public release. The repository's release gate intentionally remains closed until the required Apple Silicon macOS matrix, LibreOffice compatibility matrix, Finder smoke tests, Developer ID signing, and notarization evidence are available.

## Requirements

- macOS 14 or later.
- Apple Silicon Mac.
- Xcode with the macOS SDK and command-line tools. The current project is verified with Xcode 26.6 and Apple Swift 6.3.3.
- At least 500 MB of free space for build products, plus space for conversion snapshots and any retained backups.
- Optional: a Developer ID-signed [LibreOffice](https://www.libreoffice.org/download/download-libreoffice/) installation in `/Applications` or `~/Applications` for office document and spreadsheet conversions. File-Flip accepts verified LibreOffice major versions 7 through 25 and disables office routes if verification or its startup self-test fails.

FFmpeg and ffprobe are already bundled as arm64-only, locally verified executables. A normal build does not need Homebrew or a separate FFmpeg installation.

## Install a local build

Run this from the repository root to create a locally runnable development build:

```sh
xcodebuild clean build \
  -project FileFlip.xcodeproj \
  -scheme FileFlip \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  ENABLE_HARDENED_RUNTIME=NO
```

This creates the application at:

```text
.build/xcode/Build/Products/Debug/FileFlip.app
```

Open it in place:

```sh
open .build/xcode/Build/Products/Debug/FileFlip.app
```

Or copy `FileFlip.app` to `/Applications` using Finder, then open it there. `ENABLE_HARDENED_RUNTIME=NO` is required for this local ad-hoc build so macOS library validation does not reject the embedded ad-hoc-signed frameworks. Use this setting only for local testing; distributable builds must enable Hardened Runtime and use consistent Developer ID signing and notarization.

### Run from Xcode

1. Open `FileFlip.xcodeproj`.
2. Select the **FileFlip** scheme and **My Mac** destination.
3. Press **Run**.

FileFlip is an agent application (`LSUIElement=true`), so it appears in the menu bar rather than the Dock.

## First run and daily use

1. Open File-Flip. The onboarding window explains that conversion is local and asks for folders to monitor.
2. Select one or more folders. Desktop and Downloads are useful starting points, but no folder is monitored without explicit selection.
3. In an authorized folder, change only a supported file's extension—for example, `photo.jpg` to `photo.png`. Accept Finder's extension-change prompt if it appears.
4. Wait for the menu-bar status to report completion.
5. Open **Recent Activity** to inspect the committed behavior or select **Undo**. In the default copy mode, Undo removes the unchanged converted output and leaves the original in place; in replace mode, Undo restores the retained original.

Important behavior:

- The basename must remain unchanged. Renaming `photo.jpg` to `scan.png` is treated as an ordinary rename, not a conversion command.
- File-Flip inspects bytes instead of trusting the old extension.
- Unsupported, ambiguous, unstable, symlinked, packaged, temporary, or out-of-scope files are left unchanged.
- A conversion that may discard information can pause in **Choice Required** until an applicable default is configured in Settings.
- **Pause Monitoring** stops accepting new conversion work; a transaction already at its final publication boundary may finish safely.
- Folder authorization, monitoring state, backup retention, launch at login, provider availability, supported pairs, and future-job defaults are managed in Settings.

### Conversion behavior

Choose **Settings → Defaults → Conversion behavior** to control future conversions:

- **Keep original and create converted copy** is the default. After renaming `photo.jpg` to `photo.png`, both the exact original `photo.jpg` and validated converted `photo.png` remain visible. These conversions do not consume retained-backup quota.
- **Replace file and keep recoverable backup** leaves only the converted `photo.png` visible and stores the exact original privately until its configured retention limit removes it.

The selected behavior is captured when each conversion starts. Changing the setting does not alter conversions already running or relabel completed history entries. File-Flip refuses Undo rather than overwriting a changed, missing, or conflicting visible file.

## Format providers

The Settings **Formats** tab is the authoritative runtime list. File-Flip publishes a pair only when both its provider and independent validator are available.

| Provider | Coverage | Availability |
|---|---|---|
| Native Image I/O | JPEG/JPG, PNG, HEIC/HEIF, TIFF/TIF, WebP | Built in; individual targets depend on macOS writable image support |
| Bundled FFmpeg/ffprobe | MP3, M4A, AAC, WAV, AIFF/AIF, FLAC, OGG, OPUS; MP4, M4V, MOV, MKV, WEBM | Built in; startup verifies signatures, hashes, architecture, version, and codec inventory |
| PDFKit/Core Graphics | PDF to PNG/JPEG or extractable TXT | Built in; page selection or fidelity policy may be required |
| Native document providers | Markdown to HTML/PDF and safe-subset HTML to Markdown | Built in |
| Installed LibreOffice | Explicit DOCX/ODT/RTF/PDF/TXT/HTML and XLSX/ODS/CSV routes | Optional; appears only after local installation and security/capability checks pass |

Not every format in one row converts to every other format. Identity conversions are ignored, cross-family media conversion is not advertised, and unsafe or uncertified pairs remain unavailable.

## Architecture

```mermaid
flowchart LR
    Finder[Finder extension rename] --> Events[FSEvents file-level adapter]
    Events --> Correlator[Rename correlator and deduplicator]
    Correlator --> Stable[Stability and boundary gates]
    Stable --> Detector[Content detector]
    Detector --> Registry[Certified capability registry]
    Registry --> Provider[Native, FFmpeg, or LibreOffice provider]
    Provider --> Validator[Independent output validator]
    Validator --> Transaction[Mode-aware publication, recovery, journal]
    Transaction --> UI[Status, history, notification, undo]
```

### Modules

- **`FileConvertApp`** — SwiftUI `MenuBarExtra`, onboarding and Settings windows, application state, provider bootstrap, monitoring lifecycle, notifications, and launch-at-login integration.
- **`FileConvertCore`** — domain types, security-scoped folder authorization, FSEvents ingestion, strict rename correlation, content detection, SQLite WAL journal, transaction state machine, recovery, retention, and undo.
- **`FileConvertProviders`** — provider registry, native image/PDF/document converters, bounded FFmpeg and LibreOffice process execution, capability certification, and independent artifact validators.

### Conversion transaction

1. FSEvents reports file-level rename events under an enabled, authorized root.
2. The correlator accepts only a regular file with the same basename and a changed extension. Replayed events are deduplicated; dropped streams never synthesize conversion intent during a rescan.
3. The stability gate waits for writes to settle. Boundary guards reject symlinks, packages, hidden work files, path escapes, oversized input, and files outside the authorized root.
4. Content detection identifies the source from bounded file reads. The registry requires an exact, certified source-to-target capability.
5. The transaction captures the current conversion behavior, copies an immutable source snapshot, and records durable state in SQLite before invoking a provider.
6. The provider writes one bounded artifact in an isolated job directory. External tools receive direct argument vectors, a sanitized environment, output limits, deadlines, and process-tree cancellation.
7. A validator independent from the provider decodes or probes the artifact and checks the requested container plus relevant dimensions, streams, duration, structure, or semantics.
8. Only the transaction coordinator may publish visible files. Default copy mode prepares and verifies distinct original and converted siblings, restores the original path without replacing an existing file, then atomically publishes the converted target. Replace mode durably retains the original before atomically replacing the renamed file.
9. A crash is reconciled from the journal on next launch. Ambiguous states preserve all artifacts for manual recovery rather than guessing or overwriting a user file.
10. Undo follows the behavior captured by that history entry. Copy-mode Undo verifies both visible hashes before quarantining and deleting only the converted output; replace-mode Undo restores the retained original only when the current output remains unchanged. Conflicting paths are never overwritten.

### Local data and privacy

Application state is stored with owner-only permissions under:

```text
~/Library/Application Support/app.File-Flip.File-Flip/
```

That directory contains `journal.sqlite`, the single-instance lock, and private per-job snapshots. Replace-mode conversions also retain original-file backups there. Backup retention defaults to 30 days and is configurable in Settings; default copy-mode conversions create no retained-backup record or quota usage. File-Flip has no network-client or network-server entitlement; bundled FFmpeg is built with network protocols disabled.

## Development

### Build and test

The canonical complete local suite is:

```sh
xcodebuild test \
  -project File-Flip.xcodeproj \
  -scheme File-Flip \
  -destination 'platform=macOS,arch=arm64'
```

The scheme includes core, provider, integration, and UI test targets. Swift Package Manager is useful for the non-UI module suite:

```sh
swift test
```

Focused examples:

```sh
xcodebuild test \
  -project File-Flip.xcodeproj \
  -scheme File-Flip \
  -only-testing:File-FlipCoreTests \
  -destination 'platform=macOS,arch=arm64'

xcodebuild test \
  -project File-Flip.xcodeproj \
  -scheme File-Flip \
  -only-testing:File-FlipIntegrationTests \
  -destination 'platform=macOS,arch=arm64'
```

### Website and GitHub Pages

The Astro website builds locally with:

```sh
cd site
npm ci
npm run build
```

The static output is written to `site/dist/`. Pushes to `main` run [the Pages workflow](.github/workflows/deploy-pages.yml), which builds from `site/` and publishes the site at <https://chasedputnam.github.io/file-flip/>. In the repository's **Settings → Pages**, select **GitHub Actions** as the source once before the first deployment.

All website download buttons point to <https://github.com/chasedputnam/file-flip/releases/latest>. That URL follows whichever published GitHub release is marked latest; it returns 404 until the repository has a published release.

The first-release signing, notarization, verification, and GitHub publishing procedure is documented in [RELEASING.md](RELEASING.md).

### Project structure

```text
Config/                         App Info.plist
Sources/File-FlipApp/         macOS application and UI
Sources/File-FlipCore/        monitoring and transaction domain
Sources/File-FlipProviders/   conversion and validation providers
Tests/                          unit, provider, integration, and UI suites
Scripts/                        project, media, fixture, and release tooling
release/                        fail-closed release contract
specs/macos-extension-converter requirements, design, and task record
```

### Regenerate the Xcode project

`File-Flip.xcodeproj` is generated from the source tree. Install the Ruby `xcodeproj` gem if it is not already available, then regenerate:

```sh
gem install xcodeproj
ruby Scripts/generate-project.rb
```

Regeneration deletes and recreates `File-Flip.xcodeproj`; do not hand-edit the project and regenerate afterward expecting those edits to survive.

### Rebuild bundled media tools

The checked-in media bundle is sufficient for ordinary development. To reproduce it from pinned source archives:

```sh
Scripts/build-media-tools.sh
```

The script requires an Apple Silicon macOS host, Xcode command-line tools, `curl`, `make`, and Python 3. It builds arm64 static FFmpeg/ffprobe executables, verifies every source archive checksum, disables network support and GPL/nonfree configuration, emits source/license manifests, and ad-hoc signs local artifacts. Use `--signing-identity` or `MEDIA_TOOLS_SIGNING_IDENTITY` for a release identity.

### Fixture and release gates

Fixture checks are compare-only by default:

```sh
python3 Scripts/check-fixtures.py Tests/File-FlipProvidersTests/Fixtures/Images/manifest.json
```

Fixture updates require the explicit update mode documented in `release/release-contract.json`; generated semantic and hash changes must be reviewed.

The release gate is fail-closed and needs a signed app, recorded evidence, and owner-only data-root observations:

```sh
python3 Scripts/release-readiness.py \
  --app /path/to/File-FlipApp.app \
  --data-root "$HOME/Library/Application Support/app.File-Flip.File-Flip" \
  --evidence /path/to/release-evidence.json
```

`release/release-contract.json` is the source of truth for required platforms, suites, thresholds, fixture inventories, architectures, entitlements, and external evidence. A green local test run does not by itself certify a distributable release.
