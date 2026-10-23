# ZLAN / Waveshare device management protocol (as used by VirCom 5.68)

Recovered from `VirCom_en.exe` (SHA-256 `8324d897…1199`) with REA/Ghidra. The function addresses
below refer to that binary. Items marked *(inferred)* weren't directly observed.

## Transport

- UDP. Devices listen on **port 1092** (0x0444).
- Searches and parameter writes are **broadcast to 255.255.255.255:1092** with `SO_BROADCAST`. VirCom binds
  its configured local port and falls back to any port (`0x42ee90`, `0x42f320`).
- A key change (command `0x0B`) is sent unicast to the device's own reply address (`0x42f320`).
- Range search ("Search List") sends the search packet unicast to each IP of a range, on the
  management port (default 1092) (`0x412ba0`).

## Packet (170 bytes)

| Offset | Size | Meaning |
|---|---|---|
| 0 | 2 | Magic `5A 4C` ("ZL", `htons(0x5A4C)`) |
| 2 | 1 | Command |
| 3 | 167 | Parameter block (below) |

Commands: `0x00` search, `0x01` search reply / parameters, `0x02` write parameters (the device restarts
to apply them), `0x0B` write parameters with key change, `0x0C` reply "old key is wrong".
`0x03`/`0x07` change serial parameters on the fly (`0x42f5e0`); macOS has no virtual COM driver to
feed these, so they aren't used.

Replies shorter than 41 bytes, or with the wrong magic or command, are ignored. Replies shorter than
170 bytes fill only the first `len-3` parameter bytes (`0x42ea90`).

## Parameter block

Offsets are from the start of the 167-byte block. Multi-byte integers are big-endian, and IPv4
addresses are in network order.

| Off | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 4 | IP address | |
| 0x04 | 4 | Subnet mask | |
| 0x08 | 4 | Gateway | |
| 0x0C | 4 | Destination IP | resolved from the domain when the device lacks DNS support |
| 0x10 | 2 | Device (local) port | default 4196 |
| 0x12 | 2 | Destination port | default 4196 |
| 0x14 | 1 | Work mode | 0 TCP Server, 1 TCP Client, 2 UDP, 3 UDP Group |
| 0x15 | 10 | Device type string | e.g. `ZLSN2000`; also carries the *new key* for command 0x0B |
| 0x1F | 6 | Device ID | shown as `%02X%02X%08X`; bytes 0x21–0x24 are the lookup key |
| 0x25 | 1 | Baud index | 0:1200 1:2400 2:4800 3:7200 4:9600 5:14400 6:19200 7:28800 8:38400 9:57600 10:76800/921600 11:115200 12:230400 13:460800 14:300 15:600 |
| 0x26 | 10 | Device name | NUL-terminated, max 9 chars; carries the *old key* for 0x0B |
| 0x30 | 1 | Parity | 0 None, 1 Odd, 2 Even, 3 Mark, 4 Space |
| 0x31 | 1 | Max packet interval (ms) | default 3 |
| 0x32 | 2 | Max frame length (bytes) | default 1300 |
| 0x34 | 4 | (cleared by "Get Default") | *(inferred)* advanced flags |
| 0x38 | 1 | IP mode | 0 Static, 1 DHCP |
| 0x39 | 1 | Flow control | 0 None, 1 CTS/RTS, 2 DSR/DTR, 3 XON/XOFF |
| 0x3A | 1 | Destination mode | 0 Static, 1 Dynamic (default) |
| 0x3B | 1 | Data bits | 0 → 8, 1 → 7, 2 → 6, 3 → 5 |
| 0x3C | 1 | Transfer protocol | 0 None, 1 Modbus TCP, 2 REAL_COM |
| 0x3E | 4 | DNS server | default 8.8.4.4 |
| 0x42 | 30 | Destination domain / IP text | |
| 0x60 | 1 | Reconnect time (s) | default 12 |
| 0x61 | 1 | Keep-alive time (s) | default 60; "restart for no data" time is ×5 s |
| 0x62 | 2 | HTTP port | default 80 |
| 0x64 | 1 | Port number (low 6 bits) | shown as "PORTn" |
| 0x67 | 1 | Firmware | displayed as `V1.%d` of value + 383 |
| 0x68 | 1 | Capabilities | bit0 web download, 1 DNS, 2 REAL_COM, 3 Modbus TCP→RTU, 4 serial commands, 5 DHCP, 6 storage extension, 7 multi-TCP |
| 0x69 | 4 | UDP group IP | default 230.90.76.1 |
| 0x6D | 1 | Register-packet byte (hex) | |
| 0x6E | 1 | Flags | bit0 restart for no data, bit1 send parameters periodically, bits2–7 advanced functions |
| 0x6F | 1 | Parameter send interval (min) | default 5 |
| 0x71 | 1 | (cleared by "Get Default") | |
| 0x72 | 1 | Flags | bit0 two stop bits, bit1 advanced option |
| 0x73 | 52 | TLV list | `type, len, data…`, 0-terminated; types 9/10 carry IPs, plus extra destination names/ports and register packets |

VirCom keeps every other byte as the device sent it. The macOS port does the same: it edits only the
fields above and sends the rest back unchanged.

## Virtual serial ports

VirCom bridges a virtual COM port to a TCP connection:
- device in **TCP Server** mode: VirCom connects to `device IP:port`;
- device in **TCP Client** mode: VirCom listens (default port 4196) and the device connects in.

Optional per-port settings: register ID/packet, login key, heartbeat packet and interval.

On macOS the virtual port is a pseudo-terminal: other apps open the `/dev/ttys…` path it shows.

## Not part of the port

`0x43c3f0` sends an unsolicited UDP datagram to `www.i-zlan.com:4196` (vendor telemetry).

## Web page & code download (`0x44e680`, `0x44edd0`)

Image: one record per file, in directory order: `FA F3` (+`EA D3` above 7 KB flash), path from the
directory with `/` and a NUL, length (2 bytes LE for 7 KB flash, else 4 bytes BE), data.

UDP to port 1092, 140-byte packets starting `5A 4C 11`:

| Model | Layout | Acknowledgement |
|---|---|---|
| 2003, 7004 | `off32 len16 crc16 flag` + 128 data; CRC (Modbus, wire order) over bytes 3…139 with the CRC zeroed; flag 0 for web pages, 1 / 0x81 (last) for code | reply ≥41 bytes, byte 2 = 0x12; newer firmware adds `code_w_with_seq` at 0x45 and the next offset at 0x0F |
| 2030/2032EX, flash > 7 KB | `off32 len16 last` + 64 data | 0x12 ack / 0x15 rewind; final 0x12 after 300 ms |
| 2030/2032EX, 7 KB | `addr16 len16` + 64 data, addr = off − 0x2C00, each sent twice | final 0x12 |

Images are rounded up to 4 KB sectors (except the 7 KB case). Serial download: 22-byte start frame
`ED F2 A3 56 CA DB 91 84 B0 D7 93 0C 01 kind len32 crc(data) crc(previous 10 bytes)`, reply
`ED F2 A3 56 CA DB 91 84 B0 D7 0F 00 00 41 C3`, then 256-byte chunks every 256 ms.

`httpd.txt` "E": AES-128-ECB, key `2327628244835630`, header `00 00 00 02 len32`; "D" asks for `zlan22`.

## Configuration files in the web directory

`mqtt.txt` (INI `[MQTT]`), `httpd.txt` (scripts from the Modbus gateway / register packet designers),
`MB` (gateway table), `st.hex` (state transfer, big-endian), `ID<device id>.txt` (binding), `z` (256-byte
filler written by Clear all). Formats are in `VirComKit/Sources/VirComKit/Download/ConfigFiles.swift`.

## More Advanced Settings

See `MoreAdvanced.swift`: TLV types 1–8 and 11 in the list at 0x73, bytes 0x34–0x37, 0x6E bits 2–7,
0x70, 0x71 and 0x72 bit 1. The register packet of Device Settings is stored as text at 0x82 when the
TLV list ends before it.

## Serial devices

All start with the download sync `ED F2 A3 56 CA DB 91 84 B0 D7`:
- serial server read `00 00 73` (reply: first 0x73 parameter bytes), write `03 00 73` + 0x73 bytes,
  single byte `01 off 01 value`; mark parity;
- identify `92 00 02 51 EC` (LoRa reply contains `97 00 6F 80`/`17 00 6F 00`, 4G `83 05 A0 83`/`03 05 20 03`);
- LoRa read `92 11 09 1C 7B` → 10 bytes + CRC (SF, fw, BW, CR, freq16, baud, parity, 0, 0); write `93 11 0A` + 10 bytes + CRC;
- Zigbee (38400 bps) read `23 A0` → 15 bytes `A2 …`; write `23 FE` + the same 14 bytes;
- 4G: text `REQUEST CFG MODE` → `CFG MODE`, `ZL+LOGIN=key`, `ZL+NAME?` / `ZL+NAME=value` (GBK).
