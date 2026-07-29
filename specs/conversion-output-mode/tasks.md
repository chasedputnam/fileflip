# Tasks — conversion-output-mode

Approved by: Product owner  Date: 2026-07-28  Status: approved

- [x] 1. Add the versioned conversion behavior contract
  - References: Requirements 1.1–1.4, 4.1, 4.6, 5.1
  - [x] 1.1 Define public `ConversionBehavior` cases `keepOriginal` and `replaceWithBackup`; add the behavior to `TransactionRequest`, `JournalJob`, `CommittedTransaction`, and application history projections without introducing implicit boolean flags.
  - [x] 1.2 Extend `FutureJobDefaults` with explicit version-tolerant decoding that uses `keepOriginal` for a missing or unknown preference while preserving every existing format-policy value.
  - [x] 1.3 Capture one immutable defaults snapshot in `ConversionEngine.handle(_:)` and pass its behavior and format policy into every new transaction; add focused concurrency tests proving a later settings change cannot alter an in-flight request.
  - [x] 1.4 Add round-trip and malformed-preference tests for both values, missing values, unknown values, and relaunch persistence.

- [x] 2. Migrate the journal without rewriting historical behavior
  - References: Requirements 4.1, 4.6, 5.2
  - [x] 2.1 Replace the unconditional schema setup with ordered `PRAGMA user_version` migrations; add a non-null `conversion_behavior` column whose migration default is `replaceWithBackup`, then require explicit behavior on all new inserts.
  - [x] 2.2 Update every journal select, row decoder, transition copy, UI-test fixture, and test factory to preserve the behavior; reject unknown stored transaction values as corrupt instead of applying the future-job default.
  - [x] 2.3 Add migration tests that open a real version-1 database, verify existing rows decode as replace mode, verify new rows round trip either mode, and verify repeated migration is idempotent.

- [x] 3. Implement mode-aware transactional publication
  - References: Requirements 2.1–2.8, 3.1–3.4, 5.1–5.3
  - [x] 3.1 Refactor `TransactionCoordinator.execute` so detection-independent staging, hashing, metadata capture, provider execution, validation, space checks, and sibling verification are shared while retained-backup creation remains mandatory only for replace mode.
  - [x] 3.2 Preserve the current `replaceWithBackup` state path and behavior exactly, including durable backup insertion before conversion, quota accounting, atomic target replacement, and existing failpoints.
  - [x] 3.3 Add `publishingOriginal` and `publishingConverted` states and their legal transitions; prepare and flush distinct original/output siblings before either publication and ensure catch handling leaves publication states for recovery.
  - [x] 3.4 Publish the staged original to the canonical pre-rename path with Darwin no-replace rename semantics, flush its parent, recheck both user paths, then atomically publish validated output to the extension-renamed path.
  - [x] 3.5 Reject occupied/unsafe original paths, volume drift, source identity/hash changes, insufficient space, sibling mismatch, and no-replace races without overwriting a user file; add real-APFS integration tests for each conflict.
  - [x] 3.6 Assert successful copy transactions create no backup row, consume no retained-backup quota, preserve source metadata on the restored original, and apply target-compatible metadata to the converted result.

- [x] 4. Reconcile every copy publication boundary
  - References: Requirements 2.6–2.7, 3.4, 5.2–5.3
  - [x] 4.1 Extend `RecoveryCoordinator` to branch on captured behavior and inspect canonical original, target, prepared siblings, identities, and journaled hashes according to the approved recovery table.
  - [x] 4.2 Resume only the unambiguous copy states `(original absent, target source, prepared output valid)`, `(original source, target source, prepared output valid)`, and `(original source, target output)`; make each recovery path idempotent.
  - [x] 4.3 Route missing, changed, escaped, or mismatched path combinations to `needsRecovery` while preserving every user and private artifact; retain replace-mode reconciliation unchanged.
  - [x] 4.4 Add failpoints and real-filesystem tests after every copy, hash, flush, journal transition, original publish, output publish, and terminal write; at each point assert at least one visible exact source and zero overwritten conflicts.

- [x] 5. Implement mode-specific history, undo, and cleanup
  - References: Requirements 4.1–4.6, 5.1, 5.4
  - [x] 5.1 Project conversion behavior and both relative filenames into `HistoryItemState`; compute copy undo availability only when original/output hashes match, and retain backup-based availability for replace mode.
  - [x] 5.2 Extend `UndoCoordinator` so copy undo verifies both files, quarantines the target with a same-volume rename, re-verifies it, deletes only the committed output, and leaves the original unchanged; restore an unverified quarantine exclusively or report a conflict.
  - [x] 5.3 Keep replace undo and restore-to-new-file behavior intact, and make restore-to-new-file unavailable for copy entries that have no retained backup.
  - [x] 5.4 Update clear-history cleanup to delete copy job artifacts and journal rows without touching either visible file; retain the explicit warning before deleting replace-mode retained originals.
  - [x] 5.5 Add integration tests for successful undo in both modes, changed/missing original, changed/missing output, quarantine races, clear history, and backup quota accounting.

- [x] 6. Expose conversion behavior in the application UI
  - References: Requirements 1.1–1.5, 4.1–4.5, 5.5
  - [x] 6.1 Add the two-choice **Conversion behavior** picker and mode-specific storage explanation to General Settings using accessibility identifier `settings.conversion-behavior`; save through the existing future-defaults path.
  - [x] 6.2 Add mode-specific history detail, success text, undo availability, and sanitized destination-conflict messaging; ensure icons and color are not the only mode indicator.
  - [x] 6.3 Update `ApplicationRuntime`, bootstrap failure runtime, snapshot mapping, view-model state, preview data, and UI-test launch fixtures to carry the behavior end to end.
  - [x] 6.4 Add UI tests proving copy mode is selected without a preference, either selection survives relaunch, active conversion state does not change, and history/undo labels match committed behavior.

- [x] 7. Prove both modes through the supported application path
  - References: Requirements 5.1–5.5
  - [x] 7.1 Run all existing core, provider, integration, and UI suites with replace mode fixtures to demonstrate the alternative preserves current behavior.
  - [x] 7.2 Add a supported-file rename integration scenario for copy mode that independently hashes the restored original, validates/opens the converted target, checks history, performs undo, and confirms no backup record exists.
  - [x] 7.3 Exercise both choices through the signed development application's Finder/FSEvents path: copy mode must leave two visible files; replace mode must leave one visible conversion with exact retained-backup undo.
  - [x] 7.4 Run the complete transaction fault matrix for both modes and fail delivery on any original-byte loss, pre-existing-path overwrite, unvalidated publication, incorrect backup accounting, non-idempotent recovery, or mismatch between saved and captured behavior.
