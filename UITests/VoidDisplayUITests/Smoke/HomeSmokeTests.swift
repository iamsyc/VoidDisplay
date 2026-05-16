import XCTest

final class HomeSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeNavigationSmoke_baseline() throws {
        let app = launchAppForSmoke()

        assertAllExist(
            app,
            identifiers: [
                "sidebar_home",
                "sidebar_displays",
                "sidebar_virtual_display",
                "sidebar_screen_preview",
                "sidebar_screen_sharing",
                "sidebar_diagnostics",
                "detail_home",
                "displays_shell",
                "displays_surface_list",
                "display_surface_row"
            ],
            timeout: 6
        )

        tapIdentifier(app, identifier: "sidebar_displays")
        assertAllExist(app, identifiers: ["detail_displays", "system_displays_list"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_virtual_display")
        assertAllExist(app, identifiers: ["detail_virtual_display", "virtual_display_add_button"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_screen_preview")
        assertAllExist(app, identifiers: ["detail_screen_preview"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_screen_sharing")
        assertAllExist(app, identifiers: ["detail_screen_sharing"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_diagnostics")
        assertAllExist(app, identifiers: ["detail_diagnostics"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_home")
        assertAllExist(app, identifiers: ["detail_home", "display_surface_row"], timeout: 1.5)
    }

    @MainActor
    func testDisplaysSurfaceConvergenceSmoke_baseline() throws {
        let app = launchAppForSmoke()

        assertAllExist(
            app,
            identifiers: [
                "detail_home",
                "displays_surface_list",
                "display_surface_row",
                "displays_compact_status_line",
                "displays_preview_status",
                "displays_lan_web_view_status",
                "displays_action_open_preview",
                "displays_action_open_lan_web_view"
            ],
            timeout: 6
        )

        tapIdentifier(app, identifier: "displays_action_open_preview")
        assertAllExist(app, identifiers: ["detail_screen_preview"], timeout: 1.5)

        openHomeOverview(in: app)
        tapIdentifier(app, identifier: "displays_action_open_lan_web_view")
        assertAllExist(app, identifiers: ["detail_lan_web_view"], timeout: 1.5)
    }

    @MainActor
    func testDiagnosticsNavigationSmoke_baseline() throws {
        let app = launchAppForSmoke()

        tapIdentifier(app, identifier: "sidebar_diagnostics", timeout: 6)

        assertAllExist(
            app,
            identifiers: [
                "detail_diagnostics",
                "diagnostics_intro_text",
                "support_bundle_export_button",
                "support_bundle_draft_panel",
                "diagnostics_technical_disclosure"
            ],
            timeout: 3
        )

        XCTAssertFalse(app.descendants(matching: .any)["support_bundle_copy_summary_button"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["support_bundle_reveal_button"].exists)
    }

    @MainActor
    private func openHomeOverview(in app: XCUIApplication) {
        tapIdentifier(app, identifier: "displays_overview_toolbar_button")
        assertAllExist(app, identifiers: ["detail_home", "display_surface_row"], timeout: 1.5)
    }
}
