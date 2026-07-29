import AppKit
import Foundation

@MainActor
struct FolderPicker {
    let explanation = "Rename a file’s extension in an authorized folder to request a local conversion. FileFlip never watches a folder until you choose it."
    let suggestions: [URL]

    init(fileManager: FileManager = .default) {
        suggestions = [
            fileManager.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory),
        ]
    }

    func chooseFolders() -> [URL]? {
        let panel = configuredPanel(
            title: "Choose folders to watch",
            message: "\(explanation) Desktop and Downloads are common choices, but neither is preselected.",
            prompt: "Authorize Folders",
            allowsMultipleSelection: true
        )
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func chooseFolderToReauthorize(named folderName: String) -> URL? {
        let panel = configuredPanel(
            title: "Reauthorize \(folderName)",
            message: "Choose the same folder again to restore monitoring access.",
            prompt: "Reauthorize",
            allowsMultipleSelection: false
        )
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func configuredPanel(
        title: String,
        message: String,
        prompt: String,
        allowsMultipleSelection: Bool
    ) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canCreateDirectories = false
        panel.directoryURL = nil
        return panel
    }
}
