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
                "sidebar_diagnostics",
                "detail_home",
                "home_virtual_display_surface",
                "home_summary_panel",
                "home_virtual_display_card"
            ],
            timeout: 6
        )

        XCTAssertFalse(app.descendants(matching: .any)["sidebar_displays"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_virtual_display"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_screen_preview"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar_screen_sharing"].exists)

        tapIdentifier(app, identifier: "sidebar_diagnostics")
        assertAllExist(app, identifiers: ["detail_diagnostics"], timeout: 1.5)

        tapIdentifier(app, identifier: "sidebar_home")
        assertAllExist(app, identifiers: ["detail_home", "home_virtual_display_card"], timeout: 1.5)
    }

    @MainActor
    func testVirtualDisplayCardSurfaceSmoke_baseline() throws {
        let app = launchAppForSmoke()

        assertAllExist(
            app,
            identifiers: [
                "detail_home",
                "home_virtual_display_surface",
                "home_summary_panel",
                "home_virtual_display_card_grid",
                "home_virtual_display_card",
                "home_card_status_grid",
                "virtual_display_toggle_button",
                "home_virtual_display_preview_button",
                "home_virtual_display_web_view_button",
                "virtual_display_edit_button",
                "home_virtual_display_more_button",
                "home_add_virtual_display_button"
            ],
            timeout: 6
        )
    }

    @MainActor
    func testVirtualDisplayCardSurfaceSmoke_compactSkin() throws {
        let app = launchAppForSmoke(skinID: "compact")

        assertAllExist(
            app,
            identifiers: [
                "detail_home",
                "home_virtual_display_surface",
                "home_summary_panel",
                "home_virtual_display_card_grid",
                "home_virtual_display_card",
                "home_card_status_grid",
                "virtual_display_toggle_button",
                "home_virtual_display_preview_button",
                "home_virtual_display_web_view_button",
                "virtual_display_edit_button",
                "home_virtual_display_more_button"
            ],
            timeout: 6
        )
    }

    @MainActor
    func testVirtualDisplayCardSurfaceSmoke_dashboardSkin() throws {
        let app = launchAppForSmoke(skinID: "dashboard")

        assertAllExist(
            app,
            identifiers: [
                "detail_home",
                "home_virtual_display_surface",
                "home_dashboard_status_board",
                "home_virtual_display_card_grid",
                "home_virtual_display_card",
                "home_card_status_grid",
                "virtual_display_toggle_button",
                "home_virtual_display_preview_button",
                "home_virtual_display_web_view_button",
                "virtual_display_edit_button",
                "home_virtual_display_more_button"
            ],
            timeout: 6
        )
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
}
