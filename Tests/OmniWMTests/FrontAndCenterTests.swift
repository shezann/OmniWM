// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Carbon
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class FrontAndCenterTests: XCTestCase {
    func testActionIsASharedLayoutActionBoundToOptionShiftF() throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: .bringFocusedWindowFrontAndCenter))

        XCTAssertEqual(spec.id, "bringFocusedWindowFrontAndCenter")
        XCTAssertEqual(spec.title, "Bring Focused Window Front and Center")
        XCTAssertEqual(spec.category, .layout)
        XCTAssertEqual(spec.visibility, .normal)
        XCTAssertEqual(spec.layoutCompatibility, .shared)
        XCTAssertEqual(
            spec.defaultBinding,
            KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | shiftKey))
        )
        XCTAssertEqual(spec.ipcCommandName, .bringFocusedWindowFrontAndCenter)

        let terms = Set(spec.searchTerms.map(ActionCatalog.normalizedSearchTerm))
        for term in ["lost", "find", "center", "front"] {
            XCTAssertTrue(terms.contains(ActionCatalog.normalizedSearchTerm(term)), term)
        }
        XCTAssertTrue(SettingsTOMLCodec.hotkeyIDsAddedInVersionSix.contains("bringFocusedWindowFrontAndCenter"))
    }

    func testOptionShiftFNoLongerBelongsToTheNiriSpanToggleAndDefaultsDoNotCollide() throws {
        let spanToggle = try XCTUnwrap(ActionCatalog.spec(for: "toggleContainerFullPrimarySpan"))
        XCTAssertEqual(spanToggle.defaultBinding, .unassigned)

        let plan = HotkeyCenter.registrationPlan(for: DefaultHotkeyBindings.all())
        XCTAssertEqual(plan.failures, [:], "default bindings must not conflict with each other")
        XCTAssertTrue(plan.registrations.contains { $0.command == .bringFocusedWindowFrontAndCenter })
    }

    func testCommandRoundTripsThroughIPC() throws {
        let rawValue = "bring-focused-window-front-and-center"
        let name = IPCCommandName.bringFocusedWindowFrontAndCenter
        let request = IPCCommandRequest.bringFocusedWindowFrontAndCenter

        XCTAssertEqual(IPCCommandName(rawValue: rawValue), name)
        XCTAssertEqual(request.name, name)
        XCTAssertEqual(try IPCCommandRequest(name: name, argumentValues: []), request)
        XCTAssertThrowsError(try IPCCommandRequest(name: name, argumentValues: [.direction(.left)]))

        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), request)

        let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: name))
        XCTAssertEqual(descriptor.commandWords, [rawValue])
        XCTAssertEqual(descriptor.layoutCompatibility, .shared)
        XCTAssertTrue(descriptor.arguments.isEmpty)
    }

    func testPausedHotkeyAllowlistKeepsTheEscapeHatch() {
        let frontAndCenter = HotkeyBinding(
            id: "bringFocusedWindowFrontAndCenter",
            command: .bringFocusedWindowFrontAndCenter,
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | shiftKey))
        )
        let focus = HotkeyBinding(
            id: "focus.left",
            command: .focus(.left),
            binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey))
        )
        let allowed: Set<HotkeyCommand> = [.toggleWindowManagement, .bringFocusedWindowFrontAndCenter]

        XCTAssertEqual(HotkeyCenter.bindings([focus, frontAndCenter], allowing: allowed), [frontAndCenter])
    }

    func testFrameCoversTheConfiguredShareOfTheVisibleFrameAndStaysCentered() {
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 900)
        XCTAssertEqual(
            FrontAndCenterSettings.frame(in: visible, sizeRatio: 0.7),
            CGRect(x: 240, y: 135, width: 1120, height: 630)
        )

        let offset = CGRect(x: 1600, y: 100, width: 1000, height: 500)
        XCTAssertEqual(
            FrontAndCenterSettings.frame(in: offset, sizeRatio: 0.5),
            CGRect(x: 1850, y: 225, width: 500, height: 250)
        )

        XCTAssertEqual(FrontAndCenterSettings.frame(in: visible, sizeRatio: 4), visible)
        XCTAssertEqual(
            FrontAndCenterSettings.frame(in: visible, sizeRatio: 0),
            FrontAndCenterSettings.frame(in: visible, sizeRatio: FrontAndCenterSettings.sizeRatioRange.lowerBound)
        )
        XCTAssertEqual(FrontAndCenterSettings.clampedSizeRatio(.nan), FrontAndCenterSettings.defaultSizeRatio)
    }

    @MainActor
    func testPerMonitorOverrideWinsOverTheGlobalRatioAndRoundTripsThroughTOML() throws {
        let settings = makeSettingsStore()
        let laptop = makeMonitor(displayId: 473_000, name: "Laptop", uuid: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        let external = makeMonitor(displayId: 473_001, name: "External", uuid: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")

        XCTAssertEqual(settings.frontAndCenterSizeRatio, 0.7)
        settings.frontAndCenterSizeRatio = 0.6
        settings.updateFrontAndCenterSettings(
            MonitorFrontAndCenterSettings(monitorName: external.name, sizeRatio: 0.9),
            for: external
        )

        XCTAssertEqual(settings.resolvedFrontAndCenterSizeRatio(for: laptop), 0.6)
        XCTAssertEqual(settings.resolvedFrontAndCenterSizeRatio(for: external), 0.9)
        XCTAssertEqual(settings.frontAndCenterSettings(for: external)?.monitorDisplayUUID, external.displayUUID)

        let encoded = try SettingsTOMLCodec.encode(settings.toExport())
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("[frontAndCenter]\nsizeRatio = 0.6\n"), text)
        XCTAssertTrue(text.contains("[[monitorFrontAndCenterOverrides]]"), text)
        let decoded = try SettingsTOMLCodec.decode(encoded)
        XCTAssertEqual(decoded.frontAndCenterSizeRatio, 0.6)
        XCTAssertEqual(decoded.monitorFrontAndCenterSettings.map(\.sizeRatio), [0.9])

        // Clearing the only override removes the row instead of leaving an empty one behind.
        settings.updateFrontAndCenterSettings(
            MonitorFrontAndCenterSettings(monitorName: external.name, sizeRatio: nil),
            for: external
        )
        XCTAssertNil(settings.frontAndCenterSettings(for: external))
        XCTAssertEqual(settings.resolvedFrontAndCenterSizeRatio(for: external), 0.6)
    }

    @MainActor
    func testCommandStillRunsWhilePausedAndReportsNotFoundWithoutATarget() {
        let controller = WMController(settings: makeSettingsStore())
        controller.applyPersistedSettings(controller.settings, startServices: false)
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { nil }
        controller.frontAndCenterFocusedWindowResolver = { _ in nil }

        XCTAssertTrue(controller.setWindowManagementPaused(true))
        XCTAssertEqual(controller.commandHandler.performCommand(.focus(.left)), .ignoredDisabled)
        XCTAssertEqual(controller.commandHandler.performCommand(.bringFocusedWindowFrontAndCenter), .notFound)
        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(command: .bringFocusedWindowFrontAndCenter)
            ),
            .notFound
        )
        let repeated = PhysicalHotkeyTrigger(
            keyCode: UInt32(kVK_ANSI_F),
            modifiers: UInt32(optionKey | shiftKey),
            isRepeat: true
        )
        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(
                HotkeyInvocation(command: .bringFocusedWindowFrontAndCenter, trigger: repeated)
            ),
            .executed,
            "a key repeat is swallowed without touching any window"
        )
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")
        XCTAssertEqual(router.handle(.bringFocusedWindowFrontAndCenter), .notFound)
        XCTAssertEqual(router.handle(.focus(direction: .left)), .ignoredDisabled)
    }

    @MainActor
    func testPausedControllerDrivesTheWindowDirectlyWithoutTouchingTheLayoutModel() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        let token = addWindow(pid: 474_001, windowId: 31, to: fixture.workspace2, in: controller)
        controller.commandHandler.frontmostAppPidProvider = { 474_001 }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { token }
        XCTAssertTrue(controller.setWindowManagementPaused(true))

        // The fake AX element belongs to no process, so the direct frame write cannot succeed.
        XCTAssertEqual(controller.bringFocusedWindowFrontAndCenter(), .windowActionFailed)

        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(entry.mode, .tiling)
        XCTAssertEqual(entry.workspaceId, fixture.workspace2)
        XCTAssertNil(controller.workspaceManager.manualLayoutOverride(for: token))
    }

    @MainActor
    func testManagedWindowIsFloatedMovedToTheCurrentWorkspaceAndCentered() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        let token = addWindow(pid: 474_002, windowId: 32, to: fixture.workspace2, in: controller)
        controller.commandHandler.frontmostAppPidProvider = { 474_002 }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { token }
        controller.isEnabled = true
        controller.hasStartedServices = true
        _ = controller.workspaceManager.setInteractionMonitor(fixture.monitor.id)
        controller.settings.frontAndCenterSizeRatio = 0.5

        XCTAssertEqual(controller.bringFocusedWindowFrontAndCenter(), .executed)

        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(entry.workspaceId, fixture.workspace1, "pulled onto the workspace the user is looking at")
        XCTAssertEqual(entry.mode, .floating)
        XCTAssertEqual(controller.workspaceManager.manualLayoutOverride(for: token), .forceFloat)
        XCTAssertEqual(
            controller.workspaceManager.floatingState(for: token)?.lastFrame,
            CGRect(x: 400, y: 225, width: 800, height: 450)
        )
        XCTAssertEqual(controller.workspaceManager.floatingState(for: token)?.referenceMonitorId, fixture.monitor.id)
        XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
    }

    @MainActor
    func testSecondPressTilesTheWindowBackIntoTheWorkspaceItIsOnNow() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        let token = addWindow(pid: 474_003, windowId: 33, to: fixture.workspace2, in: controller)
        controller.commandHandler.frontmostAppPidProvider = { 474_003 }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { token }
        controller.isEnabled = true
        controller.hasStartedServices = true

        XCTAssertEqual(controller.bringFocusedWindowFrontAndCenter(), .executed)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.mode, .floating)
        XCTAssertNotNil(controller.frontAndCenterRestoreStates[token])

        XCTAssertEqual(controller.bringFocusedWindowFrontAndCenter(), .executed)

        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(entry.mode, .tiling, "the second press puts the window back into the layout")
        XCTAssertEqual(entry.workspaceId, fixture.workspace1, "it stays on the workspace it was pulled to")
        XCTAssertNil(controller.workspaceManager.manualLayoutOverride(for: token))
        XCTAssertNil(controller.frontAndCenterRestoreStates[token])

        // A third press starts the cycle again.
        XCTAssertEqual(controller.bringFocusedWindowFrontAndCenter(), .executed)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.mode, .floating)
    }

    @MainActor
    func testAWindowThatWentMissingAgainIsRecenteredAndOnlyThenPutBack() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        let token = addWindow(pid: 474_004, windowId: 34, to: fixture.workspace2, in: controller)
        controller.commandHandler.frontmostAppPidProvider = { 474_004 }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { token }
        controller.isEnabled = true
        controller.hasStartedServices = true

        XCTAssertEqual(controller.bringFocusedWindowFrontAndCenter(), .executed)
        XCTAssertEqual(controller.workspaceManager.workspace(for: token), fixture.workspace1)

        // The floating window wanders off to the inactive workspace again.
        guard case .changed = controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: token),
            toWorkspaceId: fixture.workspace2
        ) else {
            return XCTFail("expected the window to move back to workspace 2")
        }

        XCTAssertEqual(controller.bringFocusedWindowFrontAndCenter(), .executed)
        var entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(entry.mode, .floating, "a lost window is brought back, not tiled")
        XCTAssertEqual(entry.workspaceId, fixture.workspace1)

        XCTAssertEqual(controller.bringFocusedWindowFrontAndCenter(), .executed)
        entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(entry.mode, .tiling, "the original tiled state is remembered across re-centering")
        XCTAssertEqual(entry.workspaceId, fixture.workspace1)
    }

    @MainActor
    func testAFloatingWindowReturnsToItsPreviousSpotOnTheSecondPress() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(474_005), windowId: 35),
            pid: 474_005,
            windowId: 35,
            to: fixture.workspace1,
            mode: .floating
        )
        let previousFrame = CGRect(x: 100, y: 120, width: 500, height: 400)
        controller.workspaceManager.updateFloatingGeometry(
            frame: previousFrame,
            for: token,
            referenceMonitor: fixture.monitor
        )
        controller.commandHandler.frontmostAppPidProvider = { 474_005 }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { token }
        controller.isEnabled = true
        controller.hasStartedServices = true

        XCTAssertEqual(controller.bringFocusedWindowFrontAndCenter(), .executed)
        XCTAssertEqual(
            controller.workspaceManager.floatingState(for: token)?.lastFrame,
            CGRect(x: 240, y: 135, width: 1120, height: 630)
        )

        XCTAssertEqual(controller.bringFocusedWindowFrontAndCenter(), .executed)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(entry.mode, .floating)
        XCTAssertEqual(controller.workspaceManager.floatingState(for: token)?.lastFrame, previousFrame)
        XCTAssertNil(controller.frontAndCenterRestoreStates[token])
    }

    func testCenteredCheckToleratesAppSizeClamping() {
        let centered = CGRect(x: 240, y: 135, width: 1120, height: 630)
        XCTAssertTrue(WMController.isCentered(centered, at: centered))
        XCTAssertTrue(WMController.isCentered(CGRect(x: 400, y: 200, width: 800, height: 500), at: centered))
        XCTAssertFalse(WMController.isCentered(CGRect(x: 0, y: 0, width: 1120, height: 630), at: centered))
    }

    // MARK: - Fixtures

    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let workspace1: WorkspaceDescriptor.ID
        let workspace2: WorkspaceDescriptor.ID
    }

    @MainActor
    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspace: WorkspaceDescriptor.ID,
        in controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspace
        )
    }

    private func makeMonitor(displayId: CGDirectDisplayID, name: String, uuid: String? = nil) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: name,
            displayUUID: uuid
        )
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let monitor = makeMonitor(displayId: 474_000, name: "FrontAndCenter")
        let settings = makeSettingsStore()
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.frontAndCenterFocusedWindowResolver = { _ in nil }
        controller.currentMouseLocation = { CGPoint(x: 10, y: 10) }
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspace1 = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        let workspace2 = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspace1, on: monitor.id))
        controller.layoutRefreshController.resetState()

        return Fixture(controller: controller, monitor: monitor, workspace1: workspace1, workspace2: workspace2)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMFrontAndCenterTests-\(UUID().uuidString)", isDirectory: true)
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
