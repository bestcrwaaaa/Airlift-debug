import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Source

/// Where the bytes of a write or an export come from.
enum DebugSource: String, CaseIterable, Identifiable {
    case editor
    case imported
    case device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return String(localized: "Editor")
        case .imported: return String(localized: "Imported")
        case .device: return String(localized: "Device")
        }
    }
}

// MARK: - Status

/// The outcome of the last operation, painted as a banner.
enum DebugStatus: Equatable {
    case idle
    case working(String)
    case success(String)
    case warning(String)
    case failure(String)
}

// MARK: - Quick paths

/// Paths worth one tap.
enum DebugPaths {
    static let announcement = SilenceEngine.targetDir + "/StartDisclosure.caf"
    static let greetings = SilenceEngine.targetDir
    static let media = DebugEngine.mediaRoot
    static let library = "/var/mobile/Library"
    static let preferences = "/var/mobile/Library/Preferences"
    static let mobile = "/var/mobile"
}

// MARK: - Pending request

extension Notification.Name {
    /// A path for the debug console, sent by the URL scheme.
    static let debugConsoleRequest = Notification.Name("airlift.debug.console.request")
}

// MARK: - View model

/// The state behind the debug console, and the only place that talks to the
/// device for it.
///
/// Every operation is blocking and runs off the main thread. The device takes
/// one exploit session at a time, so a run that arrives while the announcement
/// screen is busy is refused rather than queued behind it.
@MainActor
final class DebugViewModel: ObservableObject {

    // MARK: state

    @Published var path: String = DebugPaths.announcement
    @Published var content: String = ""
    @Published var source: DebugSource = .editor
    @Published var status: DebugStatus = .idle
    @Published var busy = false
    @Published var log: [String] = []
    @Published var entries: [DebugEngine.Entry] = []
    /// The bytes of the last file read off the device.
    @Published var deviceData: Data?
    /// The bytes of the file picked in the Files app.
    @Published var importedData: Data?
    @Published var importedName: String?
    /// A binary payload is shown as a hex dump instead of as text.
    @Published var showHex = false
    /// The selected slice of the editor content, as character offsets.
    @Published var selectionStart = 0
    @Published var selectionEnd = 0
    /// The file prepared for the share sheet.
    @Published var exportURL: URL?
    /// The same file, as a document for the Files app.
    @Published var exportDocument: DebugExportDocument?
    @Published var exportName = "export.bin"

    private var drainTimer: Timer?

    /// A path handed over by the URL scheme, waiting for the console to pick
    /// it up. The console may not be on screen yet when the URL arrives.
    static var pendingPath: String?
    /// What to do with it: "read" or "browse".
    static var pendingAction: String?

    /// Take over a request that came in over the URL scheme.
    func consumePendingRequest() {
        guard let requested = Self.pendingPath, !requested.isEmpty else { return }
        let action = Self.pendingAction ?? "read"
        Self.pendingPath = nil
        Self.pendingAction = nil
        path = requested
        if action == "browse" {
            browse()
        } else {
            read()
        }
    }

    // MARK: derived

    /// The selected slice of the editor content.
    var selectedText: String {
        let text = content
        guard !text.isEmpty else { return "" }
        let lower = max(0, min(selectionStart, selectionEnd))
        let upper = min(text.count, max(selectionStart, selectionEnd))
        guard lower < upper else { return "" }
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(text.startIndex, offsetBy: upper)
        return String(text[start..<end])
    }

    /// The bytes a write or an export should use, according to the source picker.
    func payloadData() -> Data? {
        switch source {
        case .editor: return Data(content.utf8)
        case .imported: return importedData
        case .device: return deviceData
        }
    }

    var payloadSize: Int {
        payloadData()?.count ?? 0
    }

    // MARK: read

    /// Read the file at the path, through the exploit, and show its content.
    func read() {
        guard begin() else { return }
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            status = .failure(String(localized: "Enter a path first."))
            busy = false
            return
        }

        status = .working(String(localized: "Reading \(target)…"))
        append("── read \(target) ──")
        startDraining()

        let pairingPath = PairingController.pairingFilePath()
        SilenceEngine.applyStoredTargetHost()

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DebugEngine.read(path: target, pairingPath: pairingPath)
            }.value
            stopDraining()
            busy = false

            switch result {
            case let .success(file):
                deviceData = file.data
                if let text = file.text {
                    content = text
                    showHex = false
                    status = .success(String(localized: "Read \(file.byteCount.formatted()) bytes from \(target)"))
                } else {
                    content = DebugEngine.hexDump(file.data)
                    showHex = true
                    status = .warning(String(localized: "Read \(file.byteCount.formatted()) bytes — the file is not text, so a hex dump is shown"))
                }
                selectionStart = 0
                selectionEnd = content.count
                append("✓ \(file.byteCount.formatted()) byte(s)")
            case let .failure(failure):
                status = .failure(failure.message)
                append("✗ " + failure.message)
            }
        }
    }

    // MARK: write

    /// Write to the path, through the exploit.
    ///
    /// `onlySelection` writes just the selected slice of the editor content
    /// instead of the whole payload.
    func write(onlySelection: Bool = false) {
        guard begin() else { return }
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            status = .failure(String(localized: "Enter a path first."))
            busy = false
            return
        }

        let payload: Data
        if onlySelection {
            payload = Data(selectedText.utf8)
        } else if let data = payloadData() {
            payload = data
        } else {
            status = .failure(String(localized: "There is nothing to write yet."))
            busy = false
            return
        }

        status = .working(String(localized: "Writing \(payload.count.formatted()) bytes to \(target)…"))
        append("── write \(target) ──")
        startDraining()

        let pairingPath = PairingController.pairingFilePath()
        SilenceEngine.applyStoredTargetHost()

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DebugEngine.write(path: target, data: payload, pairingPath: pairingPath)
            }.value
            stopDraining()
            busy = false

            switch result {
            case let .success(written):
                status = .success(String(localized: "Wrote \(written.formatted()) bytes to \(target)"))
                append("✓ \(written.formatted()) byte(s) written")
            case let .failure(failure):
                status = .failure(failure.message)
                append("✗ " + failure.message)
            }
        }
    }

    // MARK: browse

    /// List a directory on the device.
    func browse() {
        guard begin() else { return }
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            status = .failure(String(localized: "Enter a path first."))
            busy = false
            return
        }

        status = .working(String(localized: "Listing \(target)…"))
        append("── list \(target) ──")
        startDraining()

        let pairingPath = PairingController.pairingFilePath()
        SilenceEngine.applyStoredTargetHost()

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DebugEngine.list(path: target, pairingPath: pairingPath)
            }.value
            stopDraining()
            busy = false

            switch result {
            case let .success(list):
                entries = list
                status = .success(String(localized: "Listed \(list.count) entry(ies) in \(target)"))
                append("✓ \(list.count) entry(ies)")
            case let .failure(failure):
                entries = []
                status = .failure(failure.message)
                append("✗ " + failure.message)
            }
        }
    }

    /// Open one entry of the listing: a directory is listed, a file becomes
    /// the target path.
    func open(_ entry: DebugEngine.Entry) {
        let base = path.hasSuffix("/") ? path : path + "/"
        path = base + entry.name
        if entry.isDirectory {
            browse()
        }
    }

    /// Step one directory up and list it.
    func goUp() {
        let parent = (path as NSString).deletingLastPathComponent
        path = parent.isEmpty ? "/" : parent
        browse()
    }

    // MARK: import

    /// Take a file from the Files app and keep its bytes.
    func adoptImportedFile(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            importedData = data
            importedName = url.lastPathComponent
            source = .imported
            status = .success(String(localized: "Imported \(url.lastPathComponent) (\(data.count.formatted()) bytes)"))
            append("── import \(url.lastPathComponent) ──")
            append("✓ \(data.count.formatted()) byte(s)")
        } catch {
            let message = String(localized: "Import failed: \(error.localizedDescription)")
            status = .failure(message)
            append("✗ " + message)
        }
    }

    // MARK: export

    /// Prepare the current payload for the share sheet and the Files app.
    func prepareExport() {
        guard let data = payloadData() else {
            status = .failure(String(localized: "There is nothing to export yet."))
            return
        }
        let leaf = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        let name = leaf.isEmpty ? "export.bin" : leaf
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlift-debug-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            exportURL = url
            exportDocument = DebugExportDocument(data: data)
            exportName = name
            status = .success(String(localized: "Exported \(data.count.formatted()) bytes as \(name)"))
            append("── export \(name) ──")
            append("✓ \(data.count.formatted()) byte(s)")
        } catch {
            let message = String(localized: "Export failed: \(error.localizedDescription)")
            status = .failure(message)
            append("✗ " + message)
        }
    }

    // MARK: selection

    func selectAll() {
        selectionStart = 0
        selectionEnd = content.count
    }

    /// Keep only the selected slice in the editor.
    func extractSelection() {
        let slice = selectedText
        guard !slice.isEmpty else { return }
        content = slice
        selectionStart = 0
        selectionEnd = slice.count
        status = .success(String(localized: "Kept \(slice.count) character(s)"))
    }

    /// Copy the selected slice to the clipboard.
    func copySelection() {
        let slice = selectedText
        guard !slice.isEmpty else { return }
        UIPasteboard.general.string = slice
        status = .success(String(localized: "Copied \(slice.count) character(s) to the clipboard"))
    }

    /// Put the imported file into the editor, as text when it is text.
    func loadImportedIntoEditor() {
        guard let data = importedData else { return }
        if let text = String(data: data, encoding: .utf8) {
            content = text
            showHex = false
            selectionStart = 0
            selectionEnd = text.count
            status = .success(String(localized: "Loaded the imported file into the editor"))
        } else {
            content = DebugEngine.hexDump(data)
            showHex = true
            status = .warning(String(localized: "The imported file is not text, so a hex dump is shown"))
        }
    }

    // MARK: plumbing

    /// Common guard for every device operation.
    private func begin() -> Bool {
        guard !busy else { return false }
        guard SilenceViewModel.shared.pairingReady else {
            status = .failure(String(localized: "Pair the device first — the console needs a pairing file."))
            return false
        }
        guard !SilenceViewModel.shared.busy else {
            status = .failure(String(localized: "The device is busy with another run."))
            return false
        }
        busy = true
        return true
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func startDraining() {
        drainTimer?.invalidate()
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let new = SilenceLog.shared.drain()
                if !new.isEmpty { self.log.append(contentsOf: new) }
            }
        }
    }

    private func stopDraining() {
        drainTimer?.invalidate()
        drainTimer = nil
        log.append(contentsOf: SilenceLog.shared.drain())
    }
}

// MARK: - Export document

/// A single file the console can hand to the Files app.
struct DebugExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
