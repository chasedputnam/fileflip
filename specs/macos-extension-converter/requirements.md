# Requirements — macOS-extension-converter

Approved by: Chase Putnam  Date: 2026-07-28  Status: approved

## Introduction

Changing a filename extension in Finder does not convert the file's contents, forcing Mac users to open a dedicated editor or trust an online converter for a routine task. This application makes the rename itself the conversion command while keeping all file contents on the Mac. It runs unobtrusively from the menu bar, watches only folders the user authorizes, detects the file's real format, and safely converts supported mismatches to the requested format.

The MVP targets broad, Consul-like local coverage: common images, audio, video, office documents, text documents, and spreadsheets. Because these families have different fidelity limits, the application exposes an explicit source-to-target capability matrix and refuses ambiguous conversions instead of treating every pair of extensions as interchangeable.

## Scope priorities

### Must have (MVP)

- Native macOS menu-bar application for macOS 14 or later.
- User-authorized folder monitoring, with Desktop and Downloads suggested during onboarding.
- Automatic conversion after an extension-only rename when actual content and requested format differ.
- Local conversion for the baseline image, audio, video, document, and spreadsheet pairs defined by Requirement 3.
- Non-destructive conversion, bounded history, undo, visible status, and actionable failure reporting.
- Pause/resume monitoring and launch-at-login preference.

### Should have (post-MVP)

- Advanced per-format presets beyond the baseline quality, codec, metadata, page, and sheet policies required for safe conversion.
- Additional watched folders and per-folder enable/disable controls.
- Finder notifications and a richer conversion history browser.

### Nice to have

- Archive and ebook conversion through additional local providers.
- Batch rules, custom presets, Finder Quick Actions, and drag-and-drop conversion.
- Automatic updates and signed/notarized direct distribution.

## Out of scope for the MVP

- Cloud conversion, uploads, accounts, analytics, or network-dependent operation.
- Archive, ebook, presentation, project-file, executable, encrypted-document, DRM-protected-media, and professional RAW conversion.
- Editing file contents beyond format encoding and the selected metadata policy.
- Watching the entire startup disk by default.
- Inferring that every rename is an instruction to convert when source detection is uncertain.
- Replacing professional color-management, RAW-development, document-layout, or media-transcoding tools.
- Mac App Store distribution; sandbox and review constraints will be evaluated after the direct-distribution MVP.

## Requirements

### Requirement 1 — Onboarding and folder authorization

**User Story:** As a Mac user, I want to choose exactly which folders the application watches, so that it can automate conversions without receiving unnecessary file access.

#### Acceptance Criteria

1.1 WHEN the application is launched for the first time THEN the application SHALL explain the rename-to-convert behavior and request the user to select one or more folders.

1.2 WHEN the user selects a folder through the system folder picker THEN the application SHALL begin monitoring that folder and retain access across application restarts, subject to macOS permission controls.

1.3 The application SHALL monitor only folders the user explicitly authorized.

1.4 WHEN macOS revokes or denies access to a watched folder THEN the application SHALL stop monitoring that folder, preserve all files unchanged, and identify the folder and recovery action in the UI.

1.5 WHEN a watched folder is removed in settings THEN the application SHALL stop responding to subsequent events in that folder.

1.6 The application SHALL support macOS 14 and later on Apple Silicon Macs. Intel Macs are outside the supported platform contract.

### Requirement 2 — Rename detection and conversion eligibility

**User Story:** As a user, I want an extension change to trigger conversion only when it represents a supported format change, so that ordinary file operations are not modified unexpectedly.

#### Acceptance Criteria

2.1 WHEN a regular file inside an enabled watched folder is renamed with a different extension THEN the application SHALL inspect the file contents to determine the source format rather than trusting the previous or current extension.

2.2 WHEN the detected source format differs from the requested extension and the conversion pair is supported THEN the application SHALL enqueue exactly one conversion for that file event.

2.3 WHEN the detected source format already matches the requested extension THEN the application SHALL leave the file unchanged and SHALL NOT create a history entry.

2.4 IF the source format cannot be identified with sufficient confidence THEN the application SHALL leave the file bytes unchanged and report that no conversion was performed.

2.5 IF the requested extension is unsupported or the source-to-target pair is unavailable on the running Mac THEN the application SHALL leave the file bytes unchanged and report the unsupported pair.

2.6 WHEN a directory, symbolic link, package, hidden temporary file, or application-generated working file is renamed THEN the application SHALL NOT convert it.

2.7 WHEN multiple filesystem events describe the same rename THEN the application SHALL perform at most one conversion for the resulting file identity and requested format.

2.8 WHEN a file remains open for writing or changes during eligibility inspection THEN the application SHALL wait for it to become stable before conversion or fail safely without modifying it.

### Requirement 3 — MVP format coverage and fidelity

**User Story:** As a user, I want common images, media, documents, and spreadsheets converted locally, so that I can complete routine format changes without another application or online service.

#### Acceptance Criteria

3.1 WHEN an eligible still-image conversion is requested among JPEG/JPG, PNG, HEIC/HEIF, TIFF, and WebP THEN the application SHALL produce a file whose contents conform to the requested format when the running Mac can decode and encode the pair.

3.2 WHEN an eligible audio conversion is requested among MP3, M4A/AAC, WAV, AIFF, FLAC, OGG, and Opus THEN the application SHALL produce playable audio in the requested container and a documented compatible default codec.

3.3 WHEN an eligible video conversion is requested among MP4/M4V, MOV, MKV, and WebM THEN the application SHALL produce playable video in the requested container using a documented compatible default video and audio codec combination.

3.4 The application SHALL support at minimum DOCX to or from ODT, DOCX/ODT/RTF to PDF, DOCX/ODT/RTF to TXT or HTML, Markdown to or from HTML, and Markdown to PDF.

3.5 The application SHALL support at minimum XLSX to or from ODS, CSV to XLSX or ODS, and XLSX/ODS to CSV after a default or user-selected sheet is identified.

3.6 The application SHALL support PDF pages to PNG or JPEG and SHALL support PDF to TXT only when extractable text exists; it SHALL NOT claim semantic document reconstruction from PDF.

3.7 The application SHALL expose only explicitly tested source-to-target pairs and SHALL NOT imply that every listed extension can convert to every other listed extension.

3.8 WHEN a source contains multiple images, pages, media streams, chapters, tracks, worksheets, or other structures the target cannot preserve THEN the application SHALL apply an explicit configured selection or flattening policy; if no unambiguous policy exists, it SHALL leave the file unchanged and request a choice.

3.9 WHEN a target format cannot represent a source feature such as image transparency, animation, embedded fonts, formulas, comments, hyperlinks, subtitles, chapters, or multiple audio tracks THEN the application SHALL disclose the expected loss and require an applicable configured policy before conversion.

3.10 WHEN an image conversion succeeds THEN the output SHALL preserve pixel dimensions, color profile where representable, transparency where representable, and rendered orientation unless the user configured a transform.

3.11 WHEN an audio or video conversion succeeds THEN the output SHALL preserve duration within codec tolerance and SHALL preserve the selected media streams without unintended truncation.

3.12 WHEN a document or spreadsheet conversion succeeds THEN the output SHALL preserve readable content and supported structure; the application SHALL report any provider-detected fidelity warning rather than presenting the result as lossless.

3.13 The application SHALL perform every conversion without uploading file contents or metadata and without requiring a network connection.

3.14 WHEN no custom settings exist for a supported pair THEN the application SHALL use documented defaults that prioritize compatibility and fidelity over minimum file size.

3.15 IF the required local conversion provider is not installed, cannot be verified, or is incompatible with the running Mac THEN the application SHALL mark its pairs unavailable and SHALL NOT modify the file.

### Requirement 4 — Non-destructive replacement and undo

**User Story:** As a user, I want conversions to be recoverable, so that a failed or unwanted conversion never destroys my original file.

#### Acceptance Criteria

4.1 WHEN conversion begins THEN the application SHALL preserve a recoverable copy of the exact pre-conversion bytes before replacing the renamed file.

4.2 WHEN conversion output has been produced THEN the application SHALL validate that the output is readable as the requested format before replacing the renamed file.

4.3 IF conversion, validation, backup creation, or final replacement fails THEN the application SHALL leave or restore the pre-conversion bytes at the user-visible path and report the failure.

4.4 WHEN final replacement succeeds THEN the application SHALL preserve the user-visible filename, requested extension, and applicable filesystem metadata, except metadata the user explicitly configured the application to remove.

4.5 WHEN the user selects Undo for a retained history entry THEN the application SHALL restore the exact pre-conversion bytes and the filename state that existed before the triggering extension change.

4.6 IF Undo would overwrite a file that changed after conversion THEN the application SHALL refuse automatic overwrite and offer a non-destructive restore-to-new-file action.

4.7 The application SHALL retain backups under a documented size or age limit, SHALL show the active retention policy, and SHALL never remove the only user-visible copy of a file while pruning history.

4.8 WHEN the application terminates unexpectedly during conversion THEN the application SHALL reconcile temporary files and recover the original or validated output on next launch without leaving a silently corrupted user-visible file.

### Requirement 5 — Menu-bar controls and feedback

**User Story:** As a user, I want conversion controls and status available without a persistent window, so that automation stays unobtrusive but understandable.

#### Acceptance Criteria

5.1 WHILE the application is running THEN the application SHALL provide a menu-bar item showing whether monitoring is active, paused, or blocked by an error.

5.2 WHEN the user pauses monitoring THEN the application SHALL stop enqueuing new conversions while allowing any conversion already in final replacement to complete safely.

5.3 WHEN the user resumes monitoring THEN the application SHALL process only new rename events and SHALL NOT reinterpret every existing file in watched folders.

5.4 WHEN a conversion starts, succeeds, fails, or is skipped for a user-actionable reason THEN the application SHALL expose that state in the menu-bar UI without requiring Console.app.

5.5 WHEN a conversion fails or requires a policy choice THEN the application SHALL provide a notification or menu-bar indication that identifies the file, reason, and safe next action without exposing sensitive file contents.

5.6 WHEN the user opens settings THEN the application SHALL allow watched-folder management, monitoring pause/resume, backup retention, launch-at-login, supported-pair inspection, and default conversion policies to be viewed or changed.

5.7 WHEN launch at login is enabled THEN the application SHALL start after the user signs in and restore monitoring for folders whose authorization remains valid.

### Requirement 6 — History, privacy, and local data

**User Story:** As a privacy-conscious user, I want a local audit trail with minimal retained data, so that I can understand and reverse conversions without leaking file information.

#### Acceptance Criteria

6.1 WHEN a conversion succeeds or fails after work begins THEN the application SHALL record a local history entry containing timestamp, source format, requested format, outcome, and the information required to locate or restore the file.

6.2 The application SHALL store preferences, history, temporary files, and backups only in appropriate local macOS application storage locations.

6.3 The application SHALL NOT transmit filenames, paths, file contents, conversion history, or usage events to any external service.

6.4 WHEN the user clears history THEN the application SHALL remove history records and associated retained backups after warning that those conversions can no longer be undone.

6.5 WHEN a retained file or folder is no longer accessible THEN the application SHALL show the history entry as unavailable rather than recreating, moving, or deleting unrelated files.

6.6 The application SHALL avoid writing full file paths or file contents to general-purpose system logs.

### Requirement 7 — Reliability and resource behavior

**User Story:** As a user, I want the background utility to remain responsive and conservative, so that it does not disrupt normal Finder use or consume excessive resources.

#### Acceptance Criteria

7.1 WHEN several eligible renames occur close together THEN the application SHALL queue them, limit concurrent conversions, and keep menu-bar controls responsive.

7.2 WHEN the same file is renamed again before its queued conversion starts THEN the application SHALL evaluate the latest stable filename and perform no obsolete conversion.

7.3 WHEN a file is moved outside all watched folders before conversion begins THEN the application SHALL cancel the queued conversion and leave the file unchanged.

7.4 WHEN available disk space is insufficient for both backup and conversion output THEN the application SHALL refuse the conversion before replacing any user-visible bytes and report the required recovery action.

7.5 WHILE idle with no filesystem events THEN the application SHALL perform no file-content scanning and SHALL maintain negligible sustained CPU use.

7.6 WHEN the application restarts THEN the application SHALL restore preferences and valid watched-folder access, reconcile interrupted work, and avoid replaying completed events.

7.7 IF two application instances attempt to monitor the same configuration THEN the application SHALL allow only one instance to perform conversions.

### Requirement 8 — Extensible conversion support

**User Story:** As a maintainer, I want format conversion capabilities isolated behind a stable contract, so that format support can evolve without weakening file safety.

#### Acceptance Criteria

8.1 The application SHALL represent supported source-to-target pairs as discoverable capabilities rather than assuming that matching filename extensions imply convertibility.

8.2 WHEN a conversion provider is added or upgraded THEN it SHALL use the same eligibility, backup, validation, atomic replacement, history, privacy, and cancellation behavior as every other provider.

8.3 IF a conversion provider is unavailable, incompatible, or fails validation THEN the application SHALL disable its affected conversion pairs and preserve the source file unchanged.

8.4 The application SHALL expose the currently supported conversion pairs and any format-specific limitations in settings.

## Success criteria

- In acceptance testing, every advertised source-to-target pair converts representative fixtures to files independently recognized and opened as the requested format, not merely renamed.
- Fault injection at each backup, encode, validate, and replacement boundary never loses the original fixture bytes.
- Replayed and duplicate rename events produce no duplicate conversions.
- No network request occurs during onboarding, monitoring, conversion, history, or undo workflows.
- A new user can authorize a folder, rename one supported file from each enabled format family, observe completion, and undo each conversion without opening documentation.
