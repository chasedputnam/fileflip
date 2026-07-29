# Tasks — macOS-extension-converter

Approved by: Chase Putnam  Date: 2026-07-28  Status: approved

- [x] 1. Establish the native macOS application and testable module boundaries
  - References: Requirements 1.6, 5.1, 7.5, 7.7, 8.1–8.4
  - [x] 1.1 Initialize version control, an Apple Silicon-only macOS 14+ Xcode project, and targets for `FileConvertApp`, `FileConvertCore`, `FileConvertProviders`, a bundled media-tool resource, and unit/integration/UI tests; enable Swift 6 strict concurrency and owner-only application-support storage.
  - [x] 1.2 Add a minimal `LSUIElement` SwiftUI `MenuBarExtra` app that starts one coordinator instance, displays inactive status, opens an empty settings scene, and exits cleanly.
  - [x] 1.3 Define versioned core types for file identity, detected formats, capabilities, conversion policies, provider health, jobs, artifacts, and errors; make unsupported state transitions and unvalidated commits inaccessible through public APIs.
  - [x] 1.4 Add arm64 build/typecheck gates plus a unit test proving the single-instance lock excludes a second coordinator.

- [x] 2. Implement the crash-safe conversion transaction before real converters
  - References: Requirements 2.8, 4.1–4.8, 6.1–6.6, 7.2–7.4, 7.6–7.7
  - [x] 2.1 Implement the SQLite WAL store and migrations for authorized roots, conversion jobs, backups, provider installations, and versioned policies, including the terminal-job deduplication index.
  - [x] 2.2 Implement stable-file sampling, APFS clone/copy staging, SHA-256 verification, durable backup creation, disk-space preflight, hidden same-volume output siblings, flushes, and atomic replacement behind the typed transaction state machine.
  - [x] 2.3 Implement startup reconciliation for every nonterminal state and an injectable failpoint at each stage, backup, validation, sibling-copy, flush, replace, and journal boundary.
  - [x] 2.4 Implement exact-byte undo, original-name restoration, changed-output conflict detection, non-destructive restore-to-new-file, 30-day/10-GiB retention, and oldest-first safe pruning.
  - [x] 2.5 Add real-filesystem integration tests that kill or fail the transaction at every boundary and assert exact source recovery, no unvalidated replacement, idempotent recovery, and safe undo conflicts.

- [x] 3. Detect only confirmed extension-changing rename intent
  - References: Requirements 1.3–1.5, 2.1–2.8, 5.2–5.3, 7.1–7.3, 7.5–7.7
  - [x] 3.1 Implement the file-level, extended-data FSEvents adapter with dispatch-queue delivery, root lifecycle management, event cursor persistence, drop/root-change reporting, and bounded event buffering.
  - [x] 3.2 Implement rename pairing by event ID and file identity, requiring the same basename and a changed extension; reject missing halves, directories, links, packages, hidden working files, cross-root moves, and candidates no longer contained by an enabled canonical root.
  - [x] 3.3 Implement the 500-ms/two-snapshot stability gate, latest-name reevaluation, 30-second stability timeout, and deduplication key `(volume UUID, file ID, requested format, source hash)`.
  - [x] 3.4 Wire eligible candidates into the transaction engine with a deterministic fake provider; pausing shall stop new jobs, resuming shall start from new events, and dropped-event recovery shall refresh identity state without converting pre-existing mismatches.
  - [x] 3.5 Add generated event-sequence tests covering pairs, reordering, duplicates, replay, drops, renames during queueing, root removal, and 1,000-sequence exactly-once acceptance.

- [x] 4. Build bounded content detection and the capability allowlist
  - References: Requirements 2.1–2.6, 3.1–3.7, 3.15, 8.1–8.4
  - [x] 4.1 Implement layered detectors for ImageIO images, PDFKit PDFs, bounded OOXML/ODF ZIP markers, strict text/HTML/Markdown/CSV probes, and bounded `ffprobe` JSON; extension and Finder type may label results but shall not authorize them.
  - [x] 4.2 Implement the capability registry as the sole source-to-target allowlist, with provider health/version/signature/self-test gates, versioned defaults, fidelity-loss metadata, and a query API for settings.
  - [x] 4.3 Add malformed, mislabeled, polyglot, oversized-package, archive-traversal, and decompression-bomb fixtures proving uncertain or unsafe input is rejected without starting a transaction.
  - [x] 4.4 Add contract tests proving every advertised pair has one healthy provider, one independent validator, a default policy, and certified fixtures; provider failure shall remove only its pairs.

- [x] 5. Deliver safe native image conversion
  - References: Requirements 3.1, 3.7–3.10, 3.13–3.15, 4.1–4.4, 8.2–8.4
  - [x] 5.1 Implement the ImageIO/CoreGraphics provider for runtime-writable JPEG/JPG, PNG, HEIC/HEIF, TIFF, and WebP pairs with typed quality, metadata, orientation, ICC profile, transparency-background, and frame/page policies.
  - [x] 5.2 Implement independent image validation for requested type, decodability, expected dimensions/orientation, required alpha behavior, color profile behavior, and configured frame/page selection.
  - [x] 5.3 Add certified fixtures for each advertised pair plus transparency, orientation, profile, animated/multi-frame, malformed, and metadata-stripping cases; remove any pair the oldest supported macOS cannot encode reliably.
  - [x] 5.4 Run the real rename-to-atomic-replacement integration path for every image fixture and assert output recognition, source backup hash, history state, and exact undo.

- [ ] 6. Deliver the pinned local audio and video provider
  - References: Requirements 3.2–3.3, 3.7–3.9, 3.11, 3.13–3.15, 4.1–4.4, 7.1, 8.2–8.4
  - [x] 6.1 Add reproducible scripts that build arm64-only FFmpeg/ffprobe artifacts without `--enable-gpl` or `--enable-nonfree`, emit exact source/build/license manifests, sign bundled executables, and fail when the observed build configuration differs from the approved manifest.
  - [x] 6.2 Implement provider startup verification for path, code signature, hash, version, build configuration, codec inventory, and self-test before publishing MP3, M4A/AAC, WAV, AIFF, FLAC, OGG, Opus, MP4/M4V, MOV, MKV, and WebM capabilities.
  - [x] 6.3 Implement direct-argv conversion with approved codec/container mappings, selected stream/subtitle policies, Apple hardware-encoder preference with an approved software fallback, cancellation, process-group termination, 15-minute timeout, bounded logs, and bounded output.
  - [x] 6.4 Implement independent `ffprobe` validation for container, playable streams, selected-track preservation, nonzero duration, max(250 ms, 0.5%) duration tolerance, and truncation errors.
  - [ ] 6.5 Add certified media fixtures for every advertised pair, variable frame rates, multiple audio tracks, subtitles, chapters, corrupt/truncated files, timeout, cancellation, and provider crashes; exercise full transaction/undo integration on supported Apple Silicon macOS versions.

- [x] 7. Deliver local PDF, text, Markdown, and HTML conversion
  - References: Requirements 3.4, 3.6–3.10, 3.12–3.15, 4.1–4.4, 8.2–8.4
  - [x] 7.1 Implement PDFKit/CoreGraphics providers for PDF-to-PNG/JPEG page rendering and PDF-to-TXT only when extractable text exists, with explicit page-selection and image-quality policies.
  - [x] 7.2 Implement pinned Swift Markdown parsing, deterministic Markdown-to-HTML rendering, documented safe-subset HTML-to-Markdown conversion, and isolated network-disabled HTML-to-PDF rendering.
  - [x] 7.3 Reject external-resource loads, active content, unsupported HTML loss, absent PDF text, and ambiguous multi-page output until the user has an explicit policy.
  - [x] 7.4 Implement independent PDF/text/HTML/Markdown validators and certified fixtures for Unicode, embedded fonts, links, multiple pages, malformed PDFs, active HTML, external resources, and unsupported constructs.
  - [x] 7.5 Exercise every advertised pair through rename, transaction, history, and undo integration tests with zero outbound connections observed.

- [ ] 8. Deliver installed-LibreOffice document and spreadsheet conversion
  - References: Requirements 3.4–3.5, 3.7–3.9, 3.12–3.15, 4.1–4.4, 8.1–8.4
  - [x] 8.1 Implement LibreOffice discovery and verification for bundle ID, Developer ID signature, executable location, tested version range, conversion filters, unique per-job profile, and startup self-test; publish no office capabilities when any check fails.
  - [x] 8.2 Implement fixed `soffice --headless --convert-to` requests for DOCX↔ODT, DOCX/ODT/RTF→PDF/TXT/HTML, XLSX↔ODS, CSV→XLSX/ODS, and XLSX/ODS→CSV with typed filter names and no user-supplied command fragments.
  - [x] 8.3 Implement sheet selection, delimiter/encoding, formula-value, embedded-resource, macro-denial, timeout, bounded-output, cancellation, serialized execution, and isolated-profile cleanup policies.
  - [x] 8.4 Implement independent OOXML/ODF package/PDF/text/CSV validators and semantic extracts for readable content, sheet/cell values, formulas, page counts, and provider fidelity warnings.
  - [ ] 8.5 Run the certified office matrix against every supported LibreOffice version, including fonts/layout warnings, multiple sheets, formulas, comments, macros, malformed packages, provider crashes, and full transaction/undo integration.

- [x] 9. Add explicit folder authorization and onboarding
  - References: Requirements 1.1–1.6, 5.5–5.7, 6.2–6.3, 7.6
  - [x] 9.1 Build first-run onboarding that explains rename-to-convert, suggests Desktop and Downloads without preselecting them, and uses `NSOpenPanel` to authorize one or more folders.
  - [x] 9.2 Implement security-scoped bookmark creation, owner-only persistence, resolution, stale-bookmark refresh, exact-root containment, volume identity checks, root enable/disable/removal, and permission-loss recovery.
  - [x] 9.3 Connect authorized-root changes to FSEvent stream lifecycle without replaying existing files, and implement launch-at-login through `SMAppService.mainApp` with visible authorization status.
  - [x] 9.4 Add UI/integration tests for first launch, add/remove/disable folder, overlapping roots, revoked permission, replaced removable volume, restart restoration, and login-item enable/disable.

- [x] 10. Complete menu-bar status, policies, history, and undo UX
  - References: Requirements 3.8–3.9, 4.5–4.7, 5.1–5.7, 6.1–6.5, 8.4
  - [x] 10.1 Implement accessible menu-bar states for active, paused, converting, needs-choice, permission/provider blocked, and recovery required, with responsive pause/resume and bounded recent activity.
  - [x] 10.2 Implement settings for watched roots, capability/provider status, backup usage/retention, launch at login, and typed image/media/document/spreadsheet policies; settings changes affect only future jobs.
  - [x] 10.3 Implement local history with redacted errors, provider/version and fidelity warnings, clear-history warning, unavailable-file state, Undo, and restore-to-new-file conflict flow.
  - [x] 10.4 Implement actionable local notifications for failures and required choices without file contents or unnecessary full paths, plus VoiceOver labels and keyboard navigation.
  - [x] 10.5 Add UI tests covering the first successful conversion, pause/resume semantics, required policy choice, provider unavailable state, failure detail, clear history, exact undo, and changed-file restore conflict.

- [x] 11. Enforce provider, parser, privacy, and resource boundaries
  - References: Requirements 2.4–2.8, 3.7–3.15, 4.2–4.3, 5.5, 6.2–6.6, 7.1, 7.4–7.7, 8.2–8.4
  - [x] 11.1 Centralize canonical-path validation, strict policy decoding, executable allowlisting, direct argument construction, environment sanitization, macro/network denial, log redaction, output caps, deadlines, and process-tree cancellation.
  - [x] 11.2 Add provider mutation tests proving a zero exit with wrong/corrupt/truncated output cannot construct `ValidatedArtifact` or reach commit, and that provider health loss cancels queued pairs without touching source files.
  - [x] 11.3 Add network-capture tests around onboarding, all provider families, history, and undo; fail the suite on any outbound connection or external HTML resource load.
  - [x] 11.4 Add idle-resource and load tests enforcing at most 0.5% average CPU, no idle content scan, at most 100 MiB resident memory, responsive menu controls, two-job global concurrency, and one-job office concurrency.
  - [x] 11.5 Add external-volume filesystem probes and integration tests that disable conversion when same-directory atomic replacement, flush, permissions, or metadata behavior cannot meet the transaction contract.

- [ ] 12. Prove the complete release contract on supported Macs
  - References: Requirements 1.1–1.6, 2.1–2.8, 3.1–3.15, 4.1–4.8, 5.1–5.7, 6.1–6.6, 7.1–7.7, 8.1–8.4
  - [x] 12.1 Assemble the certified fixture inventory and make the default test run compare-only; require an explicit update mode and reviewable semantic/golden diffs to regenerate fixtures.
  - [ ] 12.2 Run the full unit, contract, real-provider integration, fault-injection, privacy, idle-resource, UI, and rename end-to-end suites on the oldest supported Apple Silicon macOS and current macOS; record exact commands and observed thresholds.
  - [ ] 12.3 Build the signed arm64 release candidate, verify hardened runtime, nested executable signatures, provider manifests, absence of unauthorized network entitlements/frameworks, owner-only data permissions, and successful notarization assessment without publishing it.
  - [ ] 12.4 Perform the Finder smoke path for one file in every enabled format family: authorize folder, rename, observe status, independently open/inspect output, undo, pause/resume, restart, and confirm no completed event replays.
  - [x] 12.5 Fail release readiness if any advertised pair lacks a passing certified fixture, any fault loses source bytes, any privacy probe connects outbound, any threshold misses, or codec/license manifests lack the required review evidence.
