import AppKit
import VirComKit

/// State of the "Send Files to Device" window.
@Observable
final class DownloadToolModel {
    var folder: URL? { didSet { if folder != oldValue { folderChanged() } } }
    var kind: DownloadKind = .webpage
    var codeFile: URL?
    var viaSerial = false
    var host = ""
    var port: UInt16 = ZLProtocol.managementPort
    var serialPort = ""
    var baudRate = 115_200
    var deviceModel: DownloadModel = .zlsn2003
    var flashKB = 2048
    var compressHTML = false
    var deviceID = ""
    /// The device the tool was opened for, if any (MQTT can set its destination).
    var device: DiscoveredDevice?

    private(set) var progress: DownloadProgress?
    private(set) var running = false
    var message: Message?
    /// Recently used web page folders (security-scoped bookmarks).
    private(set) var recentFolders: [URL] = []

    struct Message: Identifiable {
        let id = UUID()
        var title: String
        var text: String
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var scoped: URL?
    private static let bookmarksKey = "VirComWebFolders.v1"

    init() {
        let datas = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        recentFolders = datas.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        }
        folder = recentFolders.first
        folderChanged()
        serialPort = SerialLink.availablePorts().first ?? ""
    }

    /// Prefills the tool for a device found on the network.
    func target(_ d: DiscoveredDevice) {
        device = d
        host = d.parameters.ip.description
        deviceID = d.parameters.deviceID
    }

    private func folderChanged() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        guard let folder else { return }
        if folder.startAccessingSecurityScopedResource() { scoped = folder }
        var list = recentFolders.filter { $0.standardizedFileURL != folder.standardizedFileURL }
        list.insert(folder, at: 0)
        recentFolders = Array(list.prefix(10))
        let datas = recentFolders.compactMap { try? $0.bookmarkData(options: .withSecurityScope) }
        UserDefaults.standard.set(datas, forKey: Self.bookmarksKey)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the web page folder. Everything in it, including subfolders, is sent to the device. Configuration files are saved in it too. An empty folder is fine."
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func chooseCodeFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { codeFile = url }
    }

    /// The folder, or an error message when none is chosen.
    /// The web page directory; asks the user to choose one when none is set (or it was moved).
    func requireFolder() -> URL? {
        if let folder, FileManager.default.fileExists(atPath: folder.path) { return folder }
        chooseFolder()
        if let folder, FileManager.default.fileExists(atPath: folder.path) { return folder }
        return nil
    }

    func file(_ name: String) -> URL? { folder?.appendingPathComponent(name) }

    func read(_ name: String) -> [UInt8]? {
        guard let url = file(name) else { return nil }
        return (try? Data(contentsOf: url)).map { [UInt8]($0) }
    }

    func write(_ name: String, _ bytes: [UInt8]) throws {
        guard let url = file(name) else { throw DownloadError("Choose a web page folder first.") }
        try Data(bytes).write(to: url)
    }

    func remove(_ name: String) {
        guard let url = file(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The current script, decrypted if needed.
    func existingScript() -> String? {
        guard let bytes = read(ConfigFileName.script) else { return nil }
        let plain = (try? ScriptEncryption.decrypt(bytes)) ?? bytes
        return String(decoding: plain, as: UTF8.self)
    }

    // MARK: Download

    func start() {
        guard !running else { return }
        let image: FlashImage
        do {
            switch kind {
            case .webpage:
                guard let dir = requireFolder() else { return }
                if !deviceID.isEmpty { try ConfigDirectory.checkBinding(dir, deviceID: deviceID) }
                image = try FlashImageBuilder.build(directory: dir, flashKB: flashKB, compressHTML: compressHTML)
            case .code:
                guard deviceModel.supportsCodeDownload else { throw DownloadError("This device model can't receive firmware.") }
                guard let codeFile else { throw DownloadError("Select a code file.") }
                image = try FlashImageBuilder.code(file: codeFile, flashKB: flashKB)
            }
        } catch {
            message = Message(title: "Send Files to Device", text: error.localizedDescription)
            return
        }
        running = true
        progress = DownloadProgress(sent: 0, total: max(image.usedLength, 1))
        let update: @Sendable (DownloadProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.progress = p }
        }
        let serial = viaSerial
        let net = NetworkDownloader(host: host, port: port, model: deviceModel, kind: kind, flashKB: flashKB)
        let ser = SerialDownloader(portPath: serialPort, baudRate: baudRate, kind: kind)
        task = Task { [weak self] in
            do {
                let text = serial ? try await ser.run(image, progress: update) : try await net.run(image, progress: update)
                self?.finish(Message(title: "Send Files to Device", text: text))
            } catch is CancellationError {
                self?.finish(nil)
            } catch {
                self?.finish(Message(title: "Send Files to Device", text: error.localizedDescription))
            }
        }
    }

    func stop() { task?.cancel() }

    private func finish(_ m: Message?) {
        running = false
        progress = nil
        task = nil
        if let m { message = m }
    }
}
