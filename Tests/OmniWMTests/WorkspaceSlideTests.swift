// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSlideTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let source: WorkspaceDescriptor.ID
        let target: WorkspaceDescriptor.ID
        let outgoing: WindowToken
        let incoming: WindowToken
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings, windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
        ))
        controller.enableNiriLayout()
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: -1600, y: 200, width: 1600, height: 900),
            visibleFrame: CGRect(x: -1600, y: 200, width: 1600, height: 900),
            hasNotch: false,
            name: "Slide"
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        let source = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let target = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        XCTAssertTrue(manager.setActiveWorkspace(source, on: monitor.id))
        func add(_ workspace: WorkspaceDescriptor.ID, _ id: Int) -> WindowToken {
            let token = manager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid_t(id)), windowId: id),
                pid: pid_t(id),
                windowId: id,
                to: workspace
            )
            _ = controller.niriEngine?.addWindow(token: token, to: workspace, afterSelection: nil)
            return token
        }
        let outgoing = add(source, 981001)
        let incoming = add(target, 981002)
        manager.setHiddenState(HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: monitor.id,
            reason: .workspaceInactive
        ), for: incoming)
        controller.workspaceSlideController.frameProvider = { entry in
            CGRect(x: entry.token == outgoing ? -1500 : 3000, y: 300, width: 700, height: 700)
        }
        controller.workspaceSlideController.presentForTests = { _, _ in true }
        controller.workspaceSlideController.now = { 100 }
        addTeardownBlock { @MainActor in
            controller.workspaceSlideController.cancel(requestRelayout: false)
            controller.layoutRefreshController.resetState()
        }
        return Fixture(
            controller: controller,
            monitor: monitor,
            source: source,
            target: target,
            outgoing: outgoing,
            incoming: incoming
        )
    }

    private func begin(_ f: Fixture, axis: WorkspaceSwipeAxis = .horizontal) {
        XCTAssertTrue(f.controller.workspaceSlideController.begin(
            source: f.source,
            monitorId: f.monitor.id,
            axis: axis,
            naturalDirection: true,
            triggerDistance: 140
        ))
    }

    func testLiveWindowsMoveTogetherBeforeSelectionChanges() throws {
        let f = try fixture()
        var positions: [WindowToken: CGRect] = [:]
        var clip: CGRect?
        f.controller.workspaceSlideController.presentForTests = { updates, rect in
            positions = Dictionary(updates, uniquingKeysWith: { _, last in last })
            clip = rect
            return true
        }
        begin(f)
        let incomingFrame = try XCTUnwrap(f.controller.workspaceSlideController.session?.windows.first {
            $0.entry.token == f.incoming
        }?.frame)
        f.controller.workspaceSlideController.update(displacement: -70)
        XCTAssertEqual(positions[f.outgoing]?.minX, -1900)
        XCTAssertEqual(positions[f.incoming]?.minX, incomingFrame.minX + 1200)
        XCTAssertEqual(clip, f.monitor.frame)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
        XCTAssertTrue(f.controller.workspaceManager.hiddenState(for: f.incoming)?.workspaceInactive == true)
        XCTAssertTrue(f.controller.shouldSuppressManagedFocusRecovery)
    }

    func testDistanceThresholdWaitsForReleaseAndSpringCompletion() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
        f.controller.workspaceSlideController.release(velocity: 0, cancelled: false)
        f.controller.workspaceSlideController.tick(at: 100.01, displayId: f.monitor.displayId)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
        f.controller.workspaceSlideController.tick(at: 110, displayId: f.monitor.displayId)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.target)
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
    }

    func testReversingBelowThresholdReturnsToOriginalWorkspace() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        f.controller.workspaceSlideController.update(displacement: -20)
        f.controller.workspaceSlideController.release(velocity: 0, cancelled: false)
        f.controller.workspaceSlideController.tick(at: 110, displayId: f.monitor.displayId)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
    }

    func testCancelAfterThresholdNeverCommits() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        f.controller.workspaceSlideController.release(velocity: -2000, cancelled: true)
        f.controller.workspaceSlideController.tick(at: 110, displayId: f.monitor.displayId)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
    }

    func testFlickCommitsBelowDistanceThreshold() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -50)
        f.controller.workspaceSlideController.release(velocity: -1000, cancelled: false)
        f.controller.workspaceSlideController.tick(at: 110, displayId: f.monitor.displayId)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.target)
    }

    func testOpposingFlickDoesNotCommitBelowThreshold() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -50)
        f.controller.workspaceSlideController.release(velocity: 1000, cancelled: false)
        f.controller.workspaceSlideController.tick(at: 110, displayId: f.monitor.displayId)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
    }

    func testCancellationRestoresParkingAndReleasesAXOwnership() throws {
        let f = try fixture()
        var batches: [[WindowToken: CGRect]] = []
        f.controller.workspaceSlideController.presentForTests = { updates, _ in
            batches.append(Dictionary(updates, uniquingKeysWith: { _, last in last }))
            return true
        }
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -100)
        f.controller.workspaceSlideController.cancel()
        XCTAssertTrue(batches.contains { $0[f.outgoing]?.minX == -1500 && $0[f.incoming]?.minX == 3000 })
        XCTAssertTrue(f.controller.axManager.workspaceSlideTokens.isEmpty)
        XCTAssertFalse(f.controller.workspaceSlideController.owns(windowId: f.incoming.windowId))
    }

    func testLayoutExecutionCannotOverwritePreview() throws {
        let f = try fixture()
        begin(f)
        XCTAssertTrue(f.controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [f.source, f.target])
            .isEmpty)
        f.controller.layoutRefreshController.hideInactiveWorkspacesSync()
        XCTAssertTrue(f.controller.workspaceSlideController.isActive)
    }

    func testUnrelatedMonitorTickDoesNotAdvanceSlide() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        f.controller.workspaceSlideController.release(velocity: 0, cancelled: false)
        f.controller.workspaceSlideController.tick(at: 110, displayId: 2)
        XCTAssertTrue(f.controller.workspaceSlideController.isActive)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
    }

    func testDisplayLinkFailureReleasesOwnership() throws {
        let f = try fixture()
        f.controller.layoutRefreshController.displayLinkActivationForTests = nil
        f.controller.layoutRefreshController.displayLinkCreationAllowedForTests = { _ in false }
        XCTAssertFalse(f.controller.workspaceSlideController.begin(
            source: f.source,
            monitorId: f.monitor.id,
            axis: .vertical,
            naturalDirection: true,
            triggerDistance: 140
        ))
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
    }

    func testStationaryFingersHoldThePreview() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        f.controller.workspaceSlideController.now = { 112 }
        f.controller.workspaceSlideController.tick(at: 112, displayId: f.monitor.displayId)
        XCTAssertTrue(f.controller.workspaceSlideController.isActive)
        XCTAssertEqual(f.controller.workspaceSlideController.session?.progress ?? 0, 200 / 280, accuracy: 0.001)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
    }

    func testRuntimeInvalidationCancelsPreview() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        _ = f.controller.workspaceManager.setActiveWorkspace(f.target, on: f.monitor.id)
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.target)
    }

    func testLandingParksUsingTheOriginalFrameBeforeAXCompletes() throws {
        let f = try fixture()
        let original = try XCTUnwrap(f.controller.workspaceSlideController.frameProvider(
            try XCTUnwrap(f.controller.workspaceManager.entry(for: f.outgoing))
        ))
        // The server still reports the last slide frame while the final AX position update is queued.
        f.controller.layoutRefreshController.fastFrameProvider = { token, _ in
            token == f.outgoing ? original.offsetBy(dx: -1400, dy: 0) : nil
        }
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -250)
        f.controller.workspaceSlideController.release(velocity: 0, cancelled: false)
        f.controller.workspaceSlideController.tick(at: 110, displayId: f.monitor.displayId)

        let hidden = try XCTUnwrap(f.controller.workspaceManager.hiddenState(for: f.outgoing))
        XCTAssertEqual(hidden.referenceMonitorId, f.monitor.id)
        XCTAssertEqual(hidden.proportionalPosition, f.controller.layoutRefreshController.proportionalPosition(
            topLeft: original.topLeftCorner, in: f.monitor.frame
        ))
    }

    func testUnreadableVisibleWindowRejectsPartialPreview() throws {
        let f = try fixture()
        let readFrame = f.controller.workspaceSlideController.frameProvider
        f.controller.workspaceSlideController.frameProvider = { entry in
            entry.token == f.outgoing ? nil : readFrame(entry)
        }
        XCTAssertFalse(f.controller.workspaceSlideController.begin(
            source: f.source, monitorId: f.monitor.id, axis: .horizontal,
            naturalDirection: true, triggerDistance: 140
        ))
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
    }

    func testRemovalReleasesAXOwnershipBeforeDiscardingWindowIdentity() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -100)
        _ = f.controller.workspaceManager.removeWindow(pid: f.outgoing.pid, windowId: f.outgoing.windowId)
        XCTAssertTrue(f.controller.axManager.workspaceSlideTokens.isEmpty)
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
        XCTAssertNil(f.controller.workspaceManager.entry(for: f.outgoing))
    }

    func testFocusAcknowledgementDoesNotCancelPreview() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -100)
        _ = f.controller.workspaceManager.rememberFocus(f.outgoing, in: f.source)
        XCTAssertTrue(f.controller.workspaceSlideController.isActive)
    }

    func testRekeyReleasesOldAXOwnership() throws {
        let f = try fixture()
        begin(f)
        let replacement = WindowToken(pid: f.outgoing.pid, windowId: f.outgoing.windowId + 10)
        let window = AXWindowRef(
            element: AXUIElementCreateApplication(replacement.pid), windowId: replacement.windowId
        )
        XCTAssertNotNil(f.controller.workspaceManager.rekeyWindow(
            from: f.outgoing, to: replacement, newAXRef: window
        ))
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
        XCTAssertTrue(f.controller.axManager.workspaceSlideTokens.isEmpty)
    }

    func testLandingDoesNotRestoreOutgoingWindowsToTheScreen() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        f.controller.workspaceSlideController.release(velocity: 0, cancelled: false)
        var restoredOutgoing = false
        f.controller.workspaceSlideController.presentForTests = { positions, _ in
            if positions.contains(where: { $0.0 == f.outgoing && $0.1.minX == -1500 }) {
                restoredOutgoing = true
            }
            return true
        }
        f.controller.workspaceSlideController.tick(at: 110, displayId: f.monitor.displayId)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.target)
        XCTAssertFalse(restoredOutgoing)
        XCTAssertTrue(f.controller.axManager.workspaceSlideTokens.isEmpty)
    }

    func testPresentationFailureRestoresOriginalPositions() throws {
        let f = try fixture()
        var positions: [WindowToken: CGRect] = [:]
        f.controller.workspaceSlideController.presentForTests = { updates, _ in
            positions.merge(Dictionary(uniqueKeysWithValues: updates), uniquingKeysWith: { _, last in last })
            return true
        }
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -100)
        XCTAssertNotEqual(positions[f.outgoing]?.minX, -1500)
        var rejectNext = true
        f.controller.workspaceSlideController.presentForTests = { updates, _ in
            if rejectNext { rejectNext = false
                return false
            }
            positions.merge(Dictionary(uniqueKeysWithValues: updates), uniquingKeysWith: { _, last in last })
            return true
        }
        f.controller.workspaceSlideController.update(displacement: -120)
        XCTAssertEqual(positions[f.outgoing]?.minX, -1500)
        XCTAssertEqual(positions[f.incoming]?.minX, 3000)
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
        XCTAssertTrue(f.controller.axManager.workspaceSlideTokens.isEmpty)
    }

    func testFailedLandingDoesNotCommitWorkspaceOrFocus() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        f.controller.workspaceSlideController.release(velocity: 0, cancelled: false)
        // Allow rollback of both workspaces, but reject the incoming workspace's landing move.
        f.controller.workspaceSlideController.presentForTests = { updates, _ in updates.count != 1 }
        f.controller.workspaceSlideController.tick(at: 110, displayId: f.monitor.displayId)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
    }

    func testDirectionReversalReparksTheUnselectedNeighbor() throws {
        let f = try fixture()
        var positions: [WindowToken: CGRect] = [:]
        f.controller.workspaceSlideController.presentForTests = { updates, _ in
            positions = Dictionary(updates, uniquingKeysWith: { _, last in last })
            return true
        }
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -100)
        XCTAssertNotEqual(positions[f.incoming]?.minX, 3000)
        f.controller.workspaceSlideController.update(displacement: 100)
        XCTAssertEqual(positions[f.incoming]?.minX, 3000)
        XCTAssertEqual(positions[f.outgoing]?.minX ?? 0, -1500 + 1600 * 100 / 280, accuracy: 0.001)
    }

    func testFloatingWindowStateSurvivesPreviewAndCancellation() throws {
        let f = try fixture()
        let manager = f.controller.workspaceManager
        XCTAssertTrue(manager.setWindowMode(.floating, for: f.incoming))
        let floatingState = FloatingState(
            lastFrame: CGRect(x: -1300, y: 350, width: 700, height: 700),
            normalizedOrigin: nil,
            referenceMonitorId: f.monitor.id,
            restoreToFloating: true
        )
        manager.setFloatingState(floatingState, for: f.incoming)
        begin(f)
        XCTAssertTrue(f.controller.workspaceSlideController.owns(windowId: f.incoming.windowId))
        f.controller.workspaceSlideController.update(displacement: -200)
        XCTAssertEqual(manager.floatingState(for: f.incoming), floatingState)
        f.controller.workspaceSlideController.cancel()
        XCTAssertEqual(manager.floatingState(for: f.incoming), floatingState)
    }

    func testDwindleWindowsParticipateInLivePreview() throws {
        let f = try fixture()
        f.controller.settings.workspaceConfigurations = f.controller.settings.workspaceConfigurations.map {
            $0.with(layoutType: .dwindle)
        }
        f.controller.enableDwindleLayout()
        begin(f, axis: .vertical)
        XCTAssertTrue(f.controller.workspaceSlideController.owns(windowId: f.outgoing.windowId))
        XCTAssertTrue(f.controller.workspaceSlideController.owns(windowId: f.incoming.windowId))
        f.controller.workspaceSlideController.update(displacement: 200)
        f.controller.workspaceSlideController.release(velocity: 0, cancelled: false)
        f.controller.workspaceSlideController.tick(at: 110, displayId: f.monitor.displayId)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.target)
    }

    func testNewGestureCompletesPreviouslyReleasedSwitch() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        f.controller.workspaceSlideController.release(velocity: 0, cancelled: false)
        f.controller.workspaceSlideController.prepareForNewGesture()
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.target)
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
    }

    func testSourceReplacementCancelsReleasedSpring() throws {
        let f = try fixture()
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        f.controller.workspaceSlideController.release(velocity: 0, cancelled: false)
        f.controller.mouseEventHandler.resetForMultitouchSourceReplacement()
        f.controller.workspaceSlideController.tick(at: 110, displayId: f.monitor.displayId)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
    }

    func testDisabledAnimationsCommitOnRelease() throws {
        let f = try fixture()
        f.controller.motionPolicy.animationsEnabled = false
        begin(f)
        f.controller.workspaceSlideController.update(displacement: -200)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.source)
        f.controller.workspaceSlideController.release(velocity: 0, cancelled: false)
        XCTAssertEqual(f.controller.workspaceManager.activeWorkspace(on: f.monitor.id)?.id, f.target)
        XCTAssertFalse(f.controller.workspaceSlideController.isActive)
    }

    func testVerticalGeometryAndInversion() {
        let monitor = CGRect(x: -1600, y: 200, width: 1600, height: 900)
        XCTAssertEqual(
            WorkspaceSlideGeometry.offset(axis: .vertical, progress: 0.25, page: 0, monitor: monitor),
            CGPoint(x: 0, y: 225)
        )
        XCTAssertEqual(
            WorkspaceSlideGeometry.offset(axis: .vertical, progress: 0.25, page: 1, monitor: monitor),
            CGPoint(x: 0, y: -675)
        )
        XCTAssertEqual(WorkspaceSlideGeometry.progress(
            axis: .vertical,
            displacement: 70,
            naturalDirection: false,
            triggerDistance: 140
        ), -0.25)
        XCTAssertEqual(WorkspaceSlideGeometry.progress(
            axis: .horizontal,
            displacement: .nan,
            naturalDirection: true,
            triggerDistance: 140
        ), 0)
    }
}
