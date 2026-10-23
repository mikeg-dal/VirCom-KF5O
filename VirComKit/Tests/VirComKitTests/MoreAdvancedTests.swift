import Foundation
import Testing
@testable import VirComKit

@Suite struct MoreAdvancedTests {
    @Test func tlvSetReplacesAndRemoves() {
        var p = DeviceParameters.blank
        #expect(ParameterTLV.set(2, Array("ssid".utf8), in: &p))
        #expect(ParameterTLV.set(5, [0x81], in: &p))
        #expect(ParameterTLV.set(2, Array("net".utf8), in: &p))  // replaced, moves to the end
        #expect(Array(p.raw[0x73..<0x7C]) == [5, 1, 0x81, 2, 3, 0x6E, 0x65, 0x74, 0])
        ParameterTLV.set(5, nil, in: &p)
        #expect(ParameterTLV.get(5, in: p) == nil)
        #expect(ParameterTLV.get(2, in: p) == Array("net".utf8))
        #expect(!ParameterTLV.set(9, [UInt8](repeating: 1, count: 60), in: &p))
    }

    @Test func roundTrip() throws {
        var s = MoreAdvancedSettings()
        s.wifiMode = .station
        s.ssid = "lab"
        s.encryption = 4
        s.wifiKey = "secret12"
        s.apChannel = 6
        s.vlanEnabled = true
        s.vlanID = 100
        s.vlanPriority = 5
        s.destinations[0] = .init(host: "10.0.0.5", port: 4196)
        s.destinations[1] = .init(host: "10.0.0.6", port: 502)
        s.multiHostEnabled = true
        s.multiHostWaitMs = 256
        s.conflictDetection = true
        s.conflictMode = 2
        s.busIdleMs = 20
        s.frameEndByte = "0D"
        s.pingDetect = true
        s.keyOnTCPConnect = true
        var p = DeviceParameters.blank
        p.raw[0x6E] = 0x01  // restart-for-no-data must survive
        try s.apply(to: &p)
        #expect(p.raw[0x71] == 9)
        #expect(p.raw[0x37] == 2 && p.raw[0x35] == 0x0D && p.raw[0x36] == 20)
        #expect(p.raw[0x6E] == 0x41 && p.raw[0x72] == 0x02)
        #expect(ParameterTLV.get(7, in: p) == [10, 0, 0, 5, 0x10, 0x64, 10, 0, 0, 6, 0x01, 0xF6])
        #expect(ParameterTLV.get(6, in: p) == [100, 0xA0])
        #expect(ParameterTLV.get(5, in: p) == [0x84])
        let back = MoreAdvancedSettings(p)
        var expected = s
        expected.supported = []
        #expect(back == expected)
        #expect(back.gatewayType == .multiHostNonStorage)
    }

    @Test func domainDestinations() throws {
        var s = MoreAdvancedSettings()
        s.destinations[0] = .init(host: "a.example.com", port: 80)
        s.destinations[1] = .init(host: "10.0.0.6", port: 81)
        var p = DeviceParameters.blank
        try s.apply(to: &p)
        #expect(ParameterTLV.get(7, in: p) == nil)
        #expect(ParameterTLV.get(11, in: p) == [0, 80] + Array("a.example.com".utf8) + [0, 0, 81] + Array("10.0.0.6".utf8) + [0])
        #expect(MoreAdvancedSettings(p).destinations[1] == .init(host: "10.0.0.6", port: 81))
    }

    @Test func timings() {
        #expect(MoreAdvancedSettings.minimumTimes(baudIndex: 4) == (4 * 33 + 110 + 20, 20))  // 9600
        #expect(MoreAdvancedSettings.minimumTimes(baudIndex: 0).idle == 101)                  // 1200
    }
}

@Suite struct FourGTests {
    @Test func commands() {
        #expect(FourGCommand.query("BAUD") == Array("ZL+BAUD?\r\n".utf8))
        #expect(FourGCommand.set("PPORT", "4196") == Array("ZL+PPORT=4196\r\n".utf8))
        #expect(FourGCommand.login("123456") == Array("ZL+LOGIN=123456\r\n".utf8))
        // GBK, as the module expects.
        #expect(FourGCommand.set("PROTOCOL", "双向透传") == Array("ZL+PROTOCOL=".utf8) + [0xCB, 0xAB, 0xCF, 0xF2, 0xCD, 0xB8, 0xB4, 0xAB] + [13, 10])
    }

    @Test func parsesReplies() {
        let r = FourGCommand.parse("+BAUD:115200\r\n+ZL_MODE:2\r\nnoise\r\n+LOGIN:OK\r\n")
        #expect(r.map(\.0) == ["BAUD", "MODE", "LOGIN"])
        #expect(r[0].1 == "115200")
    }
}

@Suite struct SerialDeviceTests {
    @Test func frames() {
        #expect(DownloadCRC.bytes([0x92, 0x11, 0x09]) == [0x1C, 0x7B])
        #expect(DownloadCRC.bytes([0x92, 0x00, 0x02]) == [0x51, 0xEC])
        #expect(SerialFrame.writeParameters(.blank).count == 128)
        #expect(SerialFrame.writeByte(offset: 0x31, value: 4).suffix(4) == [1, 0x31, 1, 4])
    }

    @Test func loraRoundTrip() throws {
        var s = LoRaSettings()
        s.spreadingFactor = 10
        s.frequency = 470
        s.bandwidth = 8
        let frame = s.writeFrame
        #expect(frame.count == 25)
        #expect(Array(frame[10..<13]) == [0x93, 0x11, 0x0A])
        // A module reply carries the same 10 data bytes plus CRC.
        let reply = Array(frame[13..<23]) + DownloadCRC.bytes(frame[13..<23])
        let back = try #require(LoRaSettings(reply: reply))
        #expect(back.frequency == 470 && back.spreadingFactor == 10 && back.bandwidth == 8)
        #expect(LoRaSettings(reply: Array(reply.dropLast()) + [0]) == nil)
    }

    @Test func zigbeeRoundTrip() throws {
        let reply: [UInt8] = [0xA2, 0x12, 0x34, 0x05, 0x07, 0x03, 0x01, 0x06, 0x01, 0x01, 0x02, 0x0A, 0x0B, 0x00, 0x01]
        let z = try #require(ZigbeeSettings(reply: reply))
        #expect(z.nodeAddress == 0x1234 && z.netID == 5 && z.netType == 7 && z.nodeType == 3 && z.channel == 11)
        #expect(z.writeFrame == [0x23, 0xFE] + Array(reply[1...]))
    }

    @Test func identifiesRadios() {
        #expect(SerialSearch.radioKind([0, 0x97, 0, 0x6F, 0x80, 1]) == .lora)
        #expect(SerialSearch.radioKind([0x03, 5, 0x20, 0x03]) == .fourG)
        #expect(SerialSearch.radioKind([1, 2, 3]) == nil)
    }
}

@Suite struct RegisterPacketFieldTests {
    @Test func roundTrip() throws {
        var r = DeviceRegisterPacket()
        r.enabled = true
        r.content = "01 02"
        r.port = 0x1064
        var p = DeviceParameters.blank
        try r.apply(to: &p)
        #expect(Array(p.raw[0x82..<0x8A]) == Array("01 02".utf8) + [0, 0x10, 0x64])
        #expect(DeviceRegisterPacket(p) == r)
        var ascii = DeviceRegisterPacket()
        ascii.enabled = true
        ascii.content = "AB"
        try ascii.apply(to: &p, asciiText: true)
        #expect(DeviceRegisterPacket(p).content == "41 42")
    }

    @Test func refusesWhenOptionsInUse() {
        var p = DeviceParameters.blank
        ParameterTLV.set(2, Array("a-long-wifi-ssid".utf8), in: &p)
        var r = DeviceRegisterPacket()
        r.enabled = true
        r.content = "01"
        #expect(throws: DownloadError.self) { try r.apply(to: &p) }
    }
}

@Suite struct BatchEditTests {
    func device(_ last: UInt8, id: UInt8) -> DeviceParameters {
        var p = DeviceParameters.blank
        p.ip = IPv4(192, 168, 1, last)
        p.raw[0x24] = id
        p.name = "dev"
        p.destinationPort = 4196
        return p
    }

    @Test func policies() {
        let a = device(10, id: 1), b = device(20, id: 2), c = device(15, id: 3)
        var edited = a
        edited.ip = IPv4(192, 168, 2, 12)
        edited.name = "line"
        var batch = BatchEdit()
        let out = batch.apply(edited: edited, original: a, to: [b, a, c])
        #expect(out.map(\.ip.description) == ["192.168.2.12", "192.168.2.17", "192.168.2.22"])
        #expect(out.map(\.name) == ["line1", "line2", "line3"])
        #expect(out.map { $0.raw[0x24] } == [1, 3, 2])
        batch.ipPolicy = .increment
        batch.portPolicy = .increment
        let inc = batch.apply(edited: edited, original: a, to: [a, b, c])
        #expect(inc.map(\.ip.description) == ["192.168.2.12", "192.168.2.13", "192.168.2.14"])
        #expect(inc.map(\.destinationPort) == [4196, 4197, 4198])
    }
}

@Suite(.serialized) struct WriteGuardTests {
    @Test func blocksWritesInTestMode() async {
        UserDefaults.standard.set(true, forKey: "VirComBlockDeviceWrites")
        defer { UserDefaults.standard.removeObject(forKey: "VirComBlockDeviceWrites") }
        await #expect(throws: DownloadError.self) {
            try await ManagementClient().write(.blank)
        }
        await #expect(throws: DownloadError.self) {
            _ = try await NetworkDownloader(host: "127.0.0.1", model: .zlsn2003, kind: .webpage, flashKB: 128)
                .run(FlashImage(bytes: [1], usedLength: 1)) { _ in }
        }
    }
}
