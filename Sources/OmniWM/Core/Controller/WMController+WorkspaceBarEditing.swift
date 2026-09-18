// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

/// Workspace bar editing: double-click renames a workspace's ID, drag-and-drop renumbers a bar.
///
/// A workspace's ID (`1`-`9`, `q`, `w`, `e`, ...) is what the direct hotkeys address, so both
/// operations are renames. The workspace keeps its windows, layout, display name, home monitor and
/// app rules; only the ID label moves.
extension WMController {
    /// Applies the ID typed into a workspace label. `input` is raw user text; anything that is not a
    /// valid, unused workspace ID is rejected and nothing changes.
    @discardableResult
    func renameWorkspaceFromBar(id workspaceId: WorkspaceDescriptor.ID, to input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newName = WorkspaceIDPolicy.normalizeRawID(trimmed),
              let workspace = workspaceManager.descriptor(for: workspaceId)
        else { return false }
        guard workspace.name != newName else { return true }
        return applyWorkspaceRenames([workspaceId: newName])
    }

    /// Applies a drag-and-drop reorder. `orderedIds` is the new left-to-right order of the workspaces
    /// shown in one bar; the IDs those workspaces already hold are dealt out again by position.
    @discardableResult
    func reorderWorkspacesFromBar(orderedIds: [WorkspaceDescriptor.ID]) -> Bool {
        let names = orderedIds.compactMap { workspaceManager.descriptor(for: $0)?.name }
        guard names.count == orderedIds.count else { return false }
        let renames = WorkspaceRenumberPlanner.renames(forNewVisualOrder: names)
        guard !renames.isEmpty else { return false }

        var newNamesById: [WorkspaceDescriptor.ID: String] = [:]
        for (workspaceId, name) in zip(orderedIds, names) {
            if let newName = renames[name] {
                newNamesById[workspaceId] = newName
            }
        }
        return applyWorkspaceRenames(newNamesById)
    }

    private func applyWorkspaceRenames(_ newNamesById: [WorkspaceDescriptor.ID: String]) -> Bool {
        var oldToNew: [String: String] = [:]
        for (workspaceId, newName) in newNamesById {
            guard let oldName = workspaceManager.descriptor(for: workspaceId)?.name else { return false }
            oldToNew[oldName] = newName
        }
        let targetNames = Set(oldToNew.values)
        guard targetNames.count == oldToNew.count else { return false }
        let untouchedConfigNames = settings.workspaceConfigurations.map(\.name).filter { oldToNew[$0] == nil }
        guard !untouchedConfigNames.contains(where: targetNames.contains) else { return false }

        guard workspaceManager.renameWorkspaces(newNamesById) else { return false }

        var configs = settings.workspaceConfigurations
        for index in configs.indices {
            if let newName = oldToNew[configs[index].name] {
                configs[index].name = newName
            }
        }
        // A workspace created on the fly has no configuration yet; give it one so its new ID
        // survives a restart, pinned to the monitor it lives on.
        for (workspaceId, newName) in newNamesById where !configs.contains(where: { $0.name == newName }) {
            let assignment: MonitorAssignment = workspaceManager.monitorForWorkspace(workspaceId)
                .map { .specificDisplay(OutputId(from: $0)) } ?? .main
            configs.append(WorkspaceConfiguration(name: newName, monitorAssignment: assignment))
        }
        configs.sort { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }
        settings.workspaceConfigurations = configs

        var rulesChanged = false
        for index in settings.appRules.indices {
            guard let assigned = settings.appRules[index].assignToWorkspace,
                  let newName = oldToNew[assigned]
            else { continue }
            settings.appRules[index].assignToWorkspace = newName
            rulesChanged = true
        }

        updateWorkspaceConfig()
        if rulesChanged {
            rebuildAppRulesCache()
        }
        requestWorkspaceBarRefresh()
        return true
    }
}
