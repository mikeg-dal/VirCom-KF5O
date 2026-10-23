import Foundation
import Testing
@testable import VirComKit

@Suite struct DownloadTests {
    @Test func crcMatchesOriginalRoutine() {
        // Values produced by VirCom's own CRC routine (0x44d6e0).
        #expect(DownloadCRC.value(Array(0..<20)) == 0x8E6F)
        #expect(DownloadCRC.value([0x93, 0x0C, 0x01, 0x01, 0x00, 0x00, 0x02, 0x79, 0x43, 0x28]) == 0xE336)
        #expect(DownloadCRC.value(Array("abc".utf8), initial: 0x1234) == 0x8E52)
        #expect(DownloadCRC.value(Array("123456789".utf8)) == 0x374B)
    }

    @Test func aesMatchesOriginalCipher() throws {
        // VirCom's AES routine encrypts 00…0F under its key to this block.
        let ct = try ScriptEncryption.crypt(Array(0..<16), operation: 0)
        #expect(ct == [0x9c, 0xb5, 0xd1, 0x06, 0xb3, 0x72, 0x80, 0xeb, 0x4f, 0x17, 0x7f, 0x4b, 0xab, 0x95, 0x7c, 0x03])
    }

    @Test func encryptRoundTrip() throws {
        let plain = Array("N2S: N[0...len]\r\nS2N: S[0...len]\r\n".utf8)
        let enc = try ScriptEncryption.encrypt(plain)
        #expect(Array(enc[0..<8]) == [0, 0, 0, 2, 0, 0, 0, UInt8(plain.count)])
        #expect((enc.count - 8) % 16 == 0)
        #expect(try ScriptEncryption.decrypt(enc) == plain)
        #expect(ScriptEncryption.isEncrypted(plain) == false)
    }

    @Test func flashImageRecords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("img"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("<html>\n  <b>x</b>\n</html>".utf8).write(to: dir.appendingPathComponent("index.htm"))
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("img/a.bin"))

        let big = try FlashImageBuilder.build(directory: dir, flashKB: 128, compressHTML: true)
        // "img" sorts before "index.htm".
        var expect: [UInt8] = [0xFA, 0xF3, 0xEA, 0xD3] + Array("/img/a.bin".utf8) + [0, 0, 0, 0, 3, 1, 2, 3]
        let html = Array("<html><b>x</b></html>".utf8)
        expect += [0xFA, 0xF3, 0xEA, 0xD3] + Array("/index.htm".utf8) + [0, 0, 0, 0, UInt8(html.count)] + html
        #expect(Array(big.bytes.prefix(big.usedLength)) == expect)
        #expect(big.bytes.count == 128 * 1024)

        let small = try FlashImageBuilder.build(directory: dir, flashKB: 7, compressHTML: false)
        #expect(Array(small.bytes.prefix(15)) == [0xFA, 0xF3] + Array("/img/a.bin".utf8) + [0, 3, 0])
    }

    @Test func packetLayouts() {
        let data = [UInt8](repeating: 0xAA, count: 128)
        let s = DownloadPacket.sequenced(offset: 0x1000, chunk: data[0..<128], flag: 0x81)
        #expect(s.count == 140)
        #expect(Array(s[0..<9]) == [0x5A, 0x4C, 0x11, 0, 0, 0x10, 0, 0, 0x80])
        #expect(s[11] == 0x81 && s[12] == 0xAA)
        var zeroed = s
        zeroed[9] = 0; zeroed[10] = 0
        #expect(Array(s[9...10]) == DownloadCRC.bytes(zeroed[3..<140]))

        let w = DownloadPacket.windowed(offset: 64, chunk: data[0..<10], last: true)
        #expect(Array(w[0..<11]) == [0x5A, 0x4C, 0x11, 0, 0, 0, 64, 0, 10, 1, 0xAA])

        let l = DownloadPacket.legacy(offset: 0, chunk: data[0..<64])
        #expect(Array(l[0..<8]) == [0x5A, 0x4C, 0x11, 0xD4, 0x00, 0x00, 0x40, 0xAA])
        #expect(DownloadPacket.sectorRounded(4096) == 4096 && DownloadPacket.sectorRounded(4097) == 8192)
    }

    @Test func serialStartFrame() {
        let f = SerialDownloader.startFrame(length: 0x279, data: [UInt8](repeating: 0, count: 0x279), kind: .webpage)
        #expect(f.count == 22)
        #expect(Array(f[10..<18]) == [0x93, 0x0C, 0x01, 0x01, 0x00, 0x00, 0x02, 0x79])
        #expect(Array(f[20..<22]) == DownloadCRC.bytes(f[10..<20]))
    }

    @Test func mqttFile() {
        var c = MQTTConfig()
        c.password = "pw"
        let text = c.fileText
        #expect(text.hasPrefix("[MQTT]\r\nVER=4\r\nCLIENT_ID=zlanid\r\nUSERNAME=btjzew4/zlanname\r\nPASSWD=pw\r\nKEEPALIVE=60\r\n"))
        #expect(text.hasSuffix("PUBLISH_TOPIC=zlansub\r\nPUBLISH_QOS=1\r\nPUBLISH_RETAIN=0\r\n"))
        #expect(MQTTConfig(fileText: text).password == "pw")
    }

    @Test func registerScript() throws {
        var c = RegisterPacketConfig()
        c.heartbeatPacket = "AB"
        c.heartbeatIsASCII = true
        c.heartbeatInterval = 30
        c.registerPacket = "01 02"
        let s = try #require(try c.script(existingScript: nil))
        // 30 s = 30000 = 0x7530 → "00 75"
        #expect(s == "N2S: N[0...len]\r\nS2N: S[0...len]\r\nI2N: = 00 75 ADD[1] 00 00\r\nT2N: 41 42  = 00 01\r\nREG: 01 02\r\n")
        var r = RegisterPacketConfig()
        r.registerPacket = "01"
        #expect(try r.script(existingScript: nil) == "\r\nN2S: N[0...len]\r\nS2N: S[0...len]\r\nREG: 01")
    }

    @Test func modbusGatewayScript() {
        var a = ModbusGatewayCommand()
        a.slaveAddress = 1; a.function = 3; a.registerAddress = 0x10; a.length = 2
        var b = ModbusGatewayCommand()
        b.slaveAddress = 2; b.function = 1; b.registerAddress = 0; b.length = 20; b.supportsWrite = true
        b.queryInterval = 300; b.replyTimeout = 500
        var list = [a, b]
        #expect(ModbusGatewayScript.assignAddresses(&list) == 4)  // 2 registers + 20 coils (2 words)
        #expect(list[1].tcpRegisterAddress == 32)
        let s = ModbusGatewayScript.script([a, b])
        #expect(s.contains("MI16[8027...med]"))  // 9*2 + 0x1F49
        #expect(s.contains("T2M: M[0...8] 00 1B 01 03 00 10 00 02 03 00 1F 02 01 00 00 00 14 03 = 00 11\r\n"))
        #expect(s.contains("N2N: N[0...len] = N[0...6] 05 00 IRANGE8[8243] N[10...len]\r\n"))
        #expect(s.contains("I2M: M[36] = 01 2C STATE[1] 00 0C\r\n"))
        #expect(s.contains("I2M: 00 = 01 F4 STATE[1] 00 0C\r\n"))
        #expect(ModbusGatewayScript.parseDesignFile(ModbusGatewayScript.designFile([a, b])).map(\.length) == [2, 20])
    }

    @Test func stateFile() {
        var s0 = TransferState(number: 0)
        s0.command = "01 02"
        s0.delayEnabled = true
        var s1 = TransferState(number: 1)
        s1.sendsCommand = false
        let f = StateTransferFile.encode([s0, s1])
        #expect(f == [0, 2,
                      0, 0, 0, 100, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 2, 1, 2,
                      0, 1, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 2, 0, 0])
    }

    @Test func binding() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ConfigDirectory.bind(dir, deviceID: "287F8687676A")
        #expect(ConfigDirectory.boundID(dir) == "287F8687676A")
        #expect(throws: DownloadError.self) { try ConfigDirectory.checkBinding(dir, deviceID: "000000000000") }
        ConfigDirectory.clearAll(dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("z").path))
    }

    @Test func hexHelpers() {
        #expect(ScriptText.hex("A1") == "41 31 ")
        #expect(ScriptText.parseHex("12 ab,f") == [0x12, 0xAB, 0x0F])
    }
}
