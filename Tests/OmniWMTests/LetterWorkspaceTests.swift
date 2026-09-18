// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Carbon
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

/// Letter workspaces (`q`, `w`, `e`) and the workspace-bar editing that renames workspaces.
@MainActor
final class LetterWorkspaceTests: XCTestCase {
    // MARK: - Workspace ID policy

    func testLettersQWEAreValidRawIDsAndNothingElseIs() {
        XCTAssertEqual(WorkspaceIDPolicy.normalizeRawID("q"), "q")
        XCTAssertEqual(WorkspaceIDPolicy.normalizeRawID("W"), "w")
        XCTAssertEqual(WorkspaceIDPolicy.normalizeRawID(" e"), nil)
        XCTAssertEqual(WorkspaceIDPolicy.normalizeRawID("3"), "3")
        XCTAssertEqual(WorkspaceIDPolicy.normalizeRawID("12"), "12")
        XCTAssertNil(WorkspaceIDPolicy.normalizeRawID("r"))
        XCTAssertNil(WorkspaceIDPolicy.normalizeRawID("qq"))
        XCTAssertNil(WorkspaceIDPolicy.normalizeRawID("0"))
        XCTAssertNil(WorkspaceIDPolicy.normalizeRawID(""))
        XCTAssertTrue(WorkspaceIDPolicy.isLetterRawID("q"))
        XCTAssertFalse(WorkspaceIDPolicy.isLetterRawID("1"))
        XCTAssertNil(WorkspaceIDPolicy.workspaceNumber(from: "q"))
        XCTAssertEqual(WorkspaceIDPolicy.workspaceNumber(from: "7"), 7)
    }

    func testNumbersSortBeforeLettersAndLettersFollowTheKeyboardRow() {
        let names = ["e", "10", "w", "2", "q", "1", "zebra"]
        XCTAssertEqual(names.sorted(by: WorkspaceIDPolicy.sortsBefore), ["1", "2", "10", "q", "w", "e", "zebra"])
        XCTAssertEqual(WorkspaceIDPolicy.lowestUnusedRawID(in: ["1", "q", "2"]), "3")
        XCTAssertEqual(WorkspaceTarget(resolvingInput: "Q"), .rawID("q"))
        XCTAssertEqual(WorkspaceTarget(resolvingInput: "Code"), .displayName("Code"))
    }

    // MARK: - Renumber planner

    func testRenumberPlannerDealsTheSameIDsOutByPosition() {
        // Dragging "4" in front of "2" shifts 2 and 3 right by one ID.
        XCTAssertEqual(
            WorkspaceRenumberPlanner.renames(forNewVisualOrder: ["1", "4", "2", "3"]),
            ["4": "2", "2": "3", "3": "4"]
        )
        XCTAssertEqual(WorkspaceRenumberPlanner.renames(forNewVisualOrder: ["1", "2", "3"]), [:])
        // Letters and numbers share one pool; a letter workspace dragged to the front takes "1".
        XCTAssertEqual(
            WorkspaceRenumberPlanner.renames(forNewVisualOrder: ["q", "1", "w"]),
            ["q": "1", "1": "q"]
        )
        // Hidden workspaces are not in the bar, so their IDs are not in the pool: 1, 3, 5 stay 1, 3, 5.
        XCTAssertEqual(
            WorkspaceRenumberPlanner.renames(forNewVisualOrder: ["5", "1", "3"]),
            ["5": "1", "1": "3", "3": "5"]
        )
    }

    func testMovingInsertsAmongTheOtherElementsAndClamps() {
        XCTAssertEqual(WorkspaceRenumberPlanner.moving("d", in: ["a", "b", "c", "d"], toIndex: 1), ["a", "d", "b", "c"])
        XCTAssertEqual(WorkspaceRenumberPlanner.moving("a", in: ["a", "b", "c"], toIndex: 2), ["b", "c", "a"])
        XCTAssertEqual(WorkspaceRenumberPlanner.moving("a", in: ["a", "b", "c"], toIndex: 9), ["b", "c", "a"])
        XCTAssertEqual(WorkspaceRenumberPlanner.moving("b", in: ["a", "b", "c"], toIndex: -3), ["b", "a", "c"])
        XCTAssertEqual(WorkspaceRenumberPlanner.moving("x", in: ["a", "b"], toIndex: 0), ["a", "b"])
    }

    // MARK: - Drag geometry in the bar

    func testDragStateShiftsOnlyThePillsTheDraggedOneHasPassed() {
        let ids = (0 ..< 4).map { _ in UUID() }
        var frames: [WorkspaceDescriptor.ID: CGRect] = [:]
        for (index, id) in ids.enumerated() {
            frames[id] = CGRect(x: CGFloat(index) * 48, y: 0, width: 40, height: 20)
        }
        var drag = WorkspaceBarDragState(workspaceId: ids[0], frames: frames, translation: 0)
        XCTAssertEqual(drag.targetIndex(in: ids), 0)
        XCTAssertEqual(drag.reorderedIds(from: ids), ids)

        // Past the centre of the second pill, but not the third.
        drag.translation = 60
        XCTAssertEqual(drag.offset(for: ids[0], spacing: 8), 60)
        XCTAssertEqual(drag.offset(for: ids[1], spacing: 8), -48)
        XCTAssertEqual(drag.offset(for: ids[2], spacing: 8), 0)
        XCTAssertEqual(drag.targetIndex(in: ids), 1)
        XCTAssertEqual(drag.reorderedIds(from: ids), [ids[1], ids[0], ids[2], ids[3]])

        // Dragging the last pill to the front shifts everything right.
        var backwards = WorkspaceBarDragState(workspaceId: ids[3], frames: frames, translation: -200)
        XCTAssertEqual(backwards.offset(for: ids[0], spacing: 8), 48)
        XCTAssertEqual(backwards.offset(for: ids[2], spacing: 8), 48)
        XCTAssertEqual(backwards.reorderedIds(from: ids), [ids[3], ids[0], ids[1], ids[2]])
        backwards.translation = -10
        XCTAssertEqual(backwards.reorderedIds(from: ids), ids)
    }

    // MARK: - Hotkeys

    func testLetterWorkspacesHaveOptionDefaultsThatDoNotCollide() throws {
        for (letter, keyCode) in [("q", kVK_ANSI_Q), ("w", kVK_ANSI_W), ("e", kVK_ANSI_E)] {
            let switchSpec = try XCTUnwrap(ActionCatalog.spec(for: "switchWorkspace.\(letter)"))
            XCTAssertEqual(switchSpec.command, .switchWorkspaceNamed(letter))
            XCTAssertEqual(
                switchSpec.defaultBinding,
                KeyBinding(keyCode: UInt32(keyCode), modifiers: UInt32(optionKey))
            )
            XCTAssertEqual(switchSpec.title, "Switch to Workspace \(letter.uppercased())")
            XCTAssertEqual(switchSpec.category, .workspace)

            let moveSpec = try XCTUnwrap(ActionCatalog.spec(for: "moveToWorkspace.\(letter)"))
            XCTAssertEqual(moveSpec.command, .moveToWorkspaceNamed(letter))
            XCTAssertEqual(
                moveSpec.defaultBinding,
                KeyBinding(keyCode: UInt32(keyCode), modifiers: UInt32(optionKey | shiftKey))
            )

            let columnSpec = try XCTUnwrap(ActionCatalog.spec(for: "moveColumnToWorkspace.\(letter)"))
            XCTAssertEqual(columnSpec.command, .moveColumnToWorkspaceNamed(letter))
            XCTAssertEqual(columnSpec.defaultBinding, .unassigned)
            XCTAssertEqual(columnSpec.layoutCompatibility, .niri)
            XCTAssertEqual(columnSpec.visibility, .advanced)

            for id in ["switchWorkspace.\(letter)", "moveToWorkspace.\(letter)", "moveColumnToWorkspace.\(letter)"] {
                XCTAssertTrue(SettingsTOMLCodec.hotkeyIDsAddedInVersionSeven.contains(id), id)
            }
        }

        let plan = HotkeyCenter.registrationPlan(for: DefaultHotkeyBindings.all())
        XCTAssertEqual(plan.failures, [:], "default bindings must not conflict with each other")
        XCTAssertTrue(plan.registrations.contains { $0.command == .switchWorkspaceNamed("q") })
    }

    func testOptionQSwitchesToAndMovesWindowsIntoTheLetterWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let manager = fixture.controller.workspaceManager
        let workspaceQ = try XCTUnwrap(manager.workspaceId(named: "q"))
        let token = addFocusedWindow(to: fixture.workspace1, in: fixture)

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.moveToWorkspaceNamed("q")), .executed)
        XCTAssertEqual(manager.workspace(for: token), workspaceQ)

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.switchWorkspaceNamed("q")), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, workspaceQ)

        // An unconfigured letter is a no-op rather than an implicit workspace.
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.switchWorkspaceNamed("e")), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, workspaceQ)
        XCTAssertNil(manager.workspaceId(named: "e"))
    }

    // MARK: - Batch rename in the workspace manager

    func testRenameWorkspacesPermutesNamesAndRebuildsTheIndex() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let manager = fixture.controller.workspaceManager
        let workspaceQ = try XCTUnwrap(manager.workspaceId(named: "q"))
        let token = addFocusedWindow(to: fixture.workspace1, in: fixture)

        XCTAssertTrue(manager.renameWorkspaces([fixture.workspace1: "3", fixture.workspace3: "1"]))
        XCTAssertEqual(manager.descriptor(for: fixture.workspace1)?.name, "3")
        XCTAssertEqual(manager.descriptor(for: fixture.workspace3)?.name, "1")
        XCTAssertEqual(manager.workspaceId(named: "3"), fixture.workspace1)
        XCTAssertEqual(manager.workspaceId(named: "1"), fixture.workspace3)
        XCTAssertEqual(manager.workspace(for: token), fixture.workspace1, "windows stay with their workspace")
        XCTAssertEqual(
            manager.workspaces(on: fixture.monitorA.id).map(\.id),
            [fixture.workspace3, fixture.workspace1, workspaceQ],
            "the bar order follows the new names"
        )

        XCTAssertFalse(manager.renameWorkspaces([fixture.workspace1: "2"]), "2 belongs to an untouched workspace")
        XCTAssertFalse(manager.renameWorkspaces([fixture.workspace1: "x"]), "x is not a workspace ID")
        XCTAssertFalse(manager.renameWorkspaces([fixture.workspace1: "5", fixture.workspace3: "5"]))
        XCTAssertFalse(manager.renameWorkspaces([fixture.workspace1: "3"]), "nothing to change")
        XCTAssertEqual(manager.descriptor(for: fixture.workspace1)?.name, "3")
    }

    // MARK: - Bar editing through the controller

    func testDoubleClickRenameMovesTheIDAndItsConfigurationAndRules() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        let settings = controller.settings
        settings.appRules = [AppRule(bundleId: "com.example.editor", assignToWorkspace: "3")]
        let token = addFocusedWindow(to: fixture.workspace3, in: fixture)

        XCTAssertFalse(controller.renameWorkspaceFromBar(id: fixture.workspace3, to: "banana"))
        XCTAssertFalse(controller.renameWorkspaceFromBar(id: fixture.workspace3, to: "1"), "1 is taken")
        XCTAssertTrue(controller.renameWorkspaceFromBar(id: fixture.workspace3, to: " W "))

        let manager = controller.workspaceManager
        XCTAssertEqual(manager.descriptor(for: fixture.workspace3)?.name, "w")
        XCTAssertEqual(manager.workspace(for: token), fixture.workspace3)
        XCTAssertEqual(settings.workspaceConfigurations.map(\.name), ["1", "2", "q", "w"])
        let renamed = try XCTUnwrap(settings.workspaceConfigurations.first { $0.name == "w" })
        XCTAssertEqual(renamed.monitorAssignment, .specificDisplay(OutputId(from: fixture.monitorA)))
        XCTAssertEqual(renamed.displayName, "Code", "the display name travels with the workspace")
        XCTAssertEqual(settings.appRules.first?.assignToWorkspace, "w")
        XCTAssertNil(manager.workspaceId(named: "3"))

        // The hotkey for the new letter now reaches the renamed workspace.
        XCTAssertEqual(controller.commandHandler.performCommand(.switchWorkspaceNamed("w")), .executed)
        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.workspace3)
        XCTAssertTrue(controller.renameWorkspaceFromBar(id: fixture.workspace3, to: "w"), "same ID is a no-op success")
    }

    func testDragReorderRenumbersOnlyTheWorkspacesShownInThatBar() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let workspaceQ = try XCTUnwrap(manager.workspaceId(named: "q"))

        // Monitor A shows 1, 3, q. Drag q to the front: q -> 1, 1 -> 3, 3 -> q. Monitor B's "2" is untouched.
        XCTAssertTrue(controller.reorderWorkspacesFromBar(orderedIds: [
            workspaceQ,
            fixture.workspace1,
            fixture.workspace3
        ]))
        XCTAssertEqual(manager.descriptor(for: workspaceQ)?.name, "1")
        XCTAssertEqual(manager.descriptor(for: fixture.workspace1)?.name, "3")
        XCTAssertEqual(manager.descriptor(for: fixture.workspace3)?.name, "q")
        XCTAssertEqual(manager.descriptor(for: fixture.workspace2)?.name, "2")
        XCTAssertEqual(
            manager.workspaces(on: fixture.monitorA.id).map(\.id),
            [workspaceQ, fixture.workspace1, fixture.workspace3]
        )
        XCTAssertEqual(controller.settings.workspaceConfigurations.map(\.name), ["1", "2", "3", "q"])
        XCTAssertEqual(
            controller.settings.workspaceConfigurations.first { $0.name == "q" }?.displayName,
            "Code",
            "the configuration that was 3 is now q"
        )

        XCTAssertFalse(controller.reorderWorkspacesFromBar(orderedIds: [
            workspaceQ,
            fixture.workspace1,
            fixture.workspace3
        ]))
        XCTAssertFalse(controller.reorderWorkspacesFromBar(orderedIds: [workspaceQ, UUID()]))
    }

    func testSettingsSheetAcceptsOnlyUnusedValidIDs() {
        let configurations = [WorkspaceConfiguration(name: "1"), WorkspaceConfiguration(name: "q")]
        XCTAssertTrue(WorkspaceConfigurationAddPolicy.isValidNewWorkspaceName("w", in: configurations))
        XCTAssertTrue(WorkspaceConfigurationAddPolicy.isValidNewWorkspaceName("2", in: configurations))
        XCTAssertFalse(WorkspaceConfigurationAddPolicy.isValidNewWorkspaceName("Q", in: configurations))
        XCTAssertFalse(WorkspaceConfigurationAddPolicy.isValidNewWorkspaceName("1", in: configurations))
        XCTAssertFalse(WorkspaceConfigurationAddPolicy.isValidNewWorkspaceName("z", in: configurations))
    }

    func testLabelEditorFrameIsCentredOnTheLabel() {
        let frame = WorkspaceLabelEditorController.frame(anchoredTo: CGRect(x: 100, y: 50, width: 8, height: 16))
        XCTAssertEqual(frame.midX, 104)
        XCTAssertEqual(frame.midY, 58)
        XCTAssertEqual(frame.width, 40)
        XCTAssertEqual(frame.height, 24)
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let controller: WMController
        let monitorA: Monitor
        let monitorB: Monitor
        let workspace1: WorkspaceDescriptor.ID
        let workspace2: WorkspaceDescriptor.ID
        let workspace3: WorkspaceDescriptor.ID
    }

    private func addFocusedWindow(to workspaceId: WorkspaceDescriptor.ID, in fixture: Fixture) -> WindowToken {
        let manager = fixture.controller.workspaceManager
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(474_001), windowId: 11),
            pid: 474_001,
            windowId: 11,
            to: workspaceId
        )
        manager.withEngineMutationScope(in: workspaceId) {
            _ = fixture.controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        XCTAssertTrue(manager.setManagedFocus(token, in: workspaceId))
        return token
    }

    /// Monitor A holds 1, 3 (display name "Code") and q; monitor B holds 2.
    private func makeFixture() throws -> Fixture {
        let monitorA = makeMonitor(displayId: 474_100, name: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let monitorB = makeMonitor(
            displayId: 474_101,
            name: "B",
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMLetterWorkspaceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let settings = SettingsStore(
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
        let onA = MonitorAssignment.specificDisplay(OutputId(from: monitorA))
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: onA, layoutType: .niri),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: monitorB)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(name: "3", displayName: "Code", monitorAssignment: onA, layoutType: .niri),
            WorkspaceConfiguration(name: "q", monitorAssignment: onA, layoutType: .niri)
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let niriEngine = NiriLayoutEngine()
        niriEngine.animationClock = controller.animationClock
        controller.niriEngine = niriEngine
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitorA, monitorB])
        manager.applySettings()
        let workspace1 = try XCTUnwrap(manager.workspaceId(named: "1"))
        let workspace2 = try XCTUnwrap(manager.workspaceId(named: "2"))
        let workspace3 = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertNotNil(manager.workspaceId(named: "q"))
        XCTAssertTrue(manager.setActiveWorkspace(workspace1, on: monitorA.id, updateInteractionMonitor: false))
        XCTAssertTrue(manager.setActiveWorkspace(workspace2, on: monitorB.id, updateInteractionMonitor: false))
        _ = manager.setInteractionMonitor(monitorA.id)
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            monitorA: monitorA,
            monitorB: monitorB,
            workspace1: workspace1,
            workspace2: workspace2,
            workspace3: workspace3
        )
    }

    private func makeMonitor(displayId: CGDirectDisplayID, name: String, frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }
}
