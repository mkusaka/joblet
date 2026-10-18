import XCTest

/// Drives the real app UI. The app is launched with `-ui-testing`, which swaps in a temporary
/// home directory and an in-memory launchctl (seeded with "Nightly Backup", "Paused Cleanup" and
/// one existing agent), so nothing touches real launchd or ~/Library/LaunchAgents.
final class JobletUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(rowName("Nightly Backup").waitForExistence(timeout: timeout), "Fixture jobs did not load")
    }

    // MARK: Helpers

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func rowName(_ name: String) -> XCUIElement {
        app.staticTexts.matching(identifier: "job-row-name").matching(NSPredicate(format: "value == %@", name)).firstMatch
    }

    private func groupHeader(_ name: String) -> XCUIElement {
        app.staticTexts.matching(identifier: "group-section-header").matching(NSPredicate(format: "value == %@", name)).firstMatch
    }

    /// Sections are ordered by name with "Ungrouped" last, so a row belongs to the nearest header above it.
    private func isListed(_ row: XCUIElement, below header: XCUIElement, above next: XCUIElement?) -> Bool {
        row.frame.minY > header.frame.minY && (next.map { row.frame.minY < $0.frame.minY } ?? true)
    }

    private func text(_ element: XCUIElement) -> String {
        element.value as? String ?? ""
    }

    private var rowCount: Int {
        app.staticTexts.matching(identifier: "job-row-name").count
    }

    private func select(_ name: String) {
        rowName(name).click()
        XCTAssertTrue(waitForText(element("detail-name"), name), "Detail pane did not show \(name)")
    }

    /// SwiftUI `Text` exposes its string as the accessibility value, not the label.
    private func waitForText(_ element: XCUIElement, _ text: String) -> Bool {
        let predicate = NSPredicate(format: "value == %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// Switch values are numbers (0/1), so compare their string form.
    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let predicate = NSPredicate { object, _ in
            String(describing: (object as? XCUIElement)?.value ?? "") == value
        }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func waitForGone(_ element: XCUIElement) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: timeout) == .completed
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func createJob(name: String, command: String, intervalMinutes: String) {
        element("add-job-button").click()
        let nameField = element("editor-name")
        XCTAssertTrue(nameField.waitForExistence(timeout: timeout))
        replaceText(in: nameField, with: name)
        replaceText(in: element("editor-command"), with: command)
        app.radioButtons["Interval"].click()
        let interval = element("editor-interval-minutes")
        XCTAssertTrue(interval.waitForExistence(timeout: timeout))
        replaceText(in: interval, with: intervalMinutes)
        nameField.click() // commit the number field by moving focus
        element("editor-save").click()
        XCTAssertTrue(waitForGone(element("editor-save")), "Editor did not close")
    }

    // MARK: Tests

    func testLaunchShowsSidebarAndJobList() {
        XCTAssertTrue(element("job-list").exists)
        XCTAssertTrue(element("add-job-button").exists)
        XCTAssertEqual(rowCount, 3)
        XCTAssertTrue(rowName("Paused Cleanup").exists)
        XCTAssertTrue(element("filter-all").exists)
    }

    func testCreateJobShowsInListAndDetail() {
        createJob(name: "UI Test Job", command: "echo hello", intervalMinutes: "15")
        XCTAssertTrue(rowName("UI Test Job").waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForText(element("detail-name"), "UI Test Job"))
        XCTAssertTrue(waitForText(element("detail-command"), "echo hello"))
        XCTAssertEqual(text(element("detail-status")), "Waiting")
        XCTAssertTrue(text(element("detail-label")).hasPrefix("local.joblet."))
        XCTAssertEqual(rowCount, 4)
    }

    func testEditJob() {
        select("Nightly Backup")
        element("edit-button").click()
        let nameField = element("editor-name")
        XCTAssertTrue(nameField.waitForExistence(timeout: timeout))
        replaceText(in: nameField, with: "Renamed Backup")
        replaceText(in: element("editor-command"), with: "echo renamed")
        element("editor-save").click()
        XCTAssertTrue(waitForGone(element("editor-save")))
        XCTAssertTrue(rowName("Renamed Backup").waitForExistence(timeout: timeout))
        XCTAssertFalse(rowName("Nightly Backup").exists)
        XCTAssertTrue(waitForText(element("detail-name"), "Renamed Backup"))
        XCTAssertTrue(waitForText(element("detail-command"), "echo renamed"))
    }

    func testToggleEnableDisable() {
        select("Nightly Backup")
        let toggle = element("detail-toggle")
        XCTAssertEqual(text(element("detail-status")), "Waiting")
        toggle.click()
        XCTAssertTrue(waitForText(element("detail-status"), "Not loaded"))
        XCTAssertTrue(waitForValue(toggle, "0"))
        toggle.click()
        XCTAssertTrue(waitForText(element("detail-status"), "Waiting"))
        XCTAssertTrue(waitForValue(toggle, "1"))
    }

    func testRunNow() {
        select("Nightly Backup")
        let run = element("run-now-button")
        XCTAssertTrue(run.isEnabled)
        run.click()
        // The in-memory launchctl marks the job as running; no process is spawned.
        XCTAssertTrue(waitForText(element("detail-status"), "Running"))
        XCTAssertFalse(run.isEnabled)
    }

    func testFilterAndSearch() {
        element("filter-managed").click()
        XCTAssertTrue(waitForGone(rowName("com.example.existing-agent")))
        XCTAssertEqual(rowCount, 2)

        element("filter-external").click()
        XCTAssertTrue(rowName("com.example.existing-agent").waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForGone(rowName("Nightly Backup")))
        XCTAssertEqual(rowCount, 1)

        element("filter-all").click()
        XCTAssertTrue(rowName("Nightly Backup").waitForExistence(timeout: timeout))
        XCTAssertEqual(rowCount, 3)

        let search = app.searchFields.firstMatch
        search.click()
        search.typeText("Paused")
        XCTAssertTrue(waitForGone(rowName("Nightly Backup")))
        XCTAssertTrue(rowName("Paused Cleanup").exists)
        XCTAssertEqual(rowCount, 1)
    }

    func testDeleteJob() {
        select("Paused Cleanup")
        element("more-actions-menu").click()
        let deleteItem = app.menuItems["Delete Job…"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: timeout))
        deleteItem.click()
        let confirm = app.sheets.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.click()
        XCTAssertTrue(waitForGone(rowName("Paused Cleanup")))
        XCTAssertEqual(rowCount, 2)
    }

    func testAssignGroupThenRemoveReturnsToUngrouped() {
        select("Nightly Backup")
        element("group-menu").click()
        let newGroup = app.menuItems["New Group…"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: timeout))
        newGroup.click()
        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.click()
        field.typeText("Backups")
        app.sheets.buttons["Add"].click()

        let backups = groupHeader("Backups")
        let ungrouped = groupHeader("Ungrouped")
        XCTAssertTrue(backups.waitForExistence(timeout: timeout))
        XCTAssertTrue(ungrouped.exists)
        XCTAssertTrue(isListed(rowName("Nightly Backup"), below: backups, above: ungrouped))
        XCTAssertTrue(isListed(rowName("Paused Cleanup"), below: ungrouped, above: nil))

        element("group-menu").click()
        let remove = app.menuItems["Remove from Group"]
        XCTAssertTrue(remove.waitForExistence(timeout: timeout))
        remove.click()
        XCTAssertTrue(waitForGone(backups))
        XCTAssertTrue(isListed(rowName("Nightly Backup"), below: ungrouped, above: nil))
        XCTAssertEqual(rowCount, 3)
    }

    func testLaunchAtLoginToggleInSettings() {
        app.typeKey(",", modifierFlags: .command)
        let toggle = element("launch-at-login-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForValue(toggle, "0"))
        toggle.click()
        XCTAssertTrue(waitForValue(toggle, "1"))
        toggle.click()
        XCTAssertTrue(waitForValue(toggle, "0"))
    }
}
