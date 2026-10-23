import XCTest

/// Walks every menu, window and sheet of VirCom. The app is launched with
/// `-VirComBlockDeviceWrites YES -VirComSampleDevice YES`: nothing can change a real device, and the
/// device list holds one made-up device instead of searching the network.
final class VirComUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-VirComBlockDeviceWrites", "YES", "-VirComSampleDevice", "YES",
                                "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    // MARK: Helpers

    func menu(_ bar: String, _ item: String) {
        let barItem = app.menuBars.menuBarItems[bar]
        barItem.click()
        let entry = barItem.menus.firstMatch.menuItems[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "menu item \(bar) › \(item)")
        entry.click()
    }

    func window(_ prefix: String, timeout: TimeInterval = 5) -> XCUIElement {
        let w = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(w.waitForExistence(timeout: timeout), "window \(prefix)")
        return w
    }

    func attach(_ name: String, _ element: XCUIElement) {
        let a = XCTAttachment(screenshot: element.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Clicks an alert's OK in its window (the Touch Bar has a copy that can't be clicked).
    func dismissAlert() {
        let ok = app.windows.buttons.matching(identifier: "OK").firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 2), "alert OK")
        ok.click()
    }

    func close(_ w: XCUIElement) {
        if w.exists { w.buttons[XCUIIdentifierCloseWindow].click() }
    }

    // MARK: Menus and windows

    func testAppMenuAboutAndSettings() {
        menu("VirCom", "About VirCom")
        let blurb = app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'Native macOS port'")).firstMatch
        XCTAssertTrue(blurb.waitForExistence(timeout: 3), "About window")
        attach("About", app.windows.firstMatch)
        app.typeKey("w", modifierFlags: .command)

        menu("VirCom", "Settings…")
        let settings = window("VirCom Settings")
        XCTAssertTrue(settings.staticTexts["Default listen port"].exists)
        attach("Settings", settings)
        close(settings)
    }

    func testMainWindowAndService() {
        menu("Window", "VirCom")
        let main = window("VirCom")
        menu("Manage", "Stop Service")
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS 'Service stopped'")).firstMatch.waitForExistence(timeout: 3))
        menu("Manage", "Start Service")
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS 'Service running'")).firstMatch.waitForExistence(timeout: 3))
        main.buttons["Clear Information"].click()

        main.buttons["Add Virtual Port"].firstMatch.click()
        let sheet = main.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "Add Virtual Port sheet")
        attach("Add Virtual Port", sheet)
        sheet.buttons["Cancel"].click()
        XCTAssertFalse(sheet.waitForExistence(timeout: 1))
    }

    func testMonitorWindow() {
        menu("View", "Monitor")
        let monitor = window("Data Monitor")
        XCTAssertTrue(monitor.checkBoxes["HEX"].exists)
        attach("Monitor", monitor)
        close(monitor)
    }

    func testExportImportPanelsOpenAndCancel() {
        menu("Config", "Export Settings…")
        let save = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save panel")
        app.typeKey(.escape, modifierFlags: [])
        menu("Config", "Import Settings…")
        let open = app.dialogs.firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "open panel")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: Device management

    func testDeviceManagementSheets() {
        menu("Manage", "Device Management")
        let dm = window("Device Management")
        attach("Device Management", dm)

        dm.buttons["Add Manually"].click()
        let range = dm.sheets.firstMatch
        XCTAssertTrue(range.waitForExistence(timeout: 3), "range sheet")
        attach("Add Manually", range)
        range.buttons["Cancel"].click()

        dm.buttons["Search Serial…"].click()
        let serial = dm.sheets.firstMatch
        XCTAssertTrue(serial.waitForExistence(timeout: 3), "serial search sheet")
        XCTAssertTrue(serial.buttons["Search"].exists)
        attach("Search Serial", serial)
        serial.buttons["Back"].click()

        menu("Manage", "Search Devices")
    }

    /// Opens Device Settings for the sample device.
    func openDeviceSettings() -> XCUIElement {
        menu("Window", "VirCom")
        menu("Manage", "Device Management")
        let dm = window("Device Management")
        let row = dm.outlineRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "sample device listed")
        row.staticTexts.element(boundBy: 1).click()
        let edit = dm.buttons["Edit Device"]
        XCTAssertTrue(edit.waitForExistence(timeout: 2) && edit.isEnabled, "row selected")
        edit.click()
        return window("Device Settings")
    }

    func pane(_ ds: XCUIElement, _ name: String) {
        let item = ds.descendants(matching: .any).matching(identifier: "pane.\(name)").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 2), "sidebar \(name)")
        item.click()
    }

    func testDeviceSettingsEveryPane() {
        let ds = openDeviceSettings()
        let expected: [String: String] = [
            "Device": "Device information", "Network": "Address", "Serial": "Serial port",
            "Options": "Protocol", "WiFi": "Access point", "RS485": "Multi-host",
            "Destinations": "Extra destinations", "Proxy & VLAN": "Proxy", "Functions": "What this device supports",
            "Raw Bytes": "Parameter block as it will be sent (167 bytes)",
        ]
        for name in ["Device", "Network", "Serial", "Options", "WiFi", "RS485", "Destinations", "Proxy & VLAN", "Functions", "Raw Bytes"] {
            pane(ds, name)
            let heading = ds.staticTexts[expected[name]!]
            XCTAssertTrue(heading.waitForExistence(timeout: 2), "\(name) pane shows \(expected[name]!)")
            attach("Device Settings – \(name)", ds)
        }
        ds.buttons["cancel"].click()
        XCTAssertFalse(ds.waitForExistence(timeout: 1), "Cancel closes the window")
    }

    func testDeviceSettingsToolbar() {
        let ds = openDeviceSettings()
        ds.menuButtons["toolbar.defaults"].click()
        XCTAssertTrue(app.menuItems["Save As My Default"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Get Factory Defaults"].exists)
        app.typeKey(.escape, modifierFlags: [])

        ds.buttons["toolbar.modifyKey"].click()
        let key = ds.sheets.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 2), "Modify Key sheet")
        attach("Modify Key", key)
        key.buttons["Cancel"].click()

        ds.buttons["showQRCode"].click()
        let qr = ds.sheets.firstMatch
        XCTAssertTrue(qr.waitForExistence(timeout: 2), "QR sheet")
        attach("QR", qr)
        qr.buttons["Done"].click()

        ds.buttons["toolbar.sendFiles"].click()
        let dl = window("Send Files to Device")
        close(dl)
        ds.buttons["cancel"].click()
    }

    /// A bad address is caught before anything is sent, and the window jumps to the pane with the problem.
    func testDeviceSettingsValidation() {
        let ds = openDeviceSettings()
        pane(ds, "Network")
        let ip = ds.textFields.matching(identifier: "field.ip").firstMatch
        XCTAssertTrue(ip.waitForExistence(timeout: 2), "IP field")
        ip.doubleClick()
        ip.typeKey("a", modifierFlags: .command)
        ip.typeText("300.1.2.3")
        pane(ds, "Serial")
        ds.buttons["modifySetting"].click()
        let message = app.staticTexts["The IP address isn't a valid IP address."]
        XCTAssertTrue(message.waitForExistence(timeout: 3), "validation alert")
        attach("Validation", ds)
        dismissAlert()
        XCTAssertTrue(ds.staticTexts["Address"].waitForExistence(timeout: 2), "jumped to Network pane")
        ds.buttons["cancel"].click()
    }

    /// Modify Setting and Restart are refused in test mode and reported.
    func testDeviceSettingsWriteIsBlocked() {
        let ds = openDeviceSettings()
        ds.buttons["modifySetting"].click()
        let blocked = app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'Blocked'")).firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 5), "blocked-write alert")
        attach("Blocked write", app.windows.firstMatch)
        dismissAlert()

        ds.buttons["restartDevice"].click()
        let restart = app.windows.buttons.matching(identifier: "Restart").firstMatch
        XCTAssertTrue(restart.waitForExistence(timeout: 2), "restart confirmation")
        restart.click()
        XCTAssertTrue(blocked.waitForExistence(timeout: 5), "restart blocked too")
        dismissAlert()
        if ds.exists { ds.buttons["cancel"].click() }
    }

    // MARK: Tools

    func testSendFilesToDevice() {
        menu("Manage", "Send Files to Device")
        let dl = window("Send Files to Device")
        attach("Send Files", dl)
        for row in ["Script file (httpd.txt)"] {
            XCTAssertTrue(dl.staticTexts[row].exists, row)
        }
        for id in ["config.MQTT", "config.Modbus gateway (ZLMB)", "config.Register & heartbeat packets", "config.State transfer"] {
            XCTAssertTrue(dl.descendants(matching: .any).matching(identifier: id).firstMatch.exists, "\(id) row")
        }
        dl.radioButtons["Firmware file"].click()
        attach("Send Files – code", dl)
        dl.radioButtons["Web pages and configuration (folder)"].click()
        dl.radioButtons["Serial port"].firstMatch.click()
        attach("Send Files – serial", dl)
        dl.radioButtons["Network"].firstMatch.click()
        close(dl)
    }

    func testFourGTool() {
        menu("Manage", "4G Config Tools")
        let g = window("4G Config Tools")
        XCTAssertTrue(g.buttons["AT Command Mode"].exists)
        XCTAssertFalse(g.buttons["Login"].isEnabled, "login needs config mode")
        XCTAssertFalse(g.buttons["Set Main Parameters"].isEnabled)
        attach("4G tool", g)
        close(g)
    }

    func testHelpMenu() {
        app.menuBars.menuBarItems["Help"].click()
        XCTAssertTrue(app.menuBars.menuBarItems["Help"].menus.firstMatch.menuItems["VirCom Help"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
    }
}
