# Code Review Feedback

## Summary

The recovery-store restoration implementation satisfies the approved requirements and design. No blocking, important, suggestion, or nit findings remain after correctness, contract, security, cleanup, test-evidence, clarity, and lifecycle review.

## Findings

No findings.

## Positive observations

- Recovery resolution is append-only and constrained to unresolved `needsRecovery` replacement jobs.
- Unresolved retained artifacts are excluded from age, byte-pressure, and Clear History deletion paths; resolution makes them eligible without rewriting historical job state.
- Restore validates the retained regular file and SHA-256 before staging, validates staged bytes again, and publishes with exclusive rename semantics so an existing destination is never overwritten.
- Restore and manual acknowledgement remain separate, explicit actions. A successful file publication with a failed resolution write remains visibly unresolved and returns a specific actionable error.
- History, menu-bar recovery state, notifications, detail actions, Finder reveal, and relaunch behavior derive from persisted recovery resolution state rather than current future-job defaults.
- Focused core, integration, app-model, and UI lifecycle tests cover restore success, occupied destination, changed/symlink artifact rejection, manual acknowledgement, cleanup protection, current-default independence, exact bytes, preserved visible file, status clearing, and relaunch persistence.

## Evidence reviewed

- `swift test --filter 'retainedRecovery'`: 4 tests passed.
- `swift test --filter 'unresolvedRecovery|clearHistoryPreservesOnlyUnresolvedRecoveryJobs|journalMigratesVersionTwoRecoveryRowsWithoutResolvingThem|recoveryResolutionIsAppendOnlyAndRestrictedToEligibleJobs|recoveryResolutionEnforcesMethodFilenameContract'`: focused journal and cleanup coverage passed.
- `swift test --filter 'recoveryActionsFollowRecordedJobStateInsteadOfCurrentDefault|manualRecoveryResolutionRequiresConfirmation'`: 2 app-model tests passed.
- `xcodebuild test -project FileFlip.xcodeproj -scheme FileFlip -destination 'platform=macOS' -only-testing:FileConvertUITests/FileConvertUITests/testRecoveryRestoresSeparateFileAndClearsRecoveryStatus`: 1 end-to-end UI lifecycle test passed, including relaunch.
- Full `swift test`: 149 tests passed; 3 unrelated concurrency/resource tests failed only during the parallel full-suite run. The same three tests passed together immediately afterward with 0 failures.

## Verdict

- [x] All BLOCKING findings resolved.
- [x] All IMPORTANT findings resolved or converted to tracked tasks.
- Approve for human review.

## Re-review — conversion failure UX

One blocking polling defect was found and resolved: a job first observed as `converting` could later become `failed` under the same ID without updating the menu icon or posting a notification. Outcome tracking now compares the previously observed state per job ID, and notification deduplication is keyed by job ID plus outcome.

Additional reviewed behavior:

- Pre-publication conversion failures restore the original filename with an exclusive rename and directory flush. Unsafe or failed rollback becomes `needsRecovery` instead of reporting an ordinary failure.
- A failed conversion sets the session menu state to `exclamationmark.circle.fill`; a fresh launch does not inherit historical failure state.
- Success, failure, and recovery notifications contain only the filename, route to the corresponding history item, and do not replay historical jobs at startup.

Additional evidence:

- `swift test --filter latestConversionOutcomeDrivesMenuIconAndPostsNotifications`: 1 test passed, including the `converting` → `failed` same-ID transition.
- `swift test --no-parallel`: 161 tests passed.
- `xcodebuild test ... testFailedLiveConversionRestoresOriginalNameAndSetsFailureStatus ... testStartupResetsPriorFailureMenuBarStatus`: 2 UI tests passed.

Re-review verdict: no blocking, important, suggestion, or nit findings remain.
