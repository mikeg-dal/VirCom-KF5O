public import Foundation

/// Test safety switch: launched with `-VirComBlockDeviceWrites YES`, every operation that would change a
/// device (parameter writes, key changes, downloads, serial writes, clearing the web key) throws instead.
public enum DeviceWriteGuard {
    public static var blocked: Bool { UserDefaults.standard.bool(forKey: "VirComBlockDeviceWrites") }

    public static func check(_ what: String) throws {
        if blocked { throw DownloadError("Blocked (test mode): \(what) was not sent to the device.") }
    }
}
