import SwiftUI
import VirComKit

/// Picker contents listing /dev/cu.* ports, or a placeholder when none are connected.
struct SerialPortOptions: View {
    var body: some View {
        let ports = SerialLink.availablePorts()
        if ports.isEmpty {
            Text("None connected").tag("")
        } else {
            Text("Choose a port").tag("")
            ForEach(ports, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
        }
    }
}
