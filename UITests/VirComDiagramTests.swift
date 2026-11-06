import XCTest
import AppKit

/// Screenshots the explanatory diagrams at the bottom of the Device Settings panes and checks that
/// they are actually on screen. Same safe launch as the rest of the suite: writes are blocked and the
/// device list holds one made-up device. Screenshots are written to $VIRCOM_SHOT_DIR when it is set.
final class VirComDiagramTests: XCTestCase {
    var app: XCUIApplication!

    private var shotDir: URL? {
        guard let d = ProcessInfo.processInfo.environment["VIRCOM_SHOT_DIR"] else { return nil }
        let url = URL(fileURLWithPath: d)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-VirComBlockDeviceWrites", "YES", "-VirComSampleDevice", "YES",
                                "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    override func tearDown() { app.terminate() }

    private func window(_ prefix: String) -> XCUIElement {
        let w = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(w.waitForExistence(timeout: 10), "window \(prefix)")
        return w
    }

    private func menu(_ bar: String, _ item: String) {
        let barItem = app.menuBars.menuBarItems[bar]
        barItem.click()
        let entry = barItem.menus.firstMatch.menuItems[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "menu item \(bar) › \(item)")
        entry.click()
    }

    private func openDeviceSettings() -> XCUIElement {
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

    private func pane(_ ds: XCUIElement, _ name: String) {
        let item = ds.descendants(matching: .any).matching(identifier: "pane.\(name)").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 2), "sidebar \(name)")
        item.click()
    }

    /// Saves a screenshot and reports where the diagram sits inside the window.
    private func record(_ name: String, _ ds: XCUIElement, diagram id: String) {
        _ = ds.frame  // force a fresh snapshot
        let shot = ds.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = shotDir {
            let file = dir.appendingPathComponent(name.replacingOccurrences(of: " ", with: "-") + ".png")
            try? shot.pngRepresentation.write(to: file)
        }
        let d = ds.descendants(matching: .any).matching(identifier: id).firstMatch
        let w = ds.frame
        guard d.exists else {
            print("SHOT \(name): window \(Int(w.width))x\(Int(w.height)) — DIAGRAM \(id) NOT FOUND")
            return
        }
        let f = d.frame
        let bottomGap = w.maxY - f.maxY
        let onScreen = f.maxY <= w.maxY + 1 && f.minY >= w.minY
        print("SHOT \(name): window \(Int(w.width))x\(Int(w.height))"
              + " diagram y=\(Int(f.minY - w.minY))..\(Int(f.maxY - w.minY))"
              + " h=\(Int(f.height)) w=\(Int(f.width))"
              + " gapBelow=\(Int(bottomGap)) onScreen=\(onScreen)")
        XCTAssertTrue(onScreen, "\(name): the diagram is outside the window")
    }

    func testDiagramsAreVisible() {
        let ds = openDeviceSettings()

        print("SCREEN main=\(NSScreen.main?.frame ?? .zero) visible=\(NSScreen.main?.visibleFrame ?? .zero)")
        print("SCREENS \(NSScreen.screens.map(\.frame))")
        print("WINDOW Device Settings frame=\(ds.frame)")

        pane(ds, "Network")
        print("WINDOW after Network frame=\(ds.frame)")
        let w = ds.frame
        let bar = ds.buttons["modifySetting"]
        print("BOTTOMBAR exists=\(bar.exists) frame=\(bar.exists ? "\(bar.frame)" : "-")"
              + " relY=\(bar.exists ? Int(bar.frame.minY - w.minY) : -1) windowH=\(Int(w.height))")
        let sv = ds.scrollViews.firstMatch
        print("SCROLLVIEW exists=\(sv.exists) frame=\(sv.exists ? "\(sv.frame)" : "-")")
        record("Network initial", ds, diagram: "diagram.workMode")
        let modePicker = ds.popUpButtons["field.workMode"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 3), "work mode picker")
        for mode in ["TCP Server", "TCP Client", "UDP", "UDP Group"] {
            modePicker.click()
            let option = app.menuItems[mode].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3), "work mode option \(mode)")
            option.click()
            record("Network \(mode)", ds, diagram: "diagram.workMode")
        }

        pane(ds, "RS485")
        record("RS485", ds, diagram: "diagram.rs485")

        pane(ds, "Destinations")
        record("Destinations", ds, diagram: "diagram.destinations")

        ds.buttons["cancel"].click()
    }
}
