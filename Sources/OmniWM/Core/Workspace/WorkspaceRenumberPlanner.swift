// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

/// Turns a drag-and-drop reorder of the workspace bar into workspace renames.
///
/// The bar always shows workspaces in ID order (`1 2 3 ... q w e`), and the direct hotkeys address
/// workspaces by ID, so "move this workspace left" means "give it a lower ID". The set of IDs shown
/// in the bar never changes: after a drop, the ID pool is dealt out again by position, so the
/// workspace that lands first gets the lowest ID and the hotkeys keep matching the bar.
enum WorkspaceRenumberPlanner {
    /// `order` is the bar's new left-to-right list of raw workspace names. Returns the renames that
    /// realise it, keyed by old name, with unchanged workspaces left out.
    static func renames(forNewVisualOrder order: [String]) -> [String: String] {
        let pool = order.sorted(by: WorkspaceIDPolicy.sortsBefore)
        var renames: [String: String] = [:]
        for (index, oldName) in order.enumerated() where pool[index] != oldName {
            renames[oldName] = pool[index]
        }
        return renames
    }

    /// Moves `element` so that it ends up at `targetIndex` in the returned list, where the index is
    /// counted over the other elements (0 puts it first, `order.count - 1` puts it last).
    static func moving<Element: Equatable>(
        _ element: Element,
        in order: [Element],
        toIndex targetIndex: Int
    ) -> [Element] {
        var others = order.filter { $0 != element }
        guard others.count < order.count else { return order }
        let clamped = min(max(targetIndex, 0), others.count)
        others.insert(element, at: clamped)
        return others
    }
}
