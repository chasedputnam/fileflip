# Requirements — Conversion output mode

Approved by: Product owner
Date: 2026-07-28
Status: approved

#[[file:../macos-extension-converter/requirements.md]]

## Introduction

FileConvert currently replaces the extension-renamed file after preserving its pre-conversion bytes in the private backup store. Users need a safer default that leaves the original as an ordinary visible file beside the converted result, while retaining the existing replacement-and-backup workflow as an explicit alternative.

The setting controls future conversions only. It does not alter completed history entries, retained backups, or a conversion whose transaction has already started.

## Scope priorities

### Must have

- A global **Conversion behavior** setting with two values:
  - **Keep original and create converted copy**
  - **Replace file and keep recoverable backup**
- Copy mode is the default when no saved value exists.
- Copy mode restores the original file to its pre-rename filename and writes the validated conversion at the extension-renamed filename.
- Replace mode preserves the current transactional replacement, retained-backup, and undo behavior.
- Both modes fail closed on filename conflicts, concurrent edits, validation failures, I/O failures, and crashes.
- History and undo accurately reflect the mode captured by each conversion.
- The selected mode is persisted locally and applies only to transactions created after the change.

### Should have

- Settings copy explains visible-file and storage consequences of both modes.
- History identifies whether a conversion created a copy or replaced a file.
- Backup usage excludes successful copy-mode conversions because their original remains user-visible.

### Out of scope

- Per-folder or per-format output modes.
- Asking for a mode on every rename.
- Choosing a custom output directory or filename template.
- Keeping multiple converted variants automatically.
- Retroactively changing or migrating completed conversions.

## Requirement 1 — Configure conversion behavior

**User Story:** As a user, I want to choose whether FileConvert keeps the original beside the converted result or replaces it with a recoverable backup, so that conversion matches my preferred file-management workflow.

### Acceptance Criteria

1.1 The application SHALL expose one global **Conversion behavior** control in Settings with exactly these choices: **Keep original and create converted copy** and **Replace file and keep recoverable backup**.

1.2 WHEN no valid saved conversion behavior exists, including on first launch or after decoding an unknown value, THEN the application SHALL use **Keep original and create converted copy**.

1.3 WHEN the user changes the conversion behavior THEN the application SHALL persist the selection locally and apply it to conversions whose transaction records are created after the setting is saved.

1.4 WHEN a conversion transaction has already been created THEN changing the setting SHALL NOT change that transaction's captured behavior.

1.5 WHEN settings are displayed THEN the application SHALL explain that copy mode keeps two visible files and uses additional space, while replace mode keeps one visible file and stores a temporary recoverable original subject to the configured retention limits.

## Requirement 2 — Keep original and create converted copy

**User Story:** As a cautious user, I want the original file to remain visible after conversion, so that I do not depend on application-managed backup retention to preserve it.

### Acceptance Criteria

2.1 GIVEN an eligible extension-only rename from `name.source` to `name.target` WHEN a copy-mode conversion succeeds THEN the application SHALL leave the exact pre-conversion bytes and restorable metadata at `name.source` and SHALL place independently validated target-format bytes at `name.target`.

2.2 WHEN copy-mode conversion begins THEN the application SHALL stage and hash the source before invoking a provider, but a successful copy-mode conversion SHALL NOT create a retained backup record or consume retained-backup quota.

2.3 BEFORE publishing either copy-mode result, the application SHALL verify that the extension-renamed source has not changed and that the pre-rename path remains available for safe creation.

2.4 IF the pre-rename path already exists, becomes occupied, resolves outside the authorized root, or cannot be created safely THEN the application SHALL NOT overwrite it, SHALL NOT replace the extension-renamed source, and SHALL report a filename conflict.

2.5 IF conversion, validation, space checks, or preparation fails before publication THEN the application SHALL leave the extension-renamed source bytes unchanged and SHALL NOT create a partial visible original or converted result.

2.6 WHEN publishing a copy-mode result THEN the application SHALL prepare and flush hidden same-volume siblings before filesystem renames, publish the exact original at the pre-rename path before replacing the extension-renamed path with the converted result, and record enough durable state to reconcile an interruption between those operations.

2.7 IF publication is interrupted after the original is restored but before the converted result is committed THEN recovery SHALL preserve both original-byte copies, SHALL complete the validated converted result only when journaled hashes and path identities prove it safe, and SHALL otherwise require user action without overwriting either path.

2.8 WHEN copy mode succeeds THEN the application SHALL preserve the original file's restorable metadata on `name.source`; the converted copy SHALL preserve applicable metadata according to the conversion policy and requested target format.

## Requirement 3 — Replace file and keep recoverable backup

**User Story:** As a user who prefers a single visible output, I want FileConvert to replace the renamed file while retaining a recoverable original, so that I can minimize visible duplicates without making replacement irreversible.

### Acceptance Criteria

3.1 GIVEN **Replace file and keep recoverable backup** is captured for a conversion WHEN conversion begins THEN the application SHALL durably preserve the exact pre-conversion bytes in the private backup store before replacing the extension-renamed file.

3.2 WHEN replace-mode conversion succeeds THEN the application SHALL keep the requested filename and extension, atomically replace its bytes with independently validated output, and retain the original according to the configured age and size limits.

3.3 IF backup creation, conversion, validation, or replacement fails THEN the application SHALL leave or restore the pre-conversion bytes at the extension-renamed path and report the failure.

3.4 Existing retained-backup pruning, restore-to-new-file, changed-file conflict, and crash-reconciliation guarantees SHALL continue to apply to replace-mode transactions.

## Requirement 4 — History, undo, and migration

**User Story:** As a user, I want history and undo to match how each conversion was committed, so that recovery actions are predictable.

### Acceptance Criteria

4.1 The application SHALL persist the captured conversion behavior with every conversion transaction and SHALL expose it in history details.

4.2 WHEN Undo is selected for an unchanged successful copy-mode conversion THEN the application SHALL remove the converted `name.target` file and leave the exact original `name.source` file unchanged.

4.3 IF the copy-mode converted file changed after commit, the original path no longer matches the committed original identity and hash, or either path is otherwise ambiguous THEN Undo SHALL refuse automatic deletion or overwrite and SHALL explain the conflict.

4.4 WHEN Undo is selected for a replace-mode conversion THEN the application SHALL retain the existing exact-backup restore behavior, including restore-to-new-file when the visible file changed.

4.5 WHEN history is cleared THEN copy-mode originals and converted files SHALL remain untouched, and replace-mode retained originals SHALL follow the existing explicit backup-deletion warning and policy.

4.6 Existing installations with no conversion-behavior preference SHALL adopt copy mode on the next conversion; completed history entries SHALL retain their original replace-mode semantics through an explicit schema migration rather than being reinterpreted as copy-mode entries.

## Requirement 5 — Safety and verification

**User Story:** As a user, I want both behaviors to protect my files under failures and concurrent changes, so that convenience never causes silent loss.

### Acceptance Criteria

5.1 Both modes SHALL retain the existing content detection, provider allowlist, independent validation, source identity/hash recheck, authorized-root containment, and no-network guarantees.

5.2 The transaction journal SHALL distinguish copy-mode publication stages from replace-mode commit stages so startup recovery never infers a destructive action from an ambiguous filesystem state.

5.3 Automated fault injection SHALL exercise every journal and filesystem boundary in both modes and demonstrate exact source-byte preservation across all injected failures.

5.4 Tests SHALL cover first-run defaulting, persistence, unknown-value fallback, future-job-only setting changes, pre-rename-path conflicts, concurrent source changes, both undo behaviors, history clearing, backup quota accounting, and recovery after interruption between the two copy-mode publications.

5.5 A Finder-path smoke test SHALL demonstrate that renaming a supported fixture produces two visible files in copy mode and one visible converted file plus an undoable retained original in replace mode.

## Success criteria

- Copy mode is the observed default when no valid preference exists.
- A successful copy-mode rename leaves two user-visible files: exact original bytes under the original extension and validated converted bytes under the requested extension.
- A successful replace-mode rename preserves the existing single-visible-file and retained-backup behavior.
- No tested conflict, crash boundary, provider failure, or setting transition silently overwrites or loses the only exact original bytes.
- Undo and history clearing perform only the mode-specific actions defined above.
