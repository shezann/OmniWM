// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class WindowManagementPauseTests: XCTestCase {
    func testToggleWindowManagementIsASharedUnassignedAction() throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: .toggleWindowManagement))

        XCTAssertEqual(spec.id, "toggleWindowManagement")
        XCTAssertEqual(spec.title, "Toggle Window Management")
        XCTAssertEqual(spec.category, .focus)
        XCTAssertEqual(spec.visibility, .normal)
        XCTAssertEqual(spec.layoutCompatibility, .shared)
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertEqual(spec.ipcCommandName, .toggleWindowManagement)

        let terms = Set(spec.searchTerms.map(ActionCatalog.normalizedSearchTerm))
        for term in ["pause", "resume", "tiling"] {
            XCTAssertTrue(terms.contains(ActionCatalog.normalizedSearchTerm(term)), term)
        }
        XCTAssertTrue(SettingsTOMLCodec.hotkeyIDsAddedInVersionFive.contains("toggleWindowManagement"))
    }

    func testPauseCommandsRoundTripThroughIPC() throws {
        let cases: [(String, IPCCommandName, IPCCommandRequest)] = [
            ("pause-window-management", .pauseWindowManagement, .pauseWindowManagement),
            ("resume-window-management", .resumeWindowManagement, .resumeWindowManagement),
            ("toggle-window-management", .toggleWindowManagement, .toggleWindowManagement)
        ]
        for (rawValue, name, request) in cases {
            XCTAssertEqual(IPCCommandName(rawValue: rawValue), name, rawValue)
            XCTAssertEqual(request.name, name, rawValue)
            XCTAssertEqual(try IPCCommandRequest(name: name, argumentValues: []), request, rawValue)
            XCTAssertThrowsError(try IPCCommandRequest(name: name, argumentValues: [.direction(.left)]), rawValue)

            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), request, rawValue)

            let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: name), rawValue)
            XCTAssertEqual(descriptor.commandWords, [rawValue], rawValue)
            XCTAssertEqual(descriptor.layoutCompatibility, .shared, rawValue)
            XCTAssertTrue(descriptor.arguments.isEmpty, rawValue)
        }
    }

    func testHotkeyAllowlistKeepsOnlyTheListedCommands() {
        let toggle = HotkeyBinding(
            id: "toggleWindowManagement",
            command: .toggleWindowManagement,
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | shiftKey))
        )
        let focus = HotkeyBinding(
            id: "focus.left",
            command: .focus(.left),
            binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey))
        )

        XCTAssertEqual(HotkeyCenter.bindings([focus, toggle], allowing: nil), [focus, toggle])
        XCTAssertEqual(HotkeyCenter.bindings([focus, toggle], allowing: [.toggleWindowManagement]), [toggle])
        XCTAssertEqual(HotkeyCenter.bindings([focus], allowing: [.toggleWindowManagement]), [])
    }

    @MainActor
    func testPausingBlocksOtherCommandsAndTheToggleResumes() {
        let controller = WMController(settings: makeSettingsStore())
        controller.applyPersistedSettings(controller.settings, startServices: false)
        XCTAssertFalse(controller.isWindowManagementPaused)

        XCTAssertTrue(controller.setWindowManagementPaused(true))
        XCTAssertTrue(controller.isWindowManagementPaused)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.setWindowManagementPaused(true), "pausing twice is a no-op")

        XCTAssertEqual(controller.commandHandler.performCommand(.focus(.left)), .ignoredDisabled)
        XCTAssertEqual(controller.commandHandler.performCommand(.toggleOverview), .ignoredDisabled)
        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: .focus(.left))),
            .ignoredDisabled
        )

        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: .toggleWindowManagement)),
            .executed
        )
        XCTAssertFalse(controller.isWindowManagementPaused)
        // Resuming restores whatever the Accessibility permission allows; the test process may lack it.
        XCTAssertEqual(controller.isEnabled, controller.accessibilityPermissionGranted)

        XCTAssertEqual(controller.commandHandler.performCommand(.toggleWindowManagement), .executed)
        XCTAssertTrue(controller.isWindowManagementPaused)
        XCTAssertEqual(controller.commandHandler.performCommand(.toggleWindowManagement), .executed)
        XCTAssertFalse(controller.isWindowManagementPaused)
    }

    @MainActor
    func testRepeatedToggleHotkeyPressIsIgnored() {
        let controller = WMController(settings: makeSettingsStore())
        controller.applyPersistedSettings(controller.settings, startServices: false)
        let trigger = PhysicalHotkeyTrigger(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey), isRepeat: true)

        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(command: .toggleWindowManagement, trigger: trigger)
            ),
            .executed
        )
        XCTAssertFalse(controller.isWindowManagementPaused, "a key repeat must not flip the state")
    }

    @MainActor
    func testRouterPausesResumesAndReportsNoChange() {
        let controller = WMController(settings: makeSettingsStore())
        controller.applyPersistedSettings(controller.settings, startServices: false)
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.resumeWindowManagement), .noChange)
        XCTAssertEqual(router.handle(.pauseWindowManagement), .executed)
        XCTAssertTrue(controller.isWindowManagementPaused)
        XCTAssertEqual(router.handle(.pauseWindowManagement), .noChange)
        XCTAssertEqual(router.handle(.focus(direction: .left)), .ignoredDisabled)
        XCTAssertEqual(router.handle(.resumeWindowManagement), .executed)
        XCTAssertFalse(controller.isWindowManagementPaused)
        XCTAssertEqual(router.handle(.toggleWindowManagement), .executed)
        XCTAssertTrue(controller.isWindowManagementPaused)
        XCTAssertEqual(router.handle(.toggleWindowManagement), .executed)
        XCTAssertFalse(controller.isWindowManagementPaused)
    }

    @MainActor
    func testStatusMenuOffersTheTilingTileFirst() {
        let controller = WMController(settings: makeSettingsStore())
        let model = StatusMenuModel(settings: controller.settings, controller: controller)

        let tile = model.toggleTiles[0]
        XCTAssertEqual(tile.control, .windowManagementEnabled)
        XCTAssertTrue(tile.isOn.wrappedValue)
        tile.isOn.wrappedValue = false
        XCTAssertTrue(controller.isWindowManagementPaused)
        XCTAssertFalse(model.toggleTiles[0].isOn.wrappedValue)
        tile.isOn.wrappedValue = true
        XCTAssertFalse(controller.isWindowManagementPaused)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMPauseTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
