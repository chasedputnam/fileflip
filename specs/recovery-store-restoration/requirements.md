# Requirements — Recovery Store Restoration

Approved by: Chase Putnam  Date: 2026-07-29  Status: approved

## Introduction

When FileFlip cannot safely finish or reverse a replacement conversion, it preserves recoverable file data in its private recovery store and marks the conversion as requiring recovery. Conversion History explains that recovery is required, but it does not currently provide a direct action for returning the retained file to a user-accessible location. The recovery-required menu-bar state therefore persists across launches without giving the user a complete way to resolve it. This feature gives the user a safe, explicit restoration workflow and makes the persistent recovery indicator reflect whether unresolved recovery items actually remain.

## Scope priorities

### Must have

- Restore a verified retained file from a recovery-required history item to a user-selected location without overwriting any existing file.
- Preserve the current visible file and the private recovery artifact until restoration is durably complete.
- Mark a recovery item resolved after successful restoration and clear the recovery-required menu-bar state only when no unresolved recovery items remain.
- Keep unresolved recovery state across application relaunches.
- Explain and safely handle missing, corrupt, inaccessible, or conflicting recovery data.

### Should have

- Suggest a recognizable restored filename and the original file's authorized folder when available.
- Allow a user who completed recovery outside FileFlip to explicitly mark an item resolved after a warning and confirmation.

### Nice to have

- Reveal the restored file in Finder after a successful restore.

## Out of scope

- Browsing or editing FileFlip's private recovery directory directly in Finder.
- Reconstructing a file when no complete, hash-verified retained artifact exists.
- Automatically choosing one version when the current file and retained file differ.
- Restoring multiple recovery items in one batch.
- Changing the existing conversion backup-retention policy except where necessary to protect unresolved recovery artifacts.

## Requirements

### Requirement 1 — Discoverable recovery action

**User Story:** As a FileFlip user, I want a recovery-required history item to provide a clear restoration action, so that I can regain access to the retained file without locating FileFlip's private storage.

#### Acceptance Criteria

1.1 WHEN the user opens a Conversion History item whose outcome is `Recovery required` and a restorable artifact is available THEN FileFlip SHALL present a `Restore Retained File…` action.

1.2 WHEN FileFlip presents the restoration action THEN FileFlip SHALL identify the affected filename, explain that the current visible file will not be overwritten, and explain that the user must choose a destination.

1.3 WHEN the user begins restoration THEN FileFlip SHALL present a standard macOS save interface with a suggested filename that distinguishes the restored file from an existing file.

1.4 IF the original authorized folder remains accessible THEN FileFlip SHALL initially suggest that folder as the restoration destination.

1.5 IF the user cancels destination selection THEN FileFlip SHALL leave the recovery item, retained artifact, current visible file, and menu-bar recovery state unchanged.

1.6 FileFlip SHALL present recovery state and recovery actions only for history jobs whose recorded conversion behavior is `Replace File and Keep Recoverable Backup`. Changing the current default after a job is created SHALL NOT hide or disable recovery for that existing eligible job, and jobs recorded with `Keep Original and Create Converted Copy` SHALL NOT present recovery UI.

### Requirement 2 — Safe and exact restoration

**User Story:** As a FileFlip user, I want restoration to preserve both versions and verify the retained data, so that recovery cannot destroy or silently corrupt a file.

#### Acceptance Criteria

2.1 WHEN restoration succeeds THEN FileFlip SHALL create a regular file at the selected destination whose bytes exactly match the verified retained artifact.

2.2 WHILE restoration is in progress FileFlip SHALL leave the current visible file unchanged.

2.3 IF a file or filesystem object already exists at the selected destination THEN FileFlip SHALL refuse to overwrite it, preserve all existing data, and let the user choose another destination.

2.4 IF the retained artifact is missing, is not a regular file, fails its recorded integrity check, or cannot be read THEN FileFlip SHALL refuse restoration, leave existing files unchanged, keep the item unresolved, and show an actionable error.

2.5 IF FileFlip cannot durably publish the restored file at the selected destination THEN FileFlip SHALL remove any private incomplete output when safe, leave the retained artifact available, keep the item unresolved, and show an actionable error.

2.6 WHEN FileFlip reports restoration success THEN the restored file SHALL already be durably published at the selected destination.

2.7 The restoration workflow SHALL NOT expose the private recovery-store path in user-visible messages, notifications, logs intended for support export, or accessibility text.

### Requirement 3 — Recovery lifecycle and menu-bar state

**User Story:** As a FileFlip user, I want recovery status to remain visible only while action is still required, so that the menu-bar icon is trustworthy across launches.

#### Acceptance Criteria

3.1 WHILE at least one unresolved recovery-required history item exists THEN FileFlip SHALL show the recovery-required medical-bag menu-bar icon, including after quitting and reopening the application.

3.2 WHEN a retained file is restored successfully THEN FileFlip SHALL mark that recovery item resolved without deleting or rewriting the restored destination.

3.3 WHEN the last unresolved recovery item becomes resolved THEN FileFlip SHALL replace the recovery-required menu-bar state with the status implied by current monitoring health and active conversion state without requiring an application restart.

3.4 WHEN one recovery item is resolved while another unresolved recovery item remains THEN FileFlip SHALL continue showing the recovery-required menu-bar icon and SHALL identify an unresolved item in its status detail.

3.5 WHEN the application is relaunched THEN FileFlip SHALL derive the recovery-required menu-bar state from persisted unresolved recovery items rather than from a prior session-only icon value.

3.6 WHEN a resolved recovery item is displayed in Conversion History THEN FileFlip SHALL distinguish it from an item that still requires action and SHALL show the restoration destination filename or a privacy-preserving success summary.

3.7 IF recording the recovery item as resolved fails after the restored file is durably published THEN FileFlip SHALL preserve both the restored file and retained artifact, continue showing the item as unresolved, and explain that the file was restored but recovery status could not be updated.

### Requirement 4 — Manual resolution

**User Story:** As a FileFlip user who recovered a file by another method, I want to acknowledge that no further FileFlip recovery action is needed, so that an unavailable or externally handled item does not keep the application in recovery-required status forever.

#### Acceptance Criteria

4.1 WHEN an unresolved recovery item is shown THEN FileFlip SHALL provide a secondary `Mark as Resolved…` action regardless of whether its retained artifact is currently available.

4.2 WHEN the user selects `Mark as Resolved…` THEN FileFlip SHALL require confirmation that FileFlip will stop warning about the item and that this action does not restore a file.

4.3 IF the user cancels the confirmation THEN FileFlip SHALL leave the item and menu-bar recovery state unchanged.

4.4 WHEN the user confirms manual resolution THEN FileFlip SHALL persist the item as resolved and recalculate the menu-bar state immediately.

4.5 IF persisting manual resolution fails THEN FileFlip SHALL keep the item unresolved and show an actionable error.

4.6 WHEN an item is manually resolved THEN FileFlip SHALL retain an auditable history indication that the user resolved it without restoring through FileFlip.

### Requirement 5 — Retention and user feedback

**User Story:** As a FileFlip user, I want unresolved recovery data protected and restoration outcomes clearly communicated, so that cleanup cannot silently remove the only recoverable copy.

#### Acceptance Criteria

5.1 WHILE a recovery item remains unresolved FileFlip SHALL exclude its retained artifact from automatic age-based and size-based cleanup.

5.2 WHEN a recovery item is resolved through successful restoration or explicit manual resolution THEN FileFlip SHALL apply the configured retention policy to its private retained artifact.

5.3 WHEN restoration succeeds THEN FileFlip SHALL show an in-app success confirmation that identifies the restored filename without exposing its full path.

5.4 WHEN restoration succeeds THEN FileFlip SHALL send a local notification, subject to macOS notification permission, stating that the retained file was restored and identifying the restored filename without exposing its full path.

5.5 WHEN restoration fails THEN FileFlip SHALL show an in-app error that distinguishes destination conflict, unavailable recovery data, integrity failure, permission failure, and durable-publication failure.

5.6 WHEN the user selects a recovery-required notification or opens the recovery-required status detail THEN FileFlip SHALL provide a direct path to the unresolved Conversion History item.

## Success criteria

- A user can restore an exact retained file from a recovery-required history item without changing or overwriting the current visible file.
- Recovery-required state survives relaunch while unresolved and clears immediately after the final item is successfully restored or explicitly resolved.
- Unresolved retained artifacts are never removed by automatic retention cleanup.
- Every failed restore leaves existing user files unchanged and keeps another recovery attempt possible when the retained artifact is still valid.
