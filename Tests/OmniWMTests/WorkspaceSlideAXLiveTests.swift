// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSlideAXLiveTests: XCTestCase {
    func testInactiveForeignWindowFollowsSlidePositionsAndReleasesOwnership() async throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_SKYLIGHT_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set OMNIWM_RUN_SKYLIGHT_LIVE_TESTS=1 to run off-screen native window tests")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("Accessibility access is required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "WorkspaceSlideWindow", withExtension: "swift", subdirectory: "Fixtures"
        ))
        let executable = root.appendingPathComponent("slide-window")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", fixture.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let ready = root.appendingPathComponent("ready")
        let child = Process()
        child.executableURL = executable
        child.arguments = [ready.path]
        try child.run()
        defer { if child.isRunning { child.terminate()
            child.waitUntilExit()
        } }
        for _ in 0 ..< 250 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let windowId = try XCTUnwrap(Int(String(contentsOf: ready, encoding: .utf8)))
        let pid = child.processIdentifier
        let app = try XCTUnwrap(NSRunningApplication(processIdentifier: pid))
        let created = try await AppAXContext.getOrCreate(app)
        let context = try XCTUnwrap(created)
        defer { context.destroy() }
        let window = try XCTUnwrap(AXWindowService.axWindowRef(for: UInt32(windowId), pid: pid))
        let binding = await withCheckedContinuation { continuation in
            context.bindWindows([windowId: window]) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(binding, .bound)
        let original = try XCTUnwrap(AXWindowService.fastFrame(window))
        let manager = AXManager()
        let token = WindowToken(pid: pid, windowId: windowId)
        manager.markWindowInactive(windowId)
        manager.suppressFrameWrites([(pid, windowId)])
        manager.beginWorkspaceSlideFrameWrites([token])
        defer { manager.endWorkspaceSlideFrameWrites([token]) }

        // Use the production writer, with no presentation mock, while the window is
        // still classified as belonging to an inactive workspace.
        for distance in [40.0, 90.0, 20.0, 0.0] {
            let target = original.offsetBy(dx: distance, dy: 0)
            XCTAssertTrue(manager.applyWorkspaceSlidePositions([
                .init(pid: pid, window: window, frame: target, components: .position)
            ]))
            let observed = await waitForFrame(window, matching: target)
            XCTAssertEqual(observed, target)
            XCTAssertTrue(manager.inactiveWorkspaceWindowIds.contains(windowId))
        }
        // Ordinary layout and parking cannot replace an in-progress slide.
        manager.applyFramesParallel([.init(pid: pid, window: window, frame: original.offsetBy(dx: 250, dy: 0))])
        manager.applyParkFramesParallel([.init(pid: pid, window: window, frame: original.offsetBy(dx: 350, dy: 0))])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(AXWindowService.fastFrame(window), original)
        manager.endWorkspaceSlideFrameWrites([token])
        XCTAssertFalse(manager.applyWorkspaceSlidePositions([
            .init(pid: pid, window: window, frame: original.offsetBy(dx: 80, dy: 0), components: .position)
        ]))
        manager.markWindowActive(windowId)
        let settled = original.offsetBy(dx: 30, dy: 0)
        manager.applyFramesParallel([.init(pid: pid, window: window, frame: settled, components: .position)])
        let observed = await waitForFrame(window, matching: settled)
        XCTAssertEqual(observed, settled)
        try await assertControllerSlidesForeignWindow(window, pid: pid, root: root)
    }

    private func assertControllerSlidesForeignWindow(_ window: AXWindowRef, pid: pid_t, root: URL) async throws {
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        controller.enableNiriLayout()
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let monitor = Monitor(
            id: .init(displayId: 90100), displayId: 90100,
            frame: CGRect(x: -12000, y: -10000, width: 1600, height: 900),
            visibleFrame: CGRect(x: -12000, y: -10000, width: 1600, height: 900),
            hasNotch: false, name: "Off-screen slide test"
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        let source = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let target = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        XCTAssertTrue(manager.setActiveWorkspace(source, on: monitor.id))
        let token = manager.addWindow(window, pid: pid, windowId: window.windowId, to: target)
        _ = controller.niriEngine?.addWindow(token: token, to: target, afterSelection: nil)
        controller.axManager.markWindowInactive(window.windowId)
        controller.workspaceSlideController.now = { 100 }
        defer {
            controller.workspaceSlideController.cancel(requestRelayout: false)
            controller.layoutRefreshController.resetState()
        }
        XCTAssertTrue(controller.workspaceSlideController.begin(
            source: source, monitorId: monitor.id, axis: .horizontal,
            naturalDirection: true, triggerDistance: 140
        ))
        let captured = try XCTUnwrap(controller.workspaceSlideController.session?.windows.first)
        for displacement in [-70.0, -140.0, -35.0] {
            controller.workspaceSlideController.update(displacement: displacement)
            let expected = captured.frame.offsetBy(dx: monitor.frame.width * (1 + displacement / 280), dy: 0)
            let observed = await waitForFrame(window, matching: expected)
            XCTAssertEqual(observed, expected)
            XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, source)
        }
        controller.workspaceSlideController.now = { 120 }
        controller.workspaceSlideController.tick(at: 120, displayId: monitor.displayId)
        XCTAssertTrue(controller.workspaceSlideController.isActive)
        controller.workspaceSlideController.update(displacement: 70)
        let reversed = await waitForFrame(window, matching: captured.originalFrame)
        XCTAssertEqual(reversed, captured.originalFrame)
    }

    private func waitForFrame(_ window: AXWindowRef, matching target: CGRect) async -> CGRect? {
        for _ in 0 ..< 100 {
            let frame = AXWindowService.fastFrame(window)
            if frame == target { return frame }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return AXWindowService.fastFrame(window)
    }
}
