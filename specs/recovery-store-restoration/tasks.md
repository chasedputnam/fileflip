# Implementation Tasks — Recovery Store Restoration

Approved by: Chase Putnam  Date: 2026-07-29  Status: approved

Execute in order. Complete one checkbox at a time; do not begin a dependent task until its prerequisite is working.

- [x] 1. Persist append-only recovery resolutions
  - Add `RecoveryResolutionMethod` and `RecoveryResolutionRecord` to the core journal domain.
  - Migrate `JournalStore` to schema version 3 with the constrained, cascading `recovery_resolution` table from the approved design.
  - Add guarded insert, lookup, and unresolved-recovery query APIs. Accept only an unresolved `.needsRecovery` job recorded with `.replaceWithBackup`; reject duplicate, non-recovery, and `.keepOriginal` resolutions.
  - Preserve every pre-migration `.needsRecovery` job as unresolved; do not synthesize a resolution.
  - Update journal decoding/query support without changing existing conversion terminal-state semantics.
  - _Requirements: 1.6, 3.1, 3.2, 3.5, 3.6, 4.4, 4.6_

- [x] 2. Protect unresolved recovery data from cleanup
  - Change backup-pruning eligibility in journal SQL so age and byte-pressure pruning exclude `.needsRecovery` jobs without a resolution record.
  - Make resolved recovery backups eligible under the existing expiration and byte-limit policy; do not invent a second retention policy.
  - Change clearable-history selection and deletion so unresolved recovery jobs and their retained artifacts survive Clear History, while resolved recovery jobs remain clearable.
  - Update the runtime clear-history confirmation/result path to tolerate protected unresolved rows and remove only storage directories for journal-approved clearable job IDs.
  - _Requirements: 3.1, 4.6, 5.1, 5.2_

- [x] 3. Implement the fail-closed retained-file restoration transaction
  - Add a dedicated recovery restoration API to `RecoveryCoordinator`; keep successful-conversion undo restoration behavior separate.
  - Require an unresolved `.replaceWithBackup` recovery job and a backup path contained beneath the configured recovery root.
  - Verify with `lstat` that the artifact is a readable regular non-symlink file and verify its SHA-256 before and after staging.
  - Stage into a uniquely named hidden file in the selected destination directory, apply retained metadata, flush the staged file, publish with `renameatx_np(..., RENAME_EXCL)`, and flush the destination directory before reporting publication.
  - Scope cleanup to the coordinator’s unpublished temporary file. Never modify or remove the current visible file, selected existing objects, published destination, or retained artifact.
  - Persist `.restored` with only the destination filename after durable publication. Return typed outcomes/errors for conflict, unavailable artifact, integrity failure, permission failure, publication failure, and restored-but-resolution-write-failed.
  - Add manual acknowledgement through the same coordinator, persisting `.acknowledged` only after explicit caller confirmation.
  - _Requirements: 2.1–2.7, 3.2, 3.7, 4.4, 4.5, 5.5_

- [ ] 4. Expose persisted recovery lifecycle through the application runtime
  - Add restore-recovery and manual-resolution operations to `ApplicationRuntime`, `ConcreteApplicationRuntime`, and bootstrap/test conformers.
  - Add `RecoveryArtifactAvailability` and `RecoveryState` to `HistoryItemState`; keep undo `Availability` independent.
  - Map recovery state only for `.needsRecovery` jobs whose recorded behavior is `.replaceWithBackup`. The current future-job default must not influence an existing item; `.keepOriginal` jobs remain `.notApplicable`.
  - Verify artifact availability from the journal record, contained storage URL, regular-file type, readability, and recorded hash without exposing the private path.
  - Map resolved method, privacy-preserving destination filename, and resolution date into history snapshots.
  - Derive the unresolved collection and menu status input from persisted mapped recovery state on every snapshot, including startup.
  - _Requirements: 1.1, 1.6, 3.1–3.6, 4.1, 4.6, 5.1_

- [ ] 5. Add recovery actions and safe destination selection
  - Add `Restore Retained File…` only for unresolved eligible items with an available verified artifact. Explain the affected filename, separate-copy behavior, current-file protection, and destination choice before opening the panel.
  - Present `NSSavePanel` with `<original stem> — Recovered.<original extension>` and the accessible original parent when available. Use a panel delegate to reject occupied destinations before acceptance; rely on the core exclusive rename for race safety.
  - Treat cancellation as a no-op. On destination conflict, keep the item unresolved and let the user choose again.
  - Add `Mark as Resolved…` to every unresolved eligible item, including unavailable artifacts. Require confirmation that no file will be restored, warnings will stop, and retention becomes applicable.
  - Refresh and reselect the history item after either resolution path. Show distinct in-app feedback for every typed failure and the restored-but-status-update-failed outcome without private paths.
  - After complete success, show `Recovery Complete`, identify only the restored filename, and offer `Reveal in Finder` without making Finder reveal part of transaction success.
  - Show `Recovered as <filename>`, `Resolved manually`, and `Recovery data unavailable` distinctly in rows, details, accessibility labels, and safe-next-action text.
  - Update Clear History messaging to state that unresolved recovery items remain protected.
  - _Requirements: 1.1–1.6, 2.3–2.7, 3.3, 3.4, 3.6, 3.7, 4.1–4.6, 5.3, 5.5_

- [ ] 6. Route recovery status and notifications to the exact history item
  - Move history selection into shared model/navigation state so menu and notification entry points can select a job before opening the History window.
  - Add `Review Recovery…` to the menu status area for the first unresolved item and route recovery recent-activity rows to their own detail.
  - Install a `UNUserNotificationCenterDelegate`-backed app navigation coordinator that activates FileFlip, opens the History window, and selects the recovery job UUID carried in notification user info.
  - Add the recovery job UUID and navigation category to existing `File Recovery Required` notifications.
  - After durable restore plus successful resolution persistence, post `Retained File Restored — <filename> was restored successfully.` subject to macOS permission. Notification denial or delivery failure must not fail restoration.
  - Ensure notification bodies, routing payloads, accessibility text, and support-facing errors omit full user and recovery-store paths.
  - _Requirements: 3.3, 3.4, 5.3, 5.4, 5.6_

- [ ] 7. Smoke-test the complete recovery workflow
  - Seed an isolated real app store with one `.replaceWithBackup` `.needsRecovery` job, a hash-verified retained artifact, and a distinct current visible file.
  - Launch FileFlip, verify the persisted medical-bag status, select `Review Recovery…`, restore through the real save panel, and observe the in-app success state.
  - Confirm the current visible file is byte-for-byte unchanged, the destination matches retained bytes, history reads `Recovered as <filename>`, and the medical-bag state clears for the final unresolved item.
  - Relaunch against the same store and confirm the resolved history presentation and normal menu status persist.
  - Repeat the smoke path with an occupied destination and confirm no existing object changes and the item remains retryable.
  - Fix implementation defects exposed by the smoke scenario before proceeding to regression coverage.
  - _Requirements: 1.1–1.6, 2.1–2.7, 3.1–3.7, 5.3–5.6_

- [ ] 8. Add focused regression coverage and run final verification
  - Add journal migration/lifecycle tests for version-2 unresolved carry-forward, valid resolution, duplicate/non-recovery/`.keepOriginal` rejection, relaunch persistence, pruning protection, resolved eligibility, and protected Clear History.
  - Add real-filesystem transaction tests for exact bytes, unchanged current file, file/directory/symlink conflicts, exclusive-rename race, missing/non-regular/path-escaping/corrupt artifacts, publication failpoints, post-publication resolution-write failure, retry, and manual acknowledgement.
  - Add app-model tests for recorded-behavior gating, current-default independence, multi-item menu status, last-resolution status recalculation, typed alerts, filename-only notification content, and selection routing.
  - Add UI coverage for available/unavailable/resolved/manual detail states, save cancellation, conflict retry, manual confirmation cancellation, `Review Recovery…`, notification navigation, Finder reveal availability, Clear History protection text, and relaunch persistence.
  - Run the focused journal, transaction, app-model, and UI tests; then run the complete Swift test suite and the recovery end-to-end scenario. Record exact commands and outcomes.
  - _Requirements: 1.1–1.6, 2.1–2.7, 3.1–3.7, 4.1–4.6, 5.1–5.6_
