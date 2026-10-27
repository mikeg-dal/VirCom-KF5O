# VirCom for macOS

A native macOS port of **VirCom 5.68** (ZLAN ZLVircom, Waveshare build), the tool Waveshare ships for
finding and configuring its serial-to-Ethernet servers. It also provides virtual serial ports bridged
to them over TCP. Waveshare only provides VirCom for Windows, and there was no native Mac app, so this
is one.

> [!WARNING]
> **Use at your own risk.** This is independent software by Mike (KF5O): an unofficial Mac port of a
> Windows tool. It is not affiliated with, endorsed by, or supported by Waveshare or ZLAN. Waveshare,
> ZLAN and VirCom are their owners' trademarks.
>
> It can change settings on real hardware. A wrong network or serial setting can leave a device
> unreachable until it is reset, and some commands switch physical loads (relays). Check what you send
> before you send it, and try anything new on a device you can afford to reset first. The software is
> provided as is, without warranty of any kind; see [LICENSE](LICENSE).

Built with Swift 6 language mode and Swift 6.2 concurrency settings, SwiftUI and AppKit.

## Requirements

- macOS 27 or later, on Apple silicon. There is no Intel build.
- The device on the same network as the Mac (or reachable by IP), or a USB serial adapter for the
  serial tools. macOS asks for Local Network access the first time the app searches.

## Build

There are no prebuilt downloads; build it from source. You need Xcode 27 and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
UNSIGNED=1 ./build.sh               # no Apple Developer account needed; app runs on this Mac → ./dist/VirCom.app
./build.sh                          # xcodegen → unit tests → Release archive → Developer ID export to ./dist
NOTARY_PROFILE=myprofile ./build.sh   # also notarize + staple
```

Signing uses a *Developer ID Application* identity from the login keychain; set `TEAM_ID=<your team ID>`
to sign with your own team. Requirements: Xcode 27, XcodeGen.

`VirComKit/` holds the protocol, discovery and bridge code (`swift test`: 38 tests). They include a
parameter block captured read-only from a real Waveshare device, a simulated device, and a real
pty ↔ TCP round trip. The protocol, recovered from the Windows binary, is documented in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

UI tests (`VirComUITests`, XCUITest, 12 tests) open every menu, window, sheet and tab:

```sh
xcodebuild test -project VirCom.xcodeproj -scheme VirCom
```

They launch the app with `-VirComBlockDeviceWrites YES`, which makes every device write (Modify Setting,
Restart, Modify Key, downloads, serial writes, clearing the web key) fail with a "Blocked (test mode)"
message, so they're safe to run with real devices on the network. They also pass
`-VirComSampleDevice YES`, which replaces the network search with one made-up device, so the tests
run the same on any Mac with no hardware attached. Key controls carry accessibility identifiers
(`pane.Network`, `modifySetting`, `toolbar.modifyKey`, `config.MQTT`, …) that the tests use.

Device Settings is one window: a sidebar (Device, Network, Serial, Options, WiFi, RS485, Destinations,
Proxy & VLAN, Functions, Raw Bytes), actions in the toolbar, and one Modify Setting that sends every pane.

## What's ported

| VirCom feature | macOS port |
|---|---|
| Auto search (UDP broadcast, port 1092), including devices on other subnets | ✅ broadcasts per interface (macOS needs this to reach 255.255.255.255) |
| Add manually / search IP range (unicast), remembered | ✅ |
| Device list: type, name, IP, ports, work mode, destination, bound COM, ID, serial settings | ✅ |
| Device Settings: network, serial, advanced, framing, capability display, firmware version | ✅ only known fields change; every other byte is sent back unchanged |
| Get Default, Restart Device, Modify Setting, Modify Key (wrong-key detection) | ✅ |
| Open the device web page | ✅ |
| Virtual serial ports: TCP client (connect to device) or TCP server (device connects in) | ✅ as pseudo-terminals (`/dev/ttys…`) |
| Bind a port to a device, batch create with IP/port increase | ✅ |
| Register ID, login key, heartbeat packet and interval | ✅ |
| Auto reconnect, start/stop service | ✅ |
| Data monitor (sent/received, hex, timestamps, buffer size) | ✅ |
| Software settings, Export/Import Setting | ✅ (JSON) |
| Tray icon | ✅ menu bar extra; ports keep running with no window open |
| More Advanced Settings (now sidebar panes of Device Settings): WiFi, VLAN, multiple destinations (IP or names), proxy, RS485 multi-host / conflict detection / Modbus gateway type, function switches | ✅ |
| Register packet (Device Settings), Save As Default / Load Default, device-ID QR code | ✅ |
| Multi-device editing (IP / destination port / name strategies) | ✅ |
| Send Files to Device (VirCom's "webpage & code download tool"): web page folder packing, firmware files, sending over the network (all three model protocols) or serial | ✅ |
| MQTT config (incl. Alibaba/Baidu/OneNET presets), Modbus gateway (ZLMB), register/heartbeat packet, state transfer designers; Bind ID, Clear all, httpd.txt encrypt/decrypt, clear web login key | ✅ files are byte-compatible with VirCom's |
| Search With Serial Port (serial servers, ZLAN9700 LoRa, ZLAN9500 Zigbee, 4G modules) | ✅ |
| ZLAN9700/9743 LoRa and ZLAN9500 Zigbee settings | ✅ |
| 4G Config Tools and its Advanced Parameters (ZL+ AT commands) | ✅ |

## Differences from Windows

- **Virtual COM ports are pseudo-terminals.** macOS can't add named `COMn` devices without a kernel or
  DriverKit driver. Apps open the `/dev/ttys…` path shown in the main window (right-click → Copy Port Path),
  like a USB adapter. A changing baud rate on the virtual port isn't forwarded to the device ("serial
  parameter auto adapt" / REAL_COM on-the-fly changes); set the device's serial settings in Device Settings.
- **Not ported:**
  - The JSON-to-Modbus / JSON-to-serial designers (json, json2, jsonw files and their httpd.txt script)
  - P2P/N2N and the XNDNS service (they depend on ZLAN's cloud servers)
- Mark parity isn't available on macOS. Serial servers listen with mark parity in configuration mode,
  so VirCom for macOS sends with two stop bits instead, which is identical on the wire.
- Send Files to Device has been confirmed on real hardware only for web pages over the network (a Waveshare
  RS485 TO ETH (B), 2026-10-23). Firmware files, sending over serial, the serial tools and radio settings haven't been
  tested on hardware; their formats were recovered from the Windows binary and checked against its own
  CRC and AES routines.
- Some firmware sends nothing for `http://device/` and only serves named pages, so Open Web Page tries
  `/`, then `/index.html`, then `/index.htm`.
- The original sent an unsolicited datagram to `www.i-zlan.com:4196` on startup. This port doesn't.

## License

GPL-3.0. See [LICENSE](LICENSE).
