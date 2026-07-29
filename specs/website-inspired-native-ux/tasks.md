# Implementation Tasks

- [x] 1. Add website-aligned adaptive visual tokens
  - Add warm surface, primary/secondary ink, semantic foreground/fill, divider, and control-fill roles in `Sources/FileConvertApp/AppDesignSystem.swift`.
  - Resolve Light/Dark appearance dynamically and retain system contrast fallbacks.
  - Add reusable semantic icon-tile presentation without replacing visible state text.
  - _Requirements: 1.5–1.6, 2.1–2.3, 2.6_

- [x] 2. Recompose the menu-bar status header
  - Move the status icon, title, watched-folder/state detail, and compact pause/resume control into one scan-friendly header in `Sources/FileConvertApp/AppViews.swift`.
  - Preserve folder authorization behavior, pause/resume behavior, keyboard shortcuts, accessibility identifiers, and logical VoiceOver order.
  - Retain an actionable native empty state when no folder is authorized.
  - _Requirements: 1.1, 1.3, 1.7–1.8, 1.10, 2.1–2.6_

- [x] 3. Restyle Recent Activity as persistent navigation
  - Use a restrained uppercase section label, full-width rows, rounded semantic state tiles, source-to-target metadata, relative time, and a navigation chevron.
  - Keep each row a native button that selects the item and opens Conversion History.
  - Preserve empty activity copy and prevent clipping in the compact popover.
  - _Requirements: 1.2–1.5, 1.7–1.9, 2.1–2.6, 4.2_

- [x] 4. Add authoritative conversion duration to app state
  - Add optional duration metadata to `HistoryItemState` in `Sources/FileConvertApp/AppViewState.swift`.
  - Derive nonnegative duration from persisted `JournalJob.createdAt` and `updatedAt` in `Sources/FileConvertApp/ConcreteApplicationRuntime.swift`.
  - Update all app and test construction sites without inferring duration from filenames or wall-clock notification time.
  - _Requirements: 3.5, 5.1_

- [x] 5. Refine native system notification content
  - In `Sources/FileConvertApp/FileConvertViewModel.swift`, use the approved success/failure title casing, source-to-target subtitle, human-readable duration when present, concise basename-only body, stable thread identifier, category, sound, request identifier, and history item metadata.
  - Keep recovery-required content distinct and redacted.
  - Preserve startup non-replay, transition-only posting, and unchanged-state deduplication.
  - Do not add any custom in-app notification fallback when authorization or posting fails.
  - _Requirements: 3.1–3.6, 3.8–3.12, 4.1, 4.4, 5.1–5.4_

- [x] 6. Register notification actions and preserve routing
  - Register `FILEFLIP_HISTORY` with a foreground `View in History` action and preserve `FILEFLIP_RECOVERY` with `Review Recovery…` in `Sources/FileConvertApp/FileConvertApp.swift`.
  - Route default taps and both actions through the existing history-item navigation path.
  - _Requirements: 3.6–3.7, 3.11–3.12, 5.3_

- [x] 7. Prove model and runtime notification contracts
  - Extend `Tests/FileConvertAppTests/FileConvertViewModelTests.swift` for exact success, failure, recovery, duration-present, duration-absent, permission/post failure, startup non-replay, state transition, deduplication, routing metadata, and content privacy behavior.
  - Add focused runtime mapping coverage for persisted timestamps and nonnegative duration.
  - Verify latest observed success/failure keeps menu status title and icon aligned while startup remains the default checkmark.
  - _Requirements: 3.1–3.10, 5.1–5.5, 6.1_

- [x] 8. Prove popover behavior with UI automation
  - Update `Tests/FileConvertUITests/FileConvertUITests.swift` for the status header, compact pause/resume control, activity row content and history navigation, empty state, existing navigation actions, and absence of custom toast/banner/notification-card UI.
  - Keep checks behavioral and accessibility-based rather than asserting source text or fixed pixels.
  - _Requirements: 1.1–1.10, 2.4–2.6, 4.1–4.3, 6.2_

- [x] 9. Smoke-test and visually inspect the native UX
  - Build and launch FileFlip on macOS.
  - Exercise representative successful and failed conversions and confirm filename/status/history/system-notification behavior end to end.
  - Inspect the popover in Light and Dark Mode, then check Reduce Transparency, Increase Contrast, and Reduce Motion behavior for legibility, boundaries, clipping, and animation suppression.
  - _Requirements: 2.1–2.6, 3.1–3.12, 4.1–4.4, 5.1–5.5, 6.3–6.4_
