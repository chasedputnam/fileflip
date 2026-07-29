# Design — Conversion output mode

Approved by: Product owner
Date: 2026-07-28
Status: approved

#[[file:requirements.md]]
#[[file:../macos-extension-converter/design.md]]

## 1. Overview

Add a transaction-scoped `ConversionBehavior` with a safe fresh-preference default:

```swift
public enum ConversionBehavior: String, Codable, CaseIterable, Sendable {
    case keepOriginal
    case replaceWithBackup
}
```

`keepOriginal` converts an extension rename from `name.source` to `name.target` into two visible files: the exact staged source is published back to `name.source`, then validated output replaces the still-original bytes at `name.target`. `replaceWithBackup` keeps the existing one-visible-file transaction and retained private backup.

The mode is captured in `TransactionRequest` and `conversion_job`; no running or historical transaction consults mutable settings. Existing journal rows migrate to `replaceWithBackup`, while absence of a user preference decodes to `keepOriginal`. This intentionally separates historical truth from the new default.

## 2. Data and configuration

### 2.1 Settings

Add `conversionBehavior` to `FutureJobDefaults`. Use explicit `Codable` decoding so missing or unknown behavior values resolve to `.keepOriginal` while all existing format policies preserve their current migration behavior. The existing `futureJobDefaults` local preference remains the single persisted settings record and `saveDefaults` remains the write path.

The General settings tab displays a **Conversion behavior** picker before Monitoring. The explanatory text is derived from the selected enum, not duplicated persisted strings:

- **Keep original and create converted copy:** restores the original filename and creates the requested conversion beside it; both visible files use disk space.
- **Replace file and keep recoverable backup:** keeps one visible file; the original is retained privately until backup limits prune it.

The engine receives the updated defaults actor-isolated. `handle(_:)` reads one immutable defaults snapshot, derives the format policy and behavior from that same snapshot, and constructs the request. This prevents a setting change between policy and behavior capture.

Addresses Requirements 1.1–1.5.

### 2.2 Journal migration

Bump SQLite `PRAGMA user_version` and add:

```sql
ALTER TABLE conversion_job
ADD COLUMN conversion_behavior TEXT NOT NULL DEFAULT 'replaceWithBackup';
```

Migration rules:

1. Rows created before the migration remain `replaceWithBackup` because that is the only behavior the old executable could have performed.
2. New inserts always bind an explicit behavior.
3. Reads reject unknown database values as corrupt rows; they never reinterpret an unknown transaction as copy mode.
4. User preference absence or an unknown preference value defaults to `keepOriginal`, because preferences choose future behavior and may safely fail to the non-replacing option.

`JournalJob`, history projections, UI-test fixtures, and test helpers carry the behavior. History details show **Created converted copy** or **Replaced file; original retained**.

Addresses Requirements 4.1 and 4.6.

## 3. Transaction architecture

### 3.1 Shared preparation

Both modes retain the existing flow through detection, capability selection, stability sampling, canonical root containment, staging, source hashing, conversion, and independent validation. The coordinator also records original `FileMetadata` before conversion.

After validation, it canonicalizes both parent directories beneath the authorized root and calculates:

- `original = root / oldRelativePath`
- `target = root / newRelativePath`
- `originalSibling = original.parent / .fileconvert-<job>-original.tmp`
- `outputSibling = target.parent / .fileconvert-<job>-output.tmp`

Temporary names remain excluded by the watcher. Space preflight reserves source-copy bytes, bounded output bytes, and the existing safety reserve in either mode. Every prepared sibling is flushed before a journal state authorizes publication.

### 3.2 Replace mode

`replaceWithBackup` follows the current state path:

```text
staged → backedUp → converting → validating → readyToCommit → committing → succeeded
```

The exact staged source is cloned/copied into the private backup store, hashed, flushed, journaled, and only then may provider conversion begin. The validated output sibling atomically replaces `target`. Existing retention and restore behavior remains intact.

Addresses Requirements 3.1–3.4.

### 3.3 Copy mode publication

`keepOriginal` does not insert a `backup` row. It converts directly after the durable staged-source state, then prepares both siblings. Add two persistent states:

```swift
case publishingOriginal
case publishingConverted
```

Publication order:

1. Re-read `target`; require its identity and hash to match the stabilized source.
2. Require `original` to be absent using `lstat`, not a symlink-following existence check.
3. Clone/copy the staged source to `originalSibling`; apply original metadata, verify `sourceHash`, and flush it and its parent.
4. Copy validated output to `outputSibling`; apply target-applicable metadata, verify `outputHash`, and flush it and its parent.
5. Transition `readyToCommit → publishingOriginal`.
6. Publish `originalSibling → original` with `renameatx_np(..., RENAME_EXCL)`. This operation must fail rather than overwrite a path created after preflight. Flush `original.parent`.
7. Transition `publishingOriginal → publishingConverted`.
8. Recheck that `original` has `sourceHash` and `target` still has the original identity and `sourceHash`.
9. Atomically rename `outputSibling → target`, flush `target.parent`, and transition to `succeeded`.

Publishing the visible original first makes every non-ambiguous interruption preserve at least one exact visible source. The target does not change until validated output and a flushed original are available. The transaction actor's catch path must not collapse either publication state to `failed`; recovery owns those states.

Addresses Requirements 2.1–2.8 and 5.1–5.2.

### 3.4 Conflict behavior

Copy mode fails without publication when:

- `original` exists at either preflight or exclusive rename;
- either parent escapes the authorized root or is not on the expected volume;
- `target` identity or hash changed;
- a prepared sibling does not match its journaled hash;
- space, metadata, flush, conversion, or validation fails.

If the exclusive original publish loses a race, the coordinator removes only its private sibling, leaves both user paths untouched, and records `destinationExists`. It never chooses a suffix automatically because that would break the user's explicit rename intent.

## 4. Recovery state table

Startup reconciliation uses the mode, state, journaled hashes, and all four paths. It may mutate user paths only for a row in a publication state and only when the following exact cases match:

| Mode/state | `original` | `target` | Prepared output | Recovery |
|---|---|---|---|---|
| copy / `publishingOriginal` | absent | source | valid output | publish prepared original exclusively, then continue |
| copy / `publishingOriginal` | source | source | valid output | continue to converted publication |
| copy / either publish state | source | output | any | mark succeeded; remove private siblings |
| copy / `publishingConverted` | source | source | valid output | atomically publish output, then mark succeeded |
| copy / either publish state | any other combination | any other combination | any | mark `needsRecovery`; preserve every artifact and user path |
| replace / `committing` | n/a | output | any | mark succeeded |
| replace / `committing` | n/a | source | any | remove private output and mark failed |
| replace / `committing` | n/a | other/missing | any | mark `needsRecovery` |

A source-hash match alone is insufficient when a required path identity or root-containment check is unavailable. Recovery is idempotent; repeating it reaches the same terminal state without overwriting an existing `original` path.

Addresses Requirements 2.7, 3.4, 5.2, and 5.3.

## 5. History, undo, and clearing

### 5.1 Availability

History availability becomes mode-specific:

- replace mode is undoable when a verified backup exists and `target` is available;
- copy mode is undoable when `original` matches `sourceHash` and `target` matches `outputHash`.

The one-second snapshot refresh may compute these facts off the main actor. Details show both relative paths for copy mode and the retained-original expiry for replace mode.

### 5.2 Copy-mode undo

Copy undo removes only the committed converted output:

1. Verify authorized-root containment.
2. Verify `original` identity/hash equals the committed source and `target` identity/hash equals the committed output.
3. Atomically move `target` to a private, same-volume quarantine name.
4. Hash and identity-check the quarantined file again. If it differs, restore it exclusively when possible and report a conflict; never delete it.
5. Flush the parent, delete the verified quarantine file, and return an undo result that names the unchanged original.

This quarantine sequence narrows path races and ensures deletion applies only to bytes proven to be the committed output. Copy mode does not offer restore-to-new-file because no private original exists; conflicts preserve both visible files.

Replace undo and restore-to-new-file remain unchanged.

### 5.3 Clear history

Clearing history deletes journal rows and private job artifacts only. For copy rows it never touches `original` or `target`. The warning changes to state that visible files are never deleted and only retained replace-mode originals lose undo availability.

Addresses Requirements 4.2–4.5.

## 6. UI and accessibility

- Add the behavior picker to General Settings with stable identifier `settings.conversion-behavior`.
- Expose mode-specific history labels and VoiceOver values; do not rely on icons or color.
- The menu-bar success row says **Created <target> and kept <source>** in copy mode or **Converted <target> — Undo** in replace mode.
- A destination conflict is actionable and names only sanitized filenames, never full paths outside existing authorized-folder disclosure.
- Changing the picker updates state immediately, persists through the existing debounced defaults writer, and does not interrupt active work.

## 7. Verification strategy

### Unit tests

- `FutureJobDefaults` round trips both values; missing and unknown preference values choose copy mode.
- Journal migration assigns old rows replace mode; new rows round trip explicit modes; unknown row values fail closed.
- State-transition tests allow only the mode-valid backup/publication paths.
- History availability and labels are correct for each mode.
- Copy undo rejects changed/missing originals and outputs and never deletes an unverified file.

### Integration and fault injection

Run the real APFS transaction suite for both modes. For copy mode, inject failure after every stage, sibling copy, flush, journal transition, exclusive original rename, output rename, and terminal journal write. At each boundary assert:

- at least one user-visible path has exact `sourceHash` bytes;
- no pre-existing `original` path is overwritten;
- successful recovery yields source at `original` and validated output at `target`;
- ambiguous recovery preserves all files and enters `needsRecovery`;
- no successful copy row has a retained backup or contributes to backup usage.

Retain the existing complete replace-mode fault matrix unchanged.

### UI and smoke evidence

UI tests cover the default selection, persistence after relaunch, explanatory copy, history mode labels, and conflict-safe undo state. A Finder-path smoke run executes the same fixture in both modes and independently hashes/opens every visible result.

Pre-agreed invariant: every injected failure preserves exact original bytes; zero destructive outcomes are acceptable.

## 8. Requirement traceability

| Requirement | Design sections |
|---|---|
| 1.1–1.5 | 2.1, 6 |
| 2.1–2.8 | 3.1, 3.3, 3.4, 4 |
| 3.1–3.4 | 3.2, 4 |
| 4.1–4.6 | 2.2, 5, 6 |
| 5.1–5.5 | 3, 4, 7 |
