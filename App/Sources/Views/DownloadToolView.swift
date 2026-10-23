import SwiftUI
import VirComKit

/// "Send Files to Device" — VirCom's "ZLAN webpage & code download tool".
struct DownloadToolView: View {
    @Bindable var model: AppModel
    @Bindable private var tool: DownloadToolModel
    @State private var sheet: Sheet?
    @State private var confirmClear = false
    @State private var askPassword = false
    @State private var password = ""
    /// Bumped after anything changes files in the directory, so row statuses refresh.
    @State private var refresh = 0

    enum Sheet: String, Identifiable {
        case mqtt, modbus, register, state
        var id: String { rawValue }
    }

    init(model: AppModel) {
        self.model = model
        tool = model.downloads
    }

    var body: some View {
        Form {
            Section {
                Picker("Send", selection: $tool.kind) {
                    Text("Web pages and configuration (folder)").tag(DownloadKind.webpage)
                    Text("Firmware file").tag(DownloadKind.code)
                }
                .pickerStyle(.radioGroup)
                folderRow
                if tool.kind == .code {
                    LabeledContent("Firmware file") {
                        HStack {
                            Text(tool.codeFile?.path ?? "None").truncationMode(.middle).lineLimit(1)
                            Spacer()
                            Button("Choose…") { tool.chooseCodeFile() }
                        }
                    }
                }
            } header: {
                Text("Content")
            } footer: {
                Text("Waveshare's manuals call this the \u{201C}Download Tool\u{201D}: it sends files from this Mac to the device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if tool.kind == .webpage {
                configSection
                scriptSection
            }
            Section("Device") {
                Picker("Device model/type", selection: $tool.deviceModel) {
                    ForEach(DownloadModel.allCases) { Text($0.title).tag($0) }
                }
                Picker("Flash size", selection: $tool.flashKB) {
                    ForEach(FlashImageBuilder.flashSizesKB, id: \.self) { Text("\(String($0)) KB").tag($0) }
                }
                Toggle("Remove spaces and line breaks from web pages", isOn: $tool.compressHTML)
                LabeledContent("Device ID") {
                    HStack {
                        TextField("Device ID", text: $tool.deviceID, prompt: Text("e.g. 287F8687676A"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        Button("Bind ID") { bindID() }.disabled(tool.deviceID.isEmpty)
                        if let id = tool.folder.flatMap(ConfigDirectory.boundID) {
                            Text("Folder is bound to \(id)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Connection") {
                Picker("Send through", selection: $tool.viaSerial) {
                    Text("Network").tag(false)
                    Text("Serial port").tag(true)
                }
                .pickerStyle(.segmented)
                if tool.viaSerial {
                    Picker("Serial port", selection: $tool.serialPort) {
                        SerialPortOptions()
                    }
                    Picker("Baud rate", selection: $tool.baudRate) {
                        ForEach([300, 600, 1200, 2400, 4800, 7200, 9600, 14400, 19200, 28800, 38400, 57600, 76800, 115_200, 230_400, 460_800], id: \.self) {
                            Text(String($0)).tag($0)
                        }
                    }
                } else {
                    TextField("Device IP address or domain", text: $tool.host, prompt: Text("e.g. 192.168.1.200"))
                    TextField("Update port (leave as is)", value: $tool.port, format: .number.grouping(.never))
                    Button("Clear web login key") { clearWebKey() }.disabled(tool.host.isEmpty)
                }
            }
            Section {
                HStack {
                    if let p = tool.progress {
                        ProgressView(value: Double(p.sent), total: Double(max(p.total, 1)))
                        Text("\(p.sent) / \(p.total)").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text("Close the device's web page in your browser before sending.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if tool.running {
                        Button("Stop") { tool.stop() }
                    } else {
                        Button("Send to Device") { tool.start() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(tool.viaSerial ? tool.serialPort.isEmpty : tool.host.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .id(refresh)
        .frame(minWidth: 620, minHeight: 640)
        .navigationTitle("Send Files to Device")
        .sheet(item: $sheet, onDismiss: { refresh += 1 }) { s in
            switch s {
            case .mqtt: MQTTConfigView(model: model)
            case .modbus: ModbusGatewayView(tool: tool)
            case .register: RegisterPacketView(tool: tool)
            case .state: StateTransferView(tool: tool)
            }
        }
        .alert(item: $tool.message) { m in Alert(title: Text(m.title), message: Text(m.text)) }
        .confirmationDialog("Remove all the config files?", isPresented: $confirmClear) {
            Button("Remove", role: .destructive) {
                if let dir = tool.requireFolder() { ConfigDirectory.clearAll(dir) }
                refresh += 1
            }
        } message: {
            Text("Deletes httpd.txt, mqtt.txt, json, jsonw and MB, and adds the filler file \"z\" so the old configuration is overwritten on the device.")
        }
        .alert("Decrypt httpd.txt", isPresented: $askPassword) {
            SecureField("Password", text: $password)
            Button("Decrypt") { decrypt() }
            Button("Cancel", role: .cancel) { password = "" }
        }
    }

    private var folderRow: some View {
        LabeledContent("Web page folder") {
            HStack {
                Menu(tool.folder?.lastPathComponent ?? "None") {
                    ForEach(tool.recentFolders, id: \.self) { url in
                        Button(url.path) { tool.folder = url }
                    }
                }
                .frame(maxWidth: 320)
                Button("Choose…") { tool.chooseFolder() }
                if let f = tool.folder {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([f]) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                }
            }
        }
    }

    /// Configuration files kept in the web page directory, one row each.
    private var configSection: some View {
        Section {
            configRow("MQTT", detail: "Broker, topics and login", file: ConfigFileName.mqtt, sheet: .mqtt)
            configRow("Modbus gateway (ZLMB)", detail: "Modbus RTU polls mapped to Modbus TCP", file: ConfigFileName.modbusGateway, sheet: .modbus)
            configRow("Register & heartbeat packets", detail: "Long register / heartbeat packets", file: nil, sheet: .register)
            configRow("State transfer", detail: "Command sequence state machine", file: ConfigFileName.stateTransfer, sheet: .state)
        } header: {
            Text("Configuration files")
        } footer: {
            Text(tool.folder == nil
                 ? "These are saved in the web page folder, so you'll be asked to choose one first (an empty folder is fine). Everything in the folder, including subfolders, is sent to the device. The JSON designers aren't available on macOS."
                 : "Saved in the web page folder and sent with the pages. Everything in the folder, including subfolders, is sent to the device. The JSON designers aren't available on macOS.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A whole-row button, like a Settings navigation row.
    private func configRow(_ title: String, detail: String, file: String?, sheet s: Sheet) -> some View {
        Button { open(s) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let file {
                    let present = tool.file(file).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                    Label(present ? "Configured" : "Not set", systemImage: present ? "checkmark.circle.fill" : "circle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(present ? .green : .secondary)
                        .font(.callout)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.callout.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("config.\(title)")
        .accessibilityHint("Edit \(title) settings")
    }

    private enum ScriptState { case none, plain, encrypted }

    private var scriptState: ScriptState {
        guard let bytes = tool.read(ConfigFileName.script) else { return .none }
        return ScriptEncryption.isEncrypted(bytes) ? .encrypted : .plain
    }

    /// httpd.txt (written by the Modbus gateway and register packet designers) and directory clean-up.
    private var scriptSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 12) {
                    switch scriptState {
                    case .none:
                        Text("None").foregroundStyle(.secondary)
                    case .plain:
                        Label("Plain text", systemImage: "lock.open").foregroundStyle(.secondary)
                        Button("Encrypt") { encrypt() }
                    case .encrypted:
                        Label("Encrypted", systemImage: "lock.fill").foregroundStyle(.green)
                        Button("Decrypt…") { askPassword = true }
                    }
                }
                .font(.callout)
            } label: {
                Text("Script file (httpd.txt)")
                Text("Encrypting hides the script from anyone reading the device's flash")
            }
            LabeledContent {
                Button("Clear All…", role: .destructive) { if tool.requireFolder() != nil { confirmClear = true } }
            } label: {
                Text("Remove all config files")
                Text("httpd.txt, mqtt.txt, MB, json and jsonw")
            }
        } header: {
            Text("Script & clean-up")
        }
    }

    private func open(_ s: Sheet) {
        if tool.requireFolder() != nil { sheet = s }
    }

    private func bindID() {
        guard let dir = tool.requireFolder() else { return }
        do {
            try ConfigDirectory.bind(dir, deviceID: tool.deviceID)
            tool.message = .init(title: "Bind ID", text: "Binding device ID succeeded! The ID\(tool.deviceID).txt file has been created in the web page folder. This folder can now only be sent to this device.")
        } catch {
            tool.message = .init(title: "Bind ID", text: error.localizedDescription)
        }
    }

    private func encrypt() {
        guard tool.requireFolder() != nil else { return }
        do {
            guard let plain = tool.read(ConfigFileName.script) else { throw DownloadError("There is no httpd.txt in this folder.") }
            try tool.write(ConfigFileName.script, try ScriptEncryption.encrypt(plain))
            tool.message = .init(title: "Encrypt", text: "httpd.txt is encrypted.")
            refresh += 1
        } catch {
            tool.message = .init(title: "Encrypt", text: error.localizedDescription)
        }
    }

    private func decrypt() {
        defer { password = "" }
        guard password == ScriptEncryption.decryptPassword else { return }
        do {
            guard let file = tool.read(ConfigFileName.script) else { throw DownloadError("There is no httpd.txt in this folder.") }
            try tool.write(ConfigFileName.script, try ScriptEncryption.decrypt(file))
            tool.message = .init(title: "Decrypt", text: "httpd.txt is decrypted.")
            refresh += 1
        } catch {
            tool.message = .init(title: "Decrypt", text: error.localizedDescription)
        }
    }

    private func clearWebKey() {
        let host = tool.host
        Task {
            do {
                try await WebLoginKey.clear(host: host)
                tool.message = .init(title: "Web key", text: "Clear login key!")
            } catch {
                tool.message = .init(title: "Web key", text: error.localizedDescription)
            }
        }
    }
}
