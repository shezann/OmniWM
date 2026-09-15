// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleCenteredMasterTests: XCTestCase {
    private struct Fixture {
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
    }

    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func makeFixture(centeredMaster: Bool = true, masterRatio: CGFloat = 0.5) -> Fixture {
        let engine = DwindleLayoutEngine()
        engine.settings.centeredMaster = centeredMaster
        engine.settings.masterRatio = masterRatio
        engine.settings.innerGap = 0
        engine.settings.smartSplit = false
        return Fixture(engine: engine, workspaceId: WorkspaceDescriptor.ID())
    }

    private func token(_ number: Int) -> WindowToken {
        WindowToken(pid: pid_t(number), windowId: number)
    }

    @discardableResult
    private func addWindows(_ count: Int, to fixture: Fixture) -> [WindowToken] {
        var tokens: [WindowToken] = []
        for number in 1 ... count {
            let token = token(number)
            _ = fixture.engine.addWindow(token: token, to: fixture.workspaceId, activeWindowFrame: nil)
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            tokens.append(token)
        }
        return tokens
    }

    private func frames(_ fixture: Fixture) -> [WindowToken: CGRect] {
        fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
    }

    private func select(_ token: WindowToken, in fixture: Fixture) {
        fixture.engine.setSelectedNode(
            fixture.engine.findNode(for: token, in: fixture.workspaceId),
            in: fixture.workspaceId
        )
    }

    private func assertFrame(
        _ frame: CGRect?,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let frame else {
            XCTFail("missing frame", file: file, line: line)
            return
        }
        XCTAssertEqual(frame.minX, x, accuracy: 1, "x", file: file, line: line)
        XCTAssertEqual(frame.minY, y, accuracy: 1, "y", file: file, line: line)
        XCTAssertEqual(frame.width, width, accuracy: 1, "width", file: file, line: line)
        XCTAssertEqual(frame.height, height, accuracy: 1, "height", file: file, line: line)
    }

    // MARK: - Shape

    func testSingleWindowFillsTheScreen() {
        let fixture = makeFixture()
        let tokens = addWindows(1, to: fixture)

        assertFrame(frames(fixture)[tokens[0]], x: 0, y: 0, width: 1200, height: 800)
        XCTAssertEqual(fixture.engine.masterToken(in: fixture.workspaceId), tokens[0])
    }

    func testTwoWindowsPutTheMasterLeftAndTheStackRight() {
        let fixture = makeFixture()
        let tokens = addWindows(2, to: fixture)
        let frames = frames(fixture)

        assertFrame(frames[tokens[0]], x: 0, y: 0, width: 600, height: 800)
        assertFrame(frames[tokens[1]], x: 600, y: 0, width: 600, height: 800)
        XCTAssertEqual(fixture.engine.masterToken(in: fixture.workspaceId), tokens[0])
    }

    func testThreeWindowsCenterTheMaster() {
        let fixture = makeFixture()
        let tokens = addWindows(3, to: fixture)
        let frames = frames(fixture)

        assertFrame(frames[tokens[0]], x: 300, y: 0, width: 600, height: 800)
        assertFrame(frames[tokens[1]], x: 900, y: 0, width: 300, height: 800)
        assertFrame(frames[tokens[2]], x: 0, y: 0, width: 300, height: 800)
    }

    func testFiveWindowsAlternateSidesWithEqualStacks() {
        let fixture = makeFixture()
        let tokens = addWindows(5, to: fixture)
        let frames = frames(fixture)

        assertFrame(frames[tokens[0]], x: 300, y: 0, width: 600, height: 800)
        assertFrame(frames[tokens[1]], x: 900, y: 0, width: 300, height: 400)
        assertFrame(frames[tokens[3]], x: 900, y: 400, width: 300, height: 400)
        assertFrame(frames[tokens[2]], x: 0, y: 0, width: 300, height: 400)
        assertFrame(frames[tokens[4]], x: 0, y: 400, width: 300, height: 400)
    }

    func testMasterRatioControlsTheMasterWidth() {
        let fixture = makeFixture(masterRatio: 0.6)
        let tokens = addWindows(3, to: fixture)
        let frames = frames(fixture)

        assertFrame(frames[tokens[0]], x: 240, y: 0, width: 720, height: 800)
        assertFrame(frames[tokens[1]], x: 960, y: 0, width: 240, height: 800)
        assertFrame(frames[tokens[2]], x: 0, y: 0, width: 240, height: 800)
    }

    func testMasterRatioChangeAppliesWithoutRebuildingTheTree() {
        let fixture = makeFixture()
        let tokens = addWindows(3, to: fixture)
        let masterLeafBefore = fixture.engine.findNode(for: tokens[0], in: fixture.workspaceId)

        fixture.engine.settings.masterRatio = 0.7
        fixture.engine.reconcileCenteredMaster(in: fixture.workspaceId)

        XCTAssertTrue(fixture.engine.findNode(for: tokens[0], in: fixture.workspaceId) === masterLeafBefore)
        assertFrame(frames(fixture)[tokens[0]], x: 180, y: 0, width: 840, height: 800)
    }

    // MARK: - Membership changes

    func testClosingTheMasterPromotesTheFirstStackedWindow() {
        let fixture = makeFixture()
        let tokens = addWindows(3, to: fixture)

        fixture.engine.removeWindow(token: tokens[0], from: fixture.workspaceId)
        let frames = frames(fixture)

        XCTAssertEqual(fixture.engine.masterToken(in: fixture.workspaceId), tokens[1])
        assertFrame(frames[tokens[1]], x: 0, y: 0, width: 600, height: 800)
        assertFrame(frames[tokens[2]], x: 600, y: 0, width: 600, height: 800)
    }

    func testClosingAStackedWindowKeepsTheMasterCentered() {
        let fixture = makeFixture()
        let tokens = addWindows(4, to: fixture)

        fixture.engine.removeWindow(token: tokens[1], from: fixture.workspaceId)
        let frames = frames(fixture)

        XCTAssertEqual(fixture.engine.masterToken(in: fixture.workspaceId), tokens[0])
        assertFrame(frames[tokens[0]], x: 300, y: 0, width: 600, height: 800)
        assertFrame(frames[tokens[2]], x: 900, y: 0, width: 300, height: 800)
        assertFrame(frames[tokens[3]], x: 0, y: 0, width: 300, height: 800)
    }

    func testGroupingAndExtractingKeepsTheCenteredShape() {
        let fixture = makeFixture()
        let tokens = addWindows(3, to: fixture)

        XCTAssertTrue(fixture.engine.groupWindow(tokens[2], into: tokens[1], in: fixture.workspaceId))
        var frames = frames(fixture)
        XCTAssertEqual(fixture.engine.centeredMasterOrder(in: fixture.workspaceId).count, 2)
        assertFrame(frames[tokens[0]], x: 0, y: 0, width: 600, height: 800)
        XCTAssertEqual(frames[tokens[2]]?.maxX ?? 0, 1200, accuracy: 1)
        XCTAssertNil(frames[tokens[1]], "inactive group members are hidden")

        XCTAssertTrue(fixture.engine.ungroupWindow(tokens[2], direction: .right, in: fixture.workspaceId))
        frames = self.frames(fixture)
        XCTAssertEqual(fixture.engine.centeredMasterOrder(in: fixture.workspaceId).count, 3)
        assertFrame(frames[tokens[0]], x: 300, y: 0, width: 600, height: 800)
        assertFrame(frames[tokens[1]], x: 900, y: 0, width: 300, height: 800)
        assertFrame(frames[tokens[2]], x: 0, y: 0, width: 300, height: 800)
    }

    func testManualSplitChangesAreRevertedOnTheNextSync() {
        let fixture = makeFixture()
        let tokens = addWindows(3, to: fixture)

        select(tokens[2], in: fixture)
        XCTAssertTrue(fixture.engine.toggleOrientation(in: fixture.workspaceId))
        XCTAssertEqual(fixture.engine.root(for: fixture.workspaceId)?.splitOrientation, .vertical)

        _ = fixture.engine.syncWindows(tokens, in: fixture.workspaceId, focusedToken: tokens[2])

        XCTAssertEqual(fixture.engine.root(for: fixture.workspaceId)?.splitOrientation, .horizontal)
        assertFrame(frames(fixture)[tokens[0]], x: 300, y: 0, width: 600, height: 800)
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), tokens[2])
    }

    // MARK: - Swap with master

    func testSwapWithMasterMovesTheFocusedWindowIntoTheCenter() {
        let fixture = makeFixture()
        let tokens = addWindows(3, to: fixture)

        select(tokens[2], in: fixture)
        XCTAssertTrue(fixture.engine.swapSelectionWithMaster(in: fixture.workspaceId))
        let frames = frames(fixture)

        XCTAssertEqual(fixture.engine.masterToken(in: fixture.workspaceId), tokens[2])
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), tokens[2])
        assertFrame(frames[tokens[2]], x: 300, y: 0, width: 600, height: 800)
        assertFrame(frames[tokens[0]], x: 0, y: 0, width: 300, height: 800)
        assertFrame(frames[tokens[1]], x: 900, y: 0, width: 300, height: 800)

        _ = fixture.engine.syncWindows(tokens, in: fixture.workspaceId, focusedToken: tokens[2])
        assertFrame(self.frames(fixture)[tokens[2]], x: 300, y: 0, width: 600, height: 800)
    }

    func testSwapWithMasterOnTheMasterSwapsWithTheFirstStackedWindow() {
        let fixture = makeFixture()
        let tokens = addWindows(3, to: fixture)

        select(tokens[0], in: fixture)
        XCTAssertTrue(fixture.engine.swapSelectionWithMaster(in: fixture.workspaceId))
        let frames = frames(fixture)

        XCTAssertEqual(fixture.engine.masterToken(in: fixture.workspaceId), tokens[1])
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), tokens[0])
        assertFrame(frames[tokens[1]], x: 300, y: 0, width: 600, height: 800)
        assertFrame(frames[tokens[0]], x: 900, y: 0, width: 300, height: 800)
    }

    func testSwapWithMasterNeedsTwoTiles() {
        let fixture = makeFixture()
        let tokens = addWindows(1, to: fixture)

        select(tokens[0], in: fixture)
        XCTAssertFalse(fixture.engine.swapSelectionWithMaster(in: fixture.workspaceId))
    }

    func testSwapWithMasterIsANoOpWhileCenteredMasterIsOff() {
        let fixture = makeFixture(centeredMaster: false)
        let tokens = addWindows(3, to: fixture)
        let before = frames(fixture)

        select(tokens[2], in: fixture)
        XCTAssertFalse(fixture.engine.swapSelectionWithMaster(in: fixture.workspaceId))
        XCTAssertTrue(fixture.engine.centeredMasterOrder(in: fixture.workspaceId).isEmpty)
        XCTAssertEqual(frames(fixture), before)
    }

    // MARK: - Toggling the setting

    func testEnablingCenteredMasterReshapesAroundTheSelectedWindow() {
        let fixture = makeFixture(centeredMaster: false)
        let tokens = addWindows(3, to: fixture)
        select(tokens[1], in: fixture)

        fixture.engine.settings.centeredMaster = true
        _ = fixture.engine.syncWindows(tokens, in: fixture.workspaceId, focusedToken: tokens[1])
        let frames = frames(fixture)

        XCTAssertEqual(fixture.engine.masterToken(in: fixture.workspaceId), tokens[1])
        assertFrame(frames[tokens[1]], x: 300, y: 0, width: 600, height: 800)
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), tokens[1])
    }

    func testDisablingCenteredMasterKeepsTheTreeAndClearsTheOrder() {
        let fixture = makeFixture()
        let tokens = addWindows(3, to: fixture)
        let before = frames(fixture)

        fixture.engine.settings.centeredMaster = false
        _ = fixture.engine.syncWindows(tokens, in: fixture.workspaceId, focusedToken: tokens[0])

        XCTAssertTrue(fixture.engine.centeredMasterOrder(in: fixture.workspaceId).isEmpty)
        XCTAssertNil(fixture.engine.masterToken(in: fixture.workspaceId))
        XCTAssertEqual(frames(fixture), before)
    }

    func testReenablingCenteredMasterRecoversTheOrderFromTheTree() {
        let fixture = makeFixture()
        let tokens = addWindows(5, to: fixture)
        let orderBefore = fixture.engine.centeredMasterOrder(in: fixture.workspaceId)

        fixture.engine.settings.centeredMaster = false
        _ = fixture.engine.syncWindows(tokens, in: fixture.workspaceId, focusedToken: tokens[4])
        fixture.engine.settings.centeredMaster = true
        _ = fixture.engine.syncWindows(tokens, in: fixture.workspaceId, focusedToken: tokens[4])

        XCTAssertEqual(fixture.engine.centeredMasterOrder(in: fixture.workspaceId), orderBefore)
        XCTAssertEqual(fixture.engine.masterToken(in: fixture.workspaceId), tokens[0])
    }

    // MARK: - Restore

    func testRestoredPlacementsRecoverTheMaster() throws {
        let source = makeFixture()
        let tokens = addWindows(5, to: source)
        let placements = source.engine.persistedPlacements(in: source.workspaceId)

        let restored = makeFixture()
        XCTAssertTrue(restored.engine.restoreInitialPlacements(
            placements,
            matching: tokens,
            in: restored.workspaceId
        ))
        let frames = frames(restored)

        XCTAssertEqual(restored.engine.masterToken(in: restored.workspaceId), tokens[0])
        XCTAssertEqual(
            restored.engine.centeredMasterOrder(in: restored.workspaceId).count,
            tokens.count
        )
        assertFrame(frames[tokens[0]], x: 300, y: 0, width: 600, height: 800)
        assertFrame(frames[tokens[1]], x: 900, y: 0, width: 300, height: 400)
        assertFrame(frames[tokens[2]], x: 0, y: 0, width: 300, height: 400)
    }
}
