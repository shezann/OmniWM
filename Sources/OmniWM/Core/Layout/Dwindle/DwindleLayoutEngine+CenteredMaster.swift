// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

/// Centered-master shaping for the Dwindle tree.
///
/// While `DwindleSettings.centeredMaster` is on, every Dwindle workspace keeps one master tile in the
/// middle column and stacks the remaining tiles in a left and a right column. The tree stays an
/// ordinary binary split tree, so the existing Dwindle operations keep working; the engine simply
/// re-shapes the tree whenever the set of tiles changes and the current shape no longer matches.
///
/// Expected shapes, where `M` is the master and `S1, S2, ...` are stack members in insertion order:
///
///     1 tile    M
///     2 tiles   [M | S1]
///     3+ tiles  [left | [M | right]]    right = S1, S3, S5 ...    left = S2, S4, S6 ...
///
/// Each stack is a chain of vertical splits with equal heights.
extension DwindleLayoutEngine {
    // MARK: - Queries

    /// Tile ids in centered-master order: the first entry is the master, the rest are stack members
    /// in insertion order. Empty while centered master is off.
    func centeredMasterOrder(in workspaceId: WorkspaceDescriptor.ID) -> [DwindleTileId] {
        workspaceState(for: workspaceId)?.masterOrder ?? []
    }

    func masterToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        guard let state = workspaceState(for: workspaceId),
              let masterId = state.masterOrder.first
        else { return nil }
        return leafNodesByTileId(in: state)[masterId]?.tile?.activeToken
    }

    // MARK: - Commands

    /// Swaps the selected tile with the master tile. When the master itself is selected, it swaps
    /// with the first stack member instead, mirroring Hyprland's `swapwithmaster` auto mode.
    /// Returns `false` while centered master is off or the workspace has fewer than two tiles.
    @discardableResult
    func swapSelectionWithMaster(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard settings.centeredMaster, let state = workspaceState(for: workspaceId) else { return false }
        reconcileCenteredMaster(state: state, in: workspaceId)
        guard state.masterOrder.count >= 2,
              let selectedTile = selectedNode(in: workspaceId)?.tile
        else { return false }

        let masterId = state.masterOrder[0]
        let partnerId = selectedTile.id == masterId ? state.masterOrder[1] : masterId
        guard let partnerToken = leafNodesByTileId(in: state)[partnerId]?.tile?.activeToken else { return false }
        return swapLeafTiles(of: selectedTile.activeToken, and: partnerToken, in: workspaceId)
    }

    // MARK: - Reconciliation

    func reconcileCenteredMaster(in workspaceId: WorkspaceDescriptor.ID) {
        guard let state = workspaceState(for: workspaceId) else { return }
        reconcileCenteredMaster(state: state, in: workspaceId)
    }

    /// Brings the workspace tree in line with the centered-master settings. Called after every
    /// change to the set of tiles and after every window sync, so a settings change takes effect on
    /// the next relayout. Manual split changes survive until the tile set changes again.
    func reconcileCenteredMaster(state: DwindleWorkspaceState, in workspaceId: WorkspaceDescriptor.ID) {
        guard settings.centeredMaster else {
            state.masterOrder.removeAll()
            state.appliedMasterRatio = nil
            return
        }

        let leavesById = leafNodesByTileId(in: state)
        let treeOrder = state.root.collectAllLeaves().compactMap { $0.tile?.id }
        guard !treeOrder.isEmpty else {
            state.masterOrder.removeAll()
            return
        }

        // A seeded order adopts a matching tree as-is so persisted ratios survive a restore. Once an
        // order exists, any change in membership re-applies the canonical layout, because a collapsed
        // split can leave a matching shape with ratios inherited from a different role.
        var membershipChanged = false
        if state.masterOrder.isEmpty {
            state.masterOrder = seededMasterOrder(state: state, treeOrder: treeOrder, in: workspaceId)
        } else {
            let previousMembers = Set(state.masterOrder)
            let present = Set(treeOrder)
            state.masterOrder.removeAll { !present.contains($0) }
            let known = Set(state.masterOrder)
            state.masterOrder.append(contentsOf: treeOrder.filter { !known.contains($0) })
            membershipChanged = previousMembers != Set(state.masterOrder)
        }

        let masterRatio = settings.clampedMasterRatio(settings.masterRatio)
        if membershipChanged || !hasCenteredMasterShape(root: state.root, order: state.masterOrder) {
            rebuildCenteredMasterTree(
                state: state,
                leavesById: leavesById,
                masterRatio: masterRatio,
                in: workspaceId
            )
            state.appliedMasterRatio = masterRatio
        } else if state.appliedMasterRatio != masterRatio {
            applyCenteredMasterRatios(root: state.root, tileCount: state.masterOrder.count, masterRatio: masterRatio)
            state.appliedMasterRatio = masterRatio
        }
    }

    // MARK: - Order seeding

    private func seededMasterOrder(
        state: DwindleWorkspaceState,
        treeOrder: [DwindleTileId],
        in workspaceId: WorkspaceDescriptor.ID
    ) -> [DwindleTileId] {
        if let detected = detectCenteredMasterOrder(root: state.root) {
            return detected
        }
        var order = treeOrder
        if let selectedId = selectedNode(in: workspaceId)?.tile?.id,
           let index = order.firstIndex(of: selectedId),
           index != 0
        {
            order.remove(at: index)
            order.insert(selectedId, at: 0)
        }
        return order
    }

    /// Recovers the centered-master order from a tree that already has the expected shape, for
    /// example after a persisted restore or after toggling the setting off and on again.
    private func detectCenteredMasterOrder(root: DwindleNode) -> [DwindleTileId]? {
        if let tile = root.tile {
            return [tile.id]
        }
        guard root.splitOrientation == .horizontal,
              let first = root.firstChild(),
              let second = root.secondChild()
        else { return nil }

        if second.splitOrientation == .horizontal,
           let master = second.firstChild()?.tile,
           let rightNode = second.secondChild(),
           let left = stackChainTileIds(first),
           let right = stackChainTileIds(rightNode)
        {
            return [master.id] + interleaved(right: right, left: left)
        }
        if let master = first.tile, let stacked = second.tile {
            return [master.id, stacked.id]
        }
        return nil
    }

    private func stackChainTileIds(_ node: DwindleNode) -> [DwindleTileId]? {
        if let tile = node.tile {
            return [tile.id]
        }
        guard node.splitOrientation == .vertical,
              let first = node.firstChild()?.tile,
              let second = node.secondChild(),
              let rest = stackChainTileIds(second)
        else { return nil }
        return [first.id] + rest
    }

    private func interleaved(right: [DwindleTileId], left: [DwindleTileId]) -> [DwindleTileId] {
        var result: [DwindleTileId] = []
        result.reserveCapacity(right.count + left.count)
        for index in 0 ..< max(right.count, left.count) {
            if index < right.count { result.append(right[index]) }
            if index < left.count { result.append(left[index]) }
        }
        return result
    }

    private func stackSides(_ order: [DwindleTileId]) -> (left: [DwindleTileId], right: [DwindleTileId]) {
        var left: [DwindleTileId] = []
        var right: [DwindleTileId] = []
        for (offset, id) in order.dropFirst().enumerated() {
            if offset.isMultiple(of: 2) {
                right.append(id)
            } else {
                left.append(id)
            }
        }
        return (left, right)
    }

    // MARK: - Shape check

    private func hasCenteredMasterShape(root: DwindleNode, order: [DwindleTileId]) -> Bool {
        guard let masterId = order.first else {
            return root.isLeaf && root.tile == nil
        }
        let sides = stackSides(order)
        if sides.right.isEmpty {
            return root.tile?.id == masterId
        }
        guard root.splitOrientation == .horizontal,
              let first = root.firstChild(),
              let second = root.secondChild()
        else { return false }
        if sides.left.isEmpty {
            return first.tile?.id == masterId && stackChainMatches(second, sides.right)
        }
        guard stackChainMatches(first, sides.left),
              second.splitOrientation == .horizontal,
              second.firstChild()?.tile?.id == masterId,
              let rightNode = second.secondChild()
        else { return false }
        return stackChainMatches(rightNode, sides.right)
    }

    private func stackChainMatches(_ node: DwindleNode, _ tiles: [DwindleTileId]) -> Bool {
        guard let first = tiles.first else { return false }
        if tiles.count == 1 {
            return node.tile?.id == first
        }
        guard node.splitOrientation == .vertical,
              let firstChild = node.firstChild(),
              let secondChild = node.secondChild()
        else { return false }
        return firstChild.tile?.id == first && stackChainMatches(secondChild, Array(tiles.dropFirst()))
    }

    // MARK: - Rebuild

    private func rebuildCenteredMasterTree(
        state: DwindleWorkspaceState,
        leavesById: [DwindleTileId: DwindleNode],
        masterRatio: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        let order = state.masterOrder.filter { leavesById[$0] != nil }
        guard let masterId = order.first else { return }
        let root = state.root

        if interactiveResize?.workspaceId == workspaceId {
            clearInteractiveResize()
        }
        if interactiveMove?.workspaceId == workspaceId {
            interactiveMoveCancel()
        }

        let previousSelection = state.selectedNodeId
        let detached = detachLeaves(order: order, leavesById: leavesById, root: root)
        guard let masterLeaf = detached.leaves[masterId] else { return }

        for child in root.children {
            child.parent = nil
        }
        root.children.removeAll()
        root.clearAnimations()

        let sides = stackSides(order)
        if sides.right.isEmpty {
            root.kind = .leaf(tile: masterLeaf.tile)
            root.cachedFrame = masterLeaf.cachedFrame
            root.cachedContentFrame = masterLeaf.cachedContentFrame
            root.frameAnimation = masterLeaf.frameAnimation
            if previousSelection == masterLeaf.id {
                state.selectedNodeId = root.id
            }
        } else {
            root.cachedContentFrame = nil
            attachCenteredMasterChildren(
                to: root,
                masterLeaf: masterLeaf,
                sides: sides,
                leaves: detached.leaves,
                masterRatio: masterRatio
            )
            if let rootReplacement = detached.rootReplacement, previousSelection == root.id {
                state.selectedNodeId = rootReplacement.id
            }
        }

        reindexLeaves(state: state)
        if selectedNode(in: workspaceId) == nil {
            state.selectedNodeId = root.tile != nil ? root.id : masterLeaf.id
        }
    }

    /// Materializes a detached leaf for every tile before the root is touched, because the root
    /// itself may currently be the leaf that holds a tile. Existing leaves are reused so their
    /// cached frames keep feeding the movement animations.
    private func detachLeaves(
        order: [DwindleTileId],
        leavesById: [DwindleTileId: DwindleNode],
        root: DwindleNode
    ) -> (leaves: [DwindleTileId: DwindleNode], rootReplacement: DwindleNode?) {
        var leaves: [DwindleTileId: DwindleNode] = [:]
        var rootReplacement: DwindleNode?
        for id in order {
            guard let node = leavesById[id] else { continue }
            if node === root {
                let fresh = DwindleNode(kind: .leaf(tile: node.tile))
                fresh.cachedFrame = node.cachedFrame
                fresh.cachedContentFrame = node.cachedContentFrame
                fresh.frameAnimation = node.frameAnimation
                leaves[id] = fresh
                rootReplacement = fresh
            } else {
                node.detach()
                leaves[id] = node
            }
        }
        return (leaves, rootReplacement)
    }

    private func attachCenteredMasterChildren(
        to root: DwindleNode,
        masterLeaf: DwindleNode,
        sides: (left: [DwindleTileId], right: [DwindleTileId]),
        leaves: [DwindleTileId: DwindleNode],
        masterRatio: CGFloat
    ) {
        let rightChain = makeStackChain(sides.right.compactMap { leaves[$0] })
        if sides.left.isEmpty {
            root.kind = .split(orientation: .horizontal, ratio: settings.clampedRatio(2 * masterRatio))
            root.replaceChildren(first: masterLeaf, second: rightChain)
            return
        }
        let leftChain = makeStackChain(sides.left.compactMap { leaves[$0] })
        let inner = DwindleNode(kind: .split(orientation: .horizontal, ratio: innerSplitRatio(masterRatio)))
        inner.replaceChildren(first: masterLeaf, second: rightChain)
        root.kind = .split(orientation: .horizontal, ratio: rootSplitRatio(masterRatio))
        root.replaceChildren(first: leftChain, second: inner)
    }

    private func makeStackChain(_ leaves: [DwindleNode]) -> DwindleNode {
        guard leaves.count > 1 else {
            return leaves[0]
        }
        let split = DwindleNode(kind: .split(
            orientation: .vertical,
            ratio: settings.clampedRatio(2.0 / CGFloat(leaves.count))
        ))
        split.replaceChildren(first: leaves[0], second: makeStackChain(Array(leaves.dropFirst())))
        return split
    }

    private func applyCenteredMasterRatios(root: DwindleNode, tileCount: Int, masterRatio: CGFloat) {
        guard tileCount >= 2, case let .split(orientation, _) = root.kind else { return }
        if tileCount == 2 {
            root.kind = .split(orientation: orientation, ratio: settings.clampedRatio(2 * masterRatio))
            return
        }
        root.kind = .split(orientation: orientation, ratio: rootSplitRatio(masterRatio))
        if let inner = root.secondChild(), case let .split(innerOrientation, _) = inner.kind {
            inner.kind = .split(orientation: innerOrientation, ratio: innerSplitRatio(masterRatio))
        }
    }

    /// Ratio of the root split: the left stack takes half of what the master leaves over.
    private func rootSplitRatio(_ masterRatio: CGFloat) -> CGFloat {
        settings.clampedRatio(1 - masterRatio)
    }

    /// Ratio of the inner split so that the master ends up with `masterRatio` of the full width.
    private func innerSplitRatio(_ masterRatio: CGFloat) -> CGFloat {
        settings.clampedRatio(4 * masterRatio / (1 + masterRatio))
    }

    private func leafNodesByTileId(in state: DwindleWorkspaceState) -> [DwindleTileId: DwindleNode] {
        var result: [DwindleTileId: DwindleNode] = [:]
        for leaf in state.root.collectAllLeaves() {
            if let tile = leaf.tile {
                result[tile.id] = leaf
            }
        }
        return result
    }

    private func reindexLeaves(state: DwindleWorkspaceState) {
        state.leafByToken.removeAll(keepingCapacity: true)
        var tileCount = 0
        for leaf in state.root.collectAllLeaves() {
            guard let tile = leaf.tile else { continue }
            tileCount += 1
            for member in tile.members {
                state.leafByToken[member.token] = leaf
            }
        }
        state.tileCount = tileCount
    }
}
