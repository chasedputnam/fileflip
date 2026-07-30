import FileConvertCore
import XCTest
import CoreGraphics
import CryptoKit
import ImageIO

@MainActor
final class FileConvertUITests: XCTestCase {
    private var application: XCUIApplication!
    private var storageURL: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        application = XCUIApplication()
        application.launchEnvironment["FILECONVERT_UI_TESTING"] = "1"
        storageURL = Self.temporaryStorageURL()
        application.launchEnvironment["FILECONVERT_UI_TEST_STORAGE"] = storageURL.path
    }

    override func tearDown() {
        application.terminate()
        application = nil
        try? FileManager.default.removeItem(at: storageURL)
        storageURL = nil
        super.tearDown()
    }

    func testFirstLaunchExplainsLocalConversionAndFolderChoice() {
        launch(scenario: "first-launch")

        XCTAssertTrue(application.windows["Welcome to FileFlip"].waitForExistence(timeout: 3))
        XCTAssertFalse(textContaining("FileConvert").exists)
        XCTAssertTrue(application.staticTexts["Convert by Renaming"].waitForExistence(timeout: 3))
        XCTAssertTrue(application.staticTexts["Convert by Renaming"].exists)
        XCTAssertTrue(application.staticTexts["Private by design"].exists)
        let authorize = application.buttons["onboarding.authorize"]
        XCTAssertTrue(authorize.exists)
        XCTAssertTrue(authorize.isEnabled)
    }

    func testFirstSuccessfulConversionAppearsInStatusAndHistory() {
        launch(scenario: "successful")
        openMenuBarExtra()

        XCTAssertTrue(statusSummary.waitForExistence(timeout: 2))
        let recentActivity = buttonContaining("photo.png")
        XCTAssertTrue(recentActivity.waitForExistence(timeout: 2))
        XCTAssertEqual(recentActivity.value as? String, "0ms")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(recentActivity.value as? String, "0ms")

        application.buttons["history.open"].click()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: 2))
        XCTAssertTrue(application.buttons["history.clear"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.descendants(matching: .outlineRow).firstMatch.isSelected)
        XCTAssertTrue(application.staticTexts["photo.png"].exists)
        XCTAssertTrue(textContaining("Converted").exists)
        XCTAssertTrue(application.staticTexts["0ms"].exists)
    }

    func testFailedLiveConversionRestoresOriginalNameAndSetsFailureStatus() throws {
        launch(scenario: "live-failure")
        let watched = storageURL.appendingPathComponent("Watched", isDirectory: true)
        let original = watched.appendingPathComponent("damaged.jpg")
        let renamed = watched.appendingPathComponent("damaged.png")
        try writeJPEGFixture(to: original)
        Thread.sleep(forTimeInterval: 0.75)
        try FileManager.default.moveItem(at: original, to: renamed)

        XCTAssertTrue(waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: original.path)
                && !FileManager.default.fileExists(atPath: renamed.path)
        })

        let namedStatusItem = application.statusItems["FileConvert"]
        let statusItem = namedStatusItem.exists ? namedStatusItem : application.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil(timeout: 5) {
            statusItem.debugDescription.contains("last conversion failed")
        })

        openHistory()
        XCTAssertTrue(application.staticTexts["damaged.png"].waitForExistence(timeout: 3))
        XCTAssertTrue(textContaining("Failed").exists)
    }

    func testStartupResetsPriorFailureMenuBarStatus() {
        launch(scenario: "failure")
        let namedStatusItem = application.statusItems["FileConvert"]
        let statusItem = namedStatusItem.exists ? namedStatusItem : application.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil(timeout: 3) {
            statusItem.debugDescription.contains("monitoring authorized folders")
        })
    }

    func testTransparencyChoiceResumesConversionWithSelectedBackground() {
        launch(scenario: "transparency-choice")

        let whiteBackground = application.buttons["White Background"]
        XCTAssertTrue(whiteBackground.waitForExistence(timeout: 5))
        whiteBackground.click()

        let original = storageURL.appending(path: "Watched/transparent.webp")
        let converted = storageURL.appending(path: "Watched/transparent.jpg")
        XCTAssertTrue(waitUntil(timeout: 10) {
            FileManager.default.fileExists(atPath: original.path)
                && FileManager.default.fileExists(atPath: converted.path)
                && Self.isJPEG(converted)
        })

        openHistory()
        XCTAssertTrue(application.staticTexts["transparent.jpg"].waitForExistence(timeout: 3))
        XCTAssertTrue(textContaining("Converted").exists)
        XCTAssertFalse(textContaining("Failed").exists)
    }

    func testAmbiguousMediaTracksUseOnePromptAndResumeConversion() async throws {
        try writeAmbiguousMediaFixture()
        launch(scenario: "track-choice")

        let audio = application.popUpButtons["Audio Track"]
        let subtitles = application.popUpButtons["Video Subtitle Track"]
        guard audio.waitForExistence(timeout: 8) else {
            XCTFail("Track prompt did not appear:\n\(application.debugDescription)")
            return
        }
        XCTAssertTrue(subtitles.exists)

        audio.click()
        application.typeKey(.downArrow, modifierFlags: [])
        application.typeKey(.enter, modifierFlags: [])
        subtitles.click()
        application.menuItems["None"].click()
        application.dialogs.buttons["Continue"].click()

        let converted = storageURL.appending(path: "Watched/recording.mkv")
        let completed = waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: converted.path)
                && ((try? converted.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
        if !completed {
            let journal = try JournalStore(url: storageURL.appending(path: "journal.sqlite"))
            let jobs = try await journal.recentHistory()
            let original = storageURL.appending(path: "Watched/recording.mov")
            let detail = "\(jobs.map { "\($0.state.rawValue):\($0.errorCode ?? "none"):\($0.errorDetail ?? "none")" }); original=\(FileManager.default.fileExists(atPath: original.path)); target=\(FileManager.default.fileExists(atPath: converted.path))"
            openMenuBarExtra()
            let messages = application.staticTexts.allElementsBoundByIndex.map { "\($0.label)|\($0.value ?? "")" }
            XCTFail("Conversion did not complete: \(detail); messages: \(messages)")
            return
        }
        openHistory()
        XCTAssertTrue(application.staticTexts["recording.mkv"].waitForExistence(timeout: 3))
        XCTAssertTrue(textContaining("Converted").exists)
    }

    func testPauseAndResumeAffectOnlyNewEvents() {
        launch(scenario: "successful")
        openMenuBarExtra()

        let control = application.buttons["monitoring.pause-resume"]
        XCTAssertEqual(control.label, "Pause Monitoring")
        control.click()
        XCTAssertTrue(application.buttons["Resume Monitoring"].waitForExistence(timeout: 2))
        XCTAssertTrue(statusText.contains("New rename events"))
        application.buttons["Resume Monitoring"].click()
        XCTAssertTrue(application.buttons["Pause Monitoring"].waitForExistence(timeout: 2))
        application.buttons["history.open"].click()
        XCTAssertTrue(application.buttons["history.clear"].waitForExistence(timeout: 2))
        let historyItems = application.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'history.item.'")
        )
        XCTAssertEqual(historyItems.count, 1)
    }

    func testConvertingStateReportsLocalWorkInProgress() {
        launch(scenario: "converting")
        openMenuBarExtra()

        let status = statusSummary
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertTrue(statusText.contains("Converting"))
        XCTAssertTrue(statusText.contains("Converting 1 file locally"))
    }

    func testPermissionLossShowsBlockedStatusAndRecoveryAction() {
        launch(scenario: "permission-blocked")
        openMenuBarExtra()

        let status = statusSummary
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertTrue(statusText.contains("monitoring is blocked"))
        XCTAssertTrue(statusText.contains("Reauthorize"))
        application.buttons["Settings…"].click()
        XCTAssertTrue(application.buttons["Folders"].waitForExistence(timeout: 2))
        application.buttons["Folders"].click()
        XCTAssertTrue(application.buttons["Reauthorize Watched"].waitForExistence(timeout: 2))
    }

    func testRecoveryRequiredIdentifiesFileWithoutOverwriting() {
        launch(scenario: "recovery-required")
        openMenuBarExtra()

        let status = statusSummary
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertTrue(statusText.contains("file needs safe recovery"))
        XCTAssertTrue(statusText.contains("draft.pdf needs review"))
    }

    func testRecoveryRestoresSeparateFileAndClearsRecoveryStatus() throws {
        launch(scenario: "recovery-required")
        let visibleFile = storageURL.appending(path: "Watched/draft.pdf")
        let recoveredFile = storageURL.appending(path: "Watched/draft — Recovered.docx")
        let visibleBytes = try Data(contentsOf: visibleFile)

        openMenuBarExtra()
        let review = application.buttons["Review Recovery…"]
        XCTAssertTrue(review.waitForExistence(timeout: 2))
        review.click()

        let restore = application.buttons["history.restore-recovery"]
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        let detail = application.descendants(matching: .any)["history.detail-scroll"]
        XCTAssertTrue(detail.waitForExistence(timeout: 2))
        for _ in 0..<3 where !restore.isHittable {
            detail.swipeUp()
        }
        XCTAssertTrue(restore.isHittable)
        restore.click()
        let confirm = application.dialogs.buttons["Choose Destination…"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.click()

        let savePanel = application.dialogs["save-panel"]
        XCTAssertTrue(savePanel.waitForExistence(timeout: 3))
        savePanel.typeKey("g", modifierFlags: [.command, .shift])
        savePanel.typeText(storageURL.appending(path: "Watched").path)
        savePanel.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(savePanel.waitForExistence(timeout: 3))
        let save = savePanel.buttons["OKButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.click()

        XCTAssertTrue(waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: recoveredFile.path)
        })
        XCTAssertEqual(try Data(contentsOf: recoveredFile), Data("exact original bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: visibleFile), visibleBytes)
        XCTAssertTrue(textContaining("Recovered as draft — Recovered.docx").waitForExistence(timeout: 3))
        XCTAssertFalse(application.buttons["history.restore-recovery"].exists)

        let statusItem = application.statusItems["FileConvert"].exists
            ? application.statusItems["FileConvert"]
            : application.statusItems.firstMatch
        XCTAssertTrue(waitUntil(timeout: 3) {
            statusItem.debugDescription.contains("monitoring authorized folders")
        })

        application.terminate()
        launch(scenario: "empty")
        openMenuBarExtra()
        let relaunchedStatusItem = application.statusItems["FileConvert"].exists
            ? application.statusItems["FileConvert"]
            : application.statusItems.firstMatch
        XCTAssertTrue(relaunchedStatusItem.debugDescription.contains("monitoring authorized folders"))
        application.buttons["history.open"].click()
        XCTAssertTrue(textContaining("Recovered as draft — Recovered.docx").waitForExistence(timeout: 3))
        XCTAssertFalse(application.buttons["history.restore-recovery"].exists)
    }

    func testRecoveryUnavailableShowsManualOnlyStateAndClearProtection() {
        launch(scenario: "recovery-unavailable")
        openHistory()

        XCTAssertTrue(textContaining("Recovery data unavailable").waitForExistence(timeout: 3))
        XCTAssertFalse(application.buttons["history.restore-recovery"].exists)
        XCTAssertTrue(application.buttons["history.resolve-recovery"].exists)

        application.buttons["history.clear"].click()
        XCTAssertTrue(
            textContaining("Unresolved recovery items and retained recovery data remain protected")
                .waitForExistence(timeout: 2)
        )
        application.sheets.buttons["Cancel"].click()
        XCTAssertTrue(application.buttons["history.resolve-recovery"].exists)
    }

    func testPreviouslyRestoredRecoveryShowsResolvedDetailWithoutActions() {
        launch(scenario: "recovery-resolved")
        openHistory()

        XCTAssertTrue(textContaining("Recovered as draft — Recovered.docx").waitForExistence(timeout: 3))
        XCTAssertFalse(application.buttons["history.restore-recovery"].exists)
        XCTAssertFalse(application.buttons["history.resolve-recovery"].exists)
        XCTAssertTrue(statusItemDescription.contains("monitoring authorized folders"))
    }

    func testManuallyResolvedRecoveryShowsResolvedDetailWithoutActions() {
        launch(scenario: "recovery-manual")
        openHistory()

        XCTAssertTrue(textContaining("Resolved manually").waitForExistence(timeout: 3))
        XCTAssertFalse(application.buttons["history.restore-recovery"].exists)
        XCTAssertFalse(application.buttons["history.resolve-recovery"].exists)
        XCTAssertTrue(statusItemDescription.contains("monitoring authorized folders"))
    }

    func testRecoveryRestoreAndManualConfirmationCancellationLeaveItemUnresolved() {
        launch(scenario: "recovery-required")
        openHistory()
        let restore = application.buttons["history.restore-recovery"]
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        scrollRecoveryActionIntoView(restore)
        restore.click()
        let choose = application.dialogs.buttons["Choose Destination…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 2))
        choose.click()

        let savePanel = application.dialogs["save-panel"]
        XCTAssertTrue(savePanel.waitForExistence(timeout: 3))
        let cancelSave = savePanel.buttons["CancelButton"]
        XCTAssertTrue(cancelSave.waitForExistence(timeout: 2))
        cancelSave.click()
        let resolve = application.buttons["history.resolve-recovery"]
        resolve.click()
        let cancelResolution = application.dialogs.buttons["Cancel"]
        XCTAssertTrue(cancelResolution.waitForExistence(timeout: 2))
        cancelResolution.click()
        XCTAssertTrue(resolve.waitForExistence(timeout: 2))
    }

    func testRecoveryConflictPreservesOccupiedFileThenRetriesWithNewName() throws {
        launch(scenario: "recovery-conflict")
        let watched = storageURL.appending(path: "Watched")
        let occupied = watched.appending(path: "draft — Recovered.docx")
        let occupiedBytes = try Data(contentsOf: occupied)
        openHistory()

        let restore = application.buttons["history.restore-recovery"]
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        scrollRecoveryActionIntoView(restore)
        restore.click()
        let choose = application.dialogs.buttons["Choose Destination…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 2))
        choose.click()
        chooseRecoveryDirectory(watched)

        let replace = application.buttons["Replace"]
        XCTAssertTrue(replace.waitForExistence(timeout: 3))
        replace.click()
        XCTAssertTrue(
            textContaining("Choose a destination that does not already exist")
                .waitForExistence(timeout: 3)
        )
        XCTAssertEqual(try Data(contentsOf: occupied), occupiedBytes)
        application.dialogs.buttons["OK"].click()

        let savePanel = application.dialogs["save-panel"]
        XCTAssertTrue(savePanel.waitForExistence(timeout: 3))
        let nameField = savePanel.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("draft — Retry.docx")
        savePanel.buttons["OKButton"].click()

        let retried = watched.appending(path: "draft — Retry.docx")
        XCTAssertTrue(waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: retried.path)
        })
        XCTAssertEqual(try Data(contentsOf: retried), Data("exact original bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: occupied), occupiedBytes)
        XCTAssertTrue(application.buttons["Reveal in Finder"].waitForExistence(timeout: 3))
    }

    func testLaunchAndTypedFutureJobDefaultsAreAvailableInSettings() {
        launch(scenario: "successful")
        openMenuBarExtra()
        application.buttons["Settings"].click()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: 2))
        XCTAssertTrue(application.buttons["General"].waitForExistence(timeout: 2))
        XCTAssertEqual(application.windows["com_apple_SwiftUI_Settings_window"].title, "General")
        application.buttons["General"].click()
        XCTAssertTrue(application.checkBoxes["settings.launch-at-login"].exists)

        application.buttons["Defaults"].click()
        XCTAssertTrue(application.descendants(matching: .any)["defaults.image.quality"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.descendants(matching: .any)["settings.conversion-behavior"].exists)
        XCTAssertTrue(application.descendants(matching: .any)["defaults.image.frames"].exists)
        XCTAssertTrue(application.descendants(matching: .any)["defaults.audio.bitrate"].exists)
        XCTAssertTrue(application.descendants(matching: .any)["defaults.video.quality"].exists)
        XCTAssertTrue(application.descendants(matching: .any)["defaults.document.loss"].exists)
        XCTAssertTrue(application.descendants(matching: .any)["defaults.spreadsheet.formula-values"].exists)
    }

    func testConversionBehaviorDefaultsToCopyAndBothSelectionsSurviveRelaunch() {
        launch(scenario: "successful")
        openDefaults()
        let picker = conversionBehaviorPicker
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
        XCTAssertTrue(pickerValue(picker).contains("Keep original"))

        chooseConversionBehavior("Replace file and keep recoverable backup", in: picker)
        XCTAssertTrue(pickerValue(picker).contains("Replace file"))
        waitForDefaultsSave()
        application.terminate()

        launch(scenario: "successful")
        openDefaults()
        XCTAssertTrue(pickerValue(conversionBehaviorPicker).contains("Replace file"))
        chooseConversionBehavior("Keep original and create converted copy", in: conversionBehaviorPicker)
        XCTAssertTrue(pickerValue(conversionBehaviorPicker).contains("Keep original"))
        waitForDefaultsSave()
        application.terminate()

        launch(scenario: "successful")
        openDefaults()
        XCTAssertTrue(pickerValue(conversionBehaviorPicker).contains("Keep original"))
    }

    func testChangingFutureBehaviorDoesNotRelabelCommittedConversion() {
        launch(scenario: "successful")
        openDefaults()
        chooseConversionBehavior("Keep original and create converted copy", in: conversionBehaviorPicker)
        waitForDefaultsSave()
        application.typeKey("w", modifierFlags: .command)
        openHistory()

        application.staticTexts["photo.png"].click()
        XCTAssertTrue(textContaining("Replaced file with retained backup").waitForExistence(timeout: 2))
        XCTAssertFalse(textContaining("Kept original and created copy").exists)
    }

    func testRequiredPolicyChoiceIsActionable() {
        launch(scenario: "needs-choice")
        openMenuBarExtra()

        XCTAssertTrue(statusText.contains("policy choice"))
        XCTAssertTrue(statusText.contains("future-job policy"))
        application.buttons["Settings…"].click()
        XCTAssertTrue(application.buttons["General"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.buttons["Defaults"].exists)
    }

    func testUnavailableProviderExplainsUnavailableFormats() {
        launch(scenario: "provider-unavailable")
        openMenuBarExtra()
        application.buttons["Settings…"].click()
        XCTAssertTrue(application.buttons["General"].waitForExistence(timeout: 2))
        application.buttons["Formats"].click()

        let provider = application.staticTexts["provider.ffmpeg"]
        XCTAssertTrue(provider.waitForExistence(timeout: 2))
        XCTAssertTrue(provider.label.contains("Unavailable"))
        application.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(application.staticTexts["No conversion pairs are currently available."].waitForExistence(timeout: 2))
    }

    func testFailureDetailIsRedactedAndActionable() {
        launch(scenario: "failure")
        openHistory()

        application.staticTexts["broken.mov"].click()
        XCTAssertTrue(application.staticTexts["What happened"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.staticTexts["What happened"].exists)
        XCTAssertTrue(textContaining("original file was preserved").exists)
        XCTAssertFalse(textContaining("/Users/").exists)
    }

    func testHistoryExplainsWhenConvertedFileIsUnavailable() {
        launch(scenario: "unavailable-file")
        openHistory()

        application.staticTexts["missing.png"].click()
        XCTAssertTrue(application.staticTexts["Unavailable"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.staticTexts["Unavailable"].exists)
        XCTAssertTrue(textContaining("Undo is unavailable").exists)
    }

    func testSignedApplicationFSEventsPathPreservesBothModesAndExactUndo() throws {
        launch(scenario: "live-monitoring")
        openDefaults()
        chooseConversionBehavior("Keep original and create converted copy", in: conversionBehaviorPicker)
        waitForDefaultsSave()
        application.typeKey("w", modifierFlags: .command)

        let watched = storageURL.appendingPathComponent("Watched", isDirectory: true)
        let copyOriginal = watched.appendingPathComponent("copy.jpg")
        let copyTarget = watched.appendingPathComponent("copy.png")
        try writeJPEGFixture(to: copyOriginal)
        let copyBytes = try Data(contentsOf: copyOriginal)
        let copyHash = Data(SHA256.hash(data: copyBytes))
        Thread.sleep(forTimeInterval: 0.75)
        try FileManager.default.moveItem(at: copyOriginal, to: copyTarget)

        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(atPath: copyOriginal.path)
                && Self.isPNG(copyTarget)
        })
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: copyOriginal))), copyHash)

        openDefaults()
        chooseConversionBehavior("Replace file and keep recoverable backup", in: conversionBehaviorPicker)
        waitForDefaultsSave()
        application.typeKey("w", modifierFlags: .command)

        let replaceOriginal = watched.appendingPathComponent("replace.jpg")
        let replaceTarget = watched.appendingPathComponent("replace.png")
        try writeJPEGFixture(to: replaceOriginal)
        let replaceBytes = try Data(contentsOf: replaceOriginal)
        Thread.sleep(forTimeInterval: 0.75)
        try FileManager.default.moveItem(at: replaceOriginal, to: replaceTarget)

        XCTAssertTrue(waitUntil {
            !FileManager.default.fileExists(atPath: replaceOriginal.path)
                && Self.isPNG(replaceTarget)
        })
        openHistory()
        application.staticTexts["replace.png"].click()
        let undo = application.buttons["history.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2))
        undo.click()
        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(atPath: replaceOriginal.path)
                && !FileManager.default.fileExists(atPath: replaceTarget.path)
        })
        XCTAssertEqual(try Data(contentsOf: replaceOriginal), replaceBytes)
    }

    func testClearHistoryRequiresDestructiveWarning() {
        launch(scenario: "successful")
        openHistory()

        application.buttons["history.clear"].click()
        XCTAssertTrue(application.staticTexts["Clear conversion history?"].waitForExistence(timeout: 2))
        XCTAssertTrue(textContaining("Unresolved recovery items and retained recovery data remain protected").exists)
        application.sheets.buttons["Clear History and Delete Backups"].click()
        XCTAssertTrue(textContaining("No conversion history").waitForExistence(timeout: 2))
    }

    func testExactUndoRestoresSuccessfulConversion() {
        launch(scenario: "successful")
        openHistory()

        application.staticTexts["photo.png"].click()
        let undo = application.buttons["history.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2))
        undo.click()
        XCTAssertTrue(textContaining("Undo is unavailable").waitForExistence(timeout: 2))
    }

    func testCopyModeHistoryAndUndoUseVisibleOriginal() {
        launch(scenario: "copy-success")
        openHistory()

        application.staticTexts["photo.png"].click()
        XCTAssertTrue(textContaining("Kept original and created copy").waitForExistence(timeout: 2))
        let undo = application.buttons["history.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2))
        undo.click()
        XCTAssertTrue(textContaining("Undo is unavailable").waitForExistence(timeout: 2))
    }

    func testClearingCopyHistoryLeavesBothVisibleFilesUntouched() throws {
        launch(scenario: "copy-success")
        let watched = storageURL.appendingPathComponent("Watched", isDirectory: true)
        let original = watched.appendingPathComponent("photo.jpg")
        let converted = watched.appendingPathComponent("photo.png")
        let originalBytes = try Data(contentsOf: original)
        let convertedBytes = try Data(contentsOf: converted)
        openHistory()

        application.buttons["history.clear"].click()
        XCTAssertTrue(textContaining("User-visible files are not deleted").waitForExistence(timeout: 2))
        application.sheets.buttons["Clear History and Delete Backups"].click()
        XCTAssertTrue(textContaining("No conversion history").waitForExistence(timeout: 2))

        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: converted), convertedBytes)
    }

    func testChangedFileUndoOffersKeepBothFlow() {
        launch(scenario: "undo-conflict")
        openHistory()

        application.staticTexts["report.pdf"].click()
        application.buttons["history.undo"].click()
        XCTAssertTrue(application.staticTexts["The Current File Has Changed"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.staticTexts["The Current File Has Changed"].exists)
        XCTAssertTrue(application.buttons["history.keep-both"].isEnabled)
        XCTAssertFalse(application.buttons["Replace"].exists)
    }

    func testKeyboardControlsAndAccessibilityLabelsRemainAvailable() {
        launch(scenario: "successful")
        openMenuBarExtra()

        application.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(application.buttons["Resume Monitoring"].waitForExistence(timeout: 2))
        let statusLabel = statusText
        application.typeKey("h", modifierFlags: .command)
        XCTAssertTrue(application.buttons["history.clear"].waitForExistence(timeout: 2))
        XCTAssertFalse(statusLabel.isEmpty)
    }

    private var conversionBehaviorPicker: XCUIElement {
        application.popUpButtons["settings.conversion-behavior"]
    }

    private func openDefaults() {
        openMenuBarExtra()
        application.buttons["Settings…"].click()
        XCTAssertTrue(application.buttons["Defaults"].waitForExistence(timeout: 2))
        application.buttons["Defaults"].click()
    }

    private func chooseConversionBehavior(_ label: String, in picker: XCUIElement) {
        picker.click()
        let option = application.menuItems[label]
        XCTAssertTrue(option.waitForExistence(timeout: 2))
        option.click()
    }

    private func pickerValue(_ picker: XCUIElement) -> String {
        (picker.value as? String) ?? picker.label
    }

    private func waitForDefaultsSave() {
        let saved = expectation(description: "Future conversion defaults persisted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { saved.fulfill() }
        wait(for: [saved], timeout: 1)
    }

    private func writeAmbiguousMediaFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Media/video/ambiguous-tracks.mov")
        let watched = storageURL.appending(path: "Watched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture,
            to: watched.appending(path: "recording.mov")
        )
    }

    private func writeJPEGFixture(to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create image context")
            return
        }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            XCTFail("Could not create JPEG fixture")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return try condition()
    }

    private static func isPNG(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count >= 8 else { return false }
        return data.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10])
    }

    private static func isJPEG(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count >= 3 else { return false }
        return data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF])
    }

    private var statusSummary: XCUIElement {
        application.descendants(matching: .any)["status.summary"]
    }

    private var statusText: String {
        (statusSummary.value as? String) ?? statusSummary.label
    }

    private var statusItemDescription: String {
        let namedStatusItem = application.statusItems["FileConvert"]
        let statusItem = namedStatusItem.exists ? namedStatusItem : application.statusItems.firstMatch
        return statusItem.debugDescription
    }

    private func scrollRecoveryActionIntoView(_ action: XCUIElement) {
        let detail = application.descendants(matching: .any)["history.detail-scroll"]
        XCTAssertTrue(detail.waitForExistence(timeout: 2))
        for _ in 0..<3 where !action.isHittable {
            detail.swipeUp()
        }
        XCTAssertTrue(action.isHittable)
    }

    private func chooseRecoveryDirectory(_ directory: URL) {
        let savePanel = application.dialogs["save-panel"]
        XCTAssertTrue(savePanel.waitForExistence(timeout: 3))
        savePanel.typeKey("g", modifierFlags: [.command, .shift])
        savePanel.typeText(directory.path)
        savePanel.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(savePanel.waitForExistence(timeout: 3))
        let save = savePanel.buttons["OKButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.click()
    }

    private func textContaining(_ text: String) -> XCUIElement {
        application.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        ).firstMatch
    }

    private func buttonContaining(_ text: String) -> XCUIElement {
        application.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        ).firstMatch
    }

    func testSuccessfulConversionAppearsInDarkMode() {
        application.launchEnvironment["FILECONVERT_UI_TEST_APPEARANCE"] = "dark"
        launch(scenario: "successful")
        openMenuBarExtra()
        XCTAssertTrue(statusSummary.waitForExistence(timeout: 2))
        XCTAssertTrue(buttonContaining("photo.png").waitForExistence(timeout: 2))
        XCTAssertTrue(buttonContaining("Converted").exists)
    }


    private func launch(scenario: String) {
        application.launchEnvironment["FILECONVERT_UI_TEST_SCENARIO"] = scenario
        application.launch()
        let foreground = application.wait(for: .runningForeground, timeout: 1)
        let background = foreground ? false : application.wait(for: .runningBackground, timeout: 2)
        XCTAssertTrue(foreground || background)
    }

    private func openMenuBarExtra() {
        let namedStatusItem = application.statusItems["FileConvert"]
        let statusItem = namedStatusItem.exists ? namedStatusItem : application.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        statusItem.click()
    }

    private func openHistory() {
        openMenuBarExtra()
        application.buttons["history.open"].click()
        XCTAssertTrue(application.buttons["history.clear"].waitForExistence(timeout: 2))
    }

    nonisolated private static func temporaryStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FileConvertUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
