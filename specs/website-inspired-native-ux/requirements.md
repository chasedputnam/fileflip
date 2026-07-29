# Requirements Document

## Introduction

FileFlip’s menu-bar interface should use the calm, compact visual language shown in the website graphics while remaining a native, accessible macOS experience. Conversion completion feedback must be delivered through macOS User Notifications rather than through a custom notification card, toast, or banner inside FileFlip. The user problem is inconsistent visual identity and ambiguous feedback placement: the product site promises a polished, glanceable workflow, while the application should make conversion outcomes visible at the system level without cluttering the tool UI.

Reference graphics:

- `/Users/chase.putnam/Desktop/Screenshot 2026-07-29 at 8.07.33 PM.png`
- `/Users/chase.putnam/Desktop/Screenshot 2026-07-29 at 8.07.16 PM.png`

## Scope Priorities

### Must have

- Restyle the menu-bar popover to match the website graphic’s hierarchy, spacing, color roles, rounded icon treatments, dividers, and activity rows.
- Deliver conversion success and failure messages through the macOS User Notifications API.
- Do not display conversion success or failure as custom in-app notification UI.
- Preserve native macOS accessibility, appearance adaptation, monitoring controls, history navigation, settings navigation, and recovery behavior.

### Should have

- Structure notification content like the reference: concise outcome title followed by source format, target format, and elapsed conversion time when available.
- Provide system notification actions appropriate to the outcome without imitating system chrome inside the application.

### Nice to have

- Subtle state-change animation when allowed by Reduce Motion.

## Requirements

### Requirement 1: Website-aligned menu-bar styling

**User Story:** As a FileFlip user, I want the menu-bar interface to resemble the product website, so that the installed application feels consistent, polished, and easy to scan.

#### Acceptance Criteria

1. WHEN the menu-bar popover opens with authorized folders THEN FileFlip SHALL present a status header containing a state indicator, a prominent status title, a watched-folder summary, and a compact pause-or-resume control.
2. WHEN recent conversion activity exists THEN FileFlip SHALL present each item as a full-width row containing a rounded state icon tile, filename, source-to-target format summary, relative time or outcome context, and navigation affordance.
3. WHEN the popover presents sections THEN FileFlip SHALL separate the status, recent activity, and navigation areas with subtle full-width dividers.
4. WHEN the popover presents section labels THEN FileFlip SHALL use a restrained uppercase secondary label for recent activity.
5. WHEN FileFlip presents success, in-progress, warning, failure, blocked, choice-required, or recovery-required states THEN FileFlip SHALL use a distinct semantic color and SF Symbol treatment without relying on color alone.
6. WHEN FileFlip presents the menu-bar popover THEN FileFlip SHALL use native typography, a warm neutral surface, dark neutral primary text, muted secondary text, mint success accents, and coral-or-orange warning accents that visually correspond to the reference graphic.
7. WHEN the menu-bar popover is resized by its content THEN FileFlip SHALL preserve readable labels, prevent row content from clipping, and keep primary controls reachable within the existing compact menu-bar interaction.
8. IF no folder is authorized or no recent activity exists THEN FileFlip SHALL preserve an actionable native empty state consistent with the updated visual system.
9. WHEN the user selects a recent activity row THEN FileFlip SHALL open Conversion History with that item selected.
10. WHEN the user selects History, Settings, Quit, pause, resume, folder authorization, or recovery actions THEN FileFlip SHALL preserve the existing behavior.

### Requirement 2: Native macOS adaptation and accessibility

**User Story:** As a macOS user, I want the refreshed interface to respect my system settings, so that visual polish does not reduce usability.

#### Acceptance Criteria

1. WHEN macOS uses Light Mode or Dark Mode THEN FileFlip SHALL maintain legible foreground-background contrast and recognizable semantic states.
2. IF Increase Contrast or Reduce Transparency is enabled THEN FileFlip SHALL retain visible boundaries and readable content without depending on translucent material.
3. IF Reduce Motion is enabled THEN FileFlip SHALL suppress nonessential state-change animation.
4. WHEN VoiceOver traverses the popover THEN FileFlip SHALL expose meaningful status, activity-row, and control labels in a logical reading order.
5. WHEN keyboard navigation is used THEN FileFlip SHALL keep all existing actions focusable and preserve the documented keyboard shortcuts.
6. WHEN a state is represented by color or an icon THEN FileFlip SHALL also expose that state through visible text or an accessibility label.

### Requirement 3: System-level conversion notifications

**User Story:** As a FileFlip user, I want conversion outcomes delivered by macOS, so that I can understand what happened even when the menu-bar popover is closed.

#### Acceptance Criteria

1. WHEN a conversion transitions to succeeded after FileFlip has started observing it THEN FileFlip SHALL submit a local notification through `UNUserNotificationCenter`.
2. WHEN a conversion transitions to failed after FileFlip has started observing it THEN FileFlip SHALL submit a local notification through `UNUserNotificationCenter`.
3. WHEN FileFlip submits a success notification THEN the notification SHALL use the title “Conversion complete” and identify the source and target formats in concise secondary content.
4. WHEN FileFlip submits a failure notification THEN the notification SHALL use the title “Conversion failed” and identify the affected filename plus the safe next action in concise secondary content.
5. IF elapsed conversion duration is available from authoritative job timestamps THEN FileFlip SHALL include a human-readable duration in the success notification’s secondary content.
6. WHEN FileFlip submits an outcome notification THEN FileFlip SHALL assign a stable category, thread identifier, sound, and history-item identifier suitable for system grouping and response routing.
7. WHEN the user opens a success or failure notification THEN FileFlip SHALL activate and open Conversion History with the corresponding item selected.
8. WHEN notification permission is denied or unavailable THEN FileFlip SHALL continue conversion and history recording without presenting a custom in-app notification substitute.
9. WHEN FileFlip launches with historical completed jobs THEN FileFlip SHALL NOT replay notifications for those historical outcomes.
10. WHEN the same job state is observed repeatedly THEN FileFlip SHALL NOT submit duplicate notifications for that unchanged outcome.
11. WHEN the operating system renders a delivered notification THEN FileFlip SHALL allow macOS to control the notification surface, app identity, placement, timing, and action presentation.
12. WHEN implementing the reference notification treatment THEN FileFlip SHALL represent its information hierarchy through notification title, subtitle, body, category, and actions rather than attempting to reproduce the website card pixel-for-pixel.

### Requirement 4: No conversion notification surface inside FileFlip

**User Story:** As a FileFlip user, I want the tool UI to remain focused on current state and history, so that system notifications do not become duplicated clutter.

#### Acceptance Criteria

1. WHEN a conversion succeeds or fails THEN FileFlip SHALL NOT present a custom toast, banner, notification card, or notification center inside the menu-bar popover, History window, onboarding window, or Settings window.
2. WHEN the menu-bar popover is open THEN FileFlip MAY continue to show persistent status and recent activity because those elements are navigation and state history rather than transient notifications.
3. WHEN an operation requires immediate user input or communicates an error from a user-initiated action THEN FileFlip MAY continue using native alerts, sheets, or confirmation dialogs.
4. WHEN notification permission is denied THEN FileFlip SHALL NOT add warning chrome to the main tool UI solely to replace the missing system notification.

### Requirement 5: Outcome correctness and privacy

**User Story:** As a FileFlip user, I want notifications and visual status to be accurate and private, so that I can trust the information shown outside the application.

#### Acceptance Criteria

1. WHEN FileFlip constructs a notification THEN FileFlip SHALL derive the outcome and formats from the persisted conversion job rather than inferred filename extensions.
2. WHEN a failed conversion restores its original filename THEN FileFlip SHALL describe the restored state accurately and SHALL NOT imply that the target conversion succeeded.
3. WHEN a job requires recovery THEN FileFlip SHALL continue to use recovery-specific system notification content and route the user to recovery actions.
4. WHEN notification content is visible outside FileFlip THEN FileFlip SHALL include only the basename and conversion metadata and SHALL NOT include authorized folder paths, bookmark data, hashes, provider command lines, or diagnostic details.
5. WHEN the latest session conversion outcome changes THEN the menu-bar status icon and status text SHALL agree with that outcome.

### Requirement 6: Verification

**User Story:** As a maintainer, I want observable regression coverage for the UX update, so that visual and notification behavior does not silently drift.

#### Acceptance Criteria

1. WHEN the implementation is complete THEN automated app-model tests SHALL verify success, failure, recovery, permission-denied, startup non-replay, same-job state transition, deduplication, notification content, and notification routing behavior.
2. WHEN the implementation is complete THEN UI automation SHALL verify the menu popover’s status header, activity rows, navigation, and absence of custom conversion notification UI.
3. WHEN the implementation is complete THEN the application SHALL be launched and exercised through representative success and failure scenarios on macOS.
4. WHEN the refreshed popover is visually inspected THEN it SHALL demonstrate the reference hierarchy and semantic color roles in both Light Mode and Dark Mode.
