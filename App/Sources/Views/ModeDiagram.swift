import SwiftUI
import VirComKit

// Small explanatory diagrams for the bottom of some Device Settings panes. They are drawn from the
// settings currently in the form, not from what the device last reported, so they follow your edits.

// MARK: - Building blocks

/// One labelled box in a diagram.
struct DiagramNode: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    /// Greyed out: shown for completeness but not part of the active path.
    var dimmed = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(minWidth: 104)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

/// The line and arrowheads between two nodes.
// `nonisolated`: the app defaults to MainActor isolation, which a Shape conformance may not cross.
private nonisolated struct ArrowLine: Shape {
    let direction: DiagramArrow.Direction

    func path(in r: CGRect) -> Path {
        var p = Path()
        let y = r.midY, head: CGFloat = 4.5
        p.move(to: CGPoint(x: r.minX, y: y))
        p.addLine(to: CGPoint(x: r.maxX, y: y))
        if direction != .left {
            p.move(to: CGPoint(x: r.maxX - head, y: y - head))
            p.addLine(to: CGPoint(x: r.maxX, y: y))
            p.addLine(to: CGPoint(x: r.maxX - head, y: y + head))
        }
        if direction != .right {
            p.move(to: CGPoint(x: r.minX + head, y: y - head))
            p.addLine(to: CGPoint(x: r.minX, y: y))
            p.addLine(to: CGPoint(x: r.minX + head, y: y + head))
        }
        return p
    }
}

/// An arrow with a word above it and a note below.
struct DiagramArrow: View {
    nonisolated enum Direction { case right, left, both }
    let direction: Direction
    var caption: String? = nil
    var detail: String? = nil
    var dimmed = false

    var body: some View {
        VStack(spacing: 2) {
            Text(caption ?? " ")
                .font(.caption2)
                .foregroundStyle(dimmed ? .tertiary : .secondary)
            ArrowLine(direction: direction)
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .frame(height: 10)
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(minWidth: 118)
    }
}

/// The strip itself: a divider, a row of nodes and arrows, and a sentence underneath.
struct DiagramStrip<Content: View>: View {
    static var height: CGFloat { 168 }

    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                // A plain HStack, not a ScrollView: a horizontal ScrollView still grows to fill the
                // height it is offered, which pushed the strip to the bottom of an over-tall window.
                HStack(alignment: .center, spacing: 6) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        // A fixed height: anything flexible in here grows to fill whatever the pane offers, which
        // pushes the button bar off the bottom of the window.
        .frame(height: DiagramStrip.height)
        .clipped()
        .background(.bar)  // opaque: the form scrolls underneath this inset
    }
}

// MARK: - Work mode (Network pane)

/// What the chosen work mode actually does, with this form's ports and addresses in it.
struct WorkModeDiagram: View {
    let p: DeviceParameters

    private var serialSummary: String {
        let parity = ["N", "O", "E", "M", "S"][Int(p.parity.rawValue)]
        return "\(p.baudRate) \(p.dataBits)\(parity)\(p.twoStopBits ? 2 : 1)"
    }

    private var destination: String {
        p.destinationHost.isEmpty ? "no destination set" : "\(p.destinationHost):\(p.destinationPort)"
    }

    /// Capabilities byte 0x68 bit 7: the device accepts more than one TCP connection at a time.
    private var multiTCP: Bool { p.capabilities.contains(.multiTCP) }

    private var destinationNote: String {
        p.dynamicDestination ? "or whoever sent last" : "always this address"
    }

    var body: some View {
        DiagramStrip(caption: caption) {
            networkSide
            arrows
            DiagramNode(systemImage: "shippingbox", title: "This device", subtitle: "port \(p.devicePort)")
            DiagramArrow(direction: .both, caption: "serial", detail: serialSummary)
            DiagramNode(systemImage: "cable.connector", title: "Serial device", subtitle: "RS232 / 485 / 422")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Diagram of \(p.workMode.title) mode. \(caption)")
        .accessibilityIdentifier("diagram.workMode")
    }

    @ViewBuilder private var networkSide: some View {
        switch p.workMode {
        case .tcpServer:
            DiagramNode(systemImage: multiTCP ? "macwindow.on.rectangle" : "desktopcomputer",
                        title: multiTCP ? "Several computers" : "Any computer",
                        subtitle: "connect in to port \(p.devicePort)")
        case .tcpClient:
            DiagramNode(systemImage: "desktopcomputer", title: destination, subtitle: "the device dials out")
        case .udp:
            DiagramNode(systemImage: "desktopcomputer", title: "Any sender",
                        subtitle: "to port \(p.devicePort)")
        case .udpGroup:
            DiagramNode(systemImage: "dot.radiowaves.left.and.right", title: "Group \(p.udpGroupIP)",
                        subtitle: "senders join here")
        }
    }

    @ViewBuilder private var arrows: some View {
        switch p.workMode {
        case .tcpServer:
            DiagramArrow(direction: .both, caption: "TCP",
                         detail: multiTCP ? "all merged onto the line" : "they connect in")
        case .tcpClient:
            DiagramArrow(direction: .both, caption: "TCP", detail: "device keeps it up")
        case .udp, .udpGroup:
            DiagramArrow(direction: .both, caption: "UDP in / out", detail: "out → \(destination)")
        }
    }

    private var caption: String {
        switch p.workMode {
        case .tcpServer:
            multiTCP
            ? "TCP Server: the device waits for computers to connect to port \(p.devicePort). It reports Multi-TCP Connection, so several can be connected at once and everything they send is merged onto the one serial line. Nothing moves until someone connects, and the Destination fields are unused."
            : "TCP Server: the device waits, and a computer opens the connection to port \(p.devicePort). It does not report Multi-TCP Connection, so treat it as one connection at a time. Nothing moves until someone connects, and the Destination fields are unused."
        case .tcpClient:
            "TCP Client: the device opens the connection to \(destination) itself and reopens it if it drops."
        case .udp:
            p.dynamicDestination
            ? "UDP: anything sent to port \(p.devicePort) goes out the serial port — from any number of senders. Serial data goes back to whoever sent to the device last, starting with \(destination)."
            : "UDP: anything sent to port \(p.devicePort) goes out the serial port — from any number of senders. Serial data always goes to \(destination), whoever sent it."
        case .udpGroup:
            p.dynamicDestination
            ? "UDP Group: the device joins \(p.udpGroupIP), and anything sent to that group on port \(p.devicePort) goes out the serial port. Other software can join the group to hear the same traffic. Serial data goes back to whoever sent last, starting with \(destination)."
            : "UDP Group: the device joins \(p.udpGroupIP), and anything sent to that group on port \(p.devicePort) goes out the serial port. Other software can join the group to hear the same traffic. Serial data always goes to \(destination) — set that to the group address to let every listener hear the replies."
        }
    }
}

// MARK: - Extra destinations

/// Where serial data is copied to: the main destination plus whatever is filled in here.
struct DestinationsDiagram: View {
    let mainDestination: String
    let extras: [MoreAdvancedSettings.Destination]
    /// TCP Server mode never sends to a destination of its own choosing.
    let sendsToDestinations: Bool

    private var used: [String] {
        extras.filter { !$0.host.isEmpty }.map { $0.port == 0 ? $0.host : "\($0.host):\($0.port)" }
    }

    var body: some View {
        DiagramStrip(caption: caption) {
            DiagramNode(systemImage: "cable.connector", title: "Serial device", subtitle: "sends data in")
            DiagramArrow(direction: .right, caption: "serial")
            DiagramNode(systemImage: "shippingbox", title: "This device", subtitle: "one copy per address")
            DiagramArrow(direction: .right, caption: used.isEmpty ? "to" : "a copy to each", dimmed: !sendsToDestinations)
            DiagramNode(systemImage: "desktopcomputer",
                        title: mainDestination.isEmpty ? "no destination set" : mainDestination,
                        subtitle: "Destination (Network)",
                        dimmed: !sendsToDestinations)
            if used.isEmpty {
                DiagramNode(systemImage: "plus", title: "no extras yet", subtitle: "up to 7 more", dimmed: true)
            } else {
                DiagramNode(systemImage: "arrow.triangle.branch",
                            title: used.count == 1 ? used[0] : "+ \(used.count) more",
                            subtitle: used.count == 1 ? "extra 1" : used.prefix(2).joined(separator: ", "),
                            dimmed: !sendsToDestinations)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Diagram of extra destinations. \(caption)")
        .accessibilityIdentifier("diagram.destinations")
    }

    private var caption: String {
        if !sendsToDestinations {
            return "In TCP Server mode the device only answers whoever connected to it, so these extra destinations are not used."
        }
        if used.isEmpty {
            return "Serial data goes only to the Destination set in the Network pane. Fill in an address here and every frame is copied to it as well — useful for a logger or a second controller watching the same stream."
        }
        return "Every frame from the serial port is sent to \(used.count + 1) addresses: the Destination in the Network pane, plus the \(used.count) here. They are separate copies, so a listener that misses one does not affect the others."
    }
}

// MARK: - RS485 bus

/// Why the multi-host and conflict-detection timers exist, and when they do nothing.
struct RS485BusDiagram: View {
    let multiHost: Bool
    let multiHostWaitMs: Int
    let conflictDetection: Bool
    let busIdleMs: Int

    private var shared: Bool { multiHost || conflictDetection }

    var body: some View {
        DiagramStrip(caption: caption) {
            DiagramNode(systemImage: "shippingbox", title: "This device",
                        subtitle: shared ? "one of several hosts" : "the only host")
            DiagramArrow(direction: .both,
                         caption: shared ? "A / B — shared" : "A / B",
                         detail: shared ? "one talker at a time" : "point to point")
            DiagramNode(systemImage: "cable.connector", title: shared ? "Slaves" : "Slave",
                        subtitle: shared ? "all on the same pair" : "answers when asked")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Diagram of the RS485 bus. \(caption)")
        .accessibilityIdentifier("diagram.rs485")
    }

    private var caption: String {
        var parts: [String] = []
        if multiHost {
            parts.append("Multi-host is on: after this device sends a query it keeps the line to itself for up to \(multiHostWaitMs) ms waiting for the reply, so a second host cannot talk over the answer.")
        }
        if conflictDetection {
            parts.append("Conflict detection is on: the device listens first and only starts sending after \(busIdleMs) ms of silence.")
        }
        if parts.isEmpty {
            parts.append("Both timers are off, so the device sends whenever it has data. That is the right setting when it is the only host on the line.")
        }
        parts.append("These two settings only do something on RS485, where every device shares one pair of wires and has to take turns. RS232 and RS422 give each direction its own wire, so they are ignored there.")
        return parts.joined(separator: " ")
    }
}
