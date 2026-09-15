// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

extension WMController {
    /// Brings every window parked off-screen for an inactive workspace back onto its monitor before
    /// services stop, so a paused OmniWM leaves the desktop looking like plain macOS. Windows on
    /// visible workspaces already sit where the layout put them and are left alone. Scratchpad
    /// windows stay hidden, matching how macOS treats a window the user tucked away on purpose.
    func releaseManagedWindowsForPause() {
        guard !isLockScreenActive else { return }

        var frameUpdates: [AXFrameApplicationTarget] = []
        var revealedJobs: [(pid: pid_t, windowId: Int)] = []

        for entry in workspaceManager.allEntries() {
            guard let hiddenState = entry.hiddenState, hiddenState.workspaceInactive else { continue }
            let referenceMonitor = hiddenState.referenceMonitorId.flatMap { workspaceManager.monitor(byId: $0) }
            guard let monitor = workspaceManager.monitor(for: entry.workspaceId)
                ?? referenceMonitor
                ?? workspaceManager.monitors.first
            else { continue }
            guard let plan = layoutRefreshController.makeRestorePositionPlan(
                for: entry,
                monitor: monitor,
                hiddenState: hiddenState
            ) else { continue }

            workspaceManager.setHiddenState(nil, for: entry.token)
            axManager.markWindowActive(entry.windowId)
            axManager.forceApplyNextFrame(for: entry.windowId)
            revealedJobs.append((entry.pid, entry.windowId))
            frameUpdates.append(
                AXFrameApplicationTarget(pid: entry.pid, window: entry.axRef, frame: plan.frame)
            )
        }

        guard !frameUpdates.isEmpty else { return }
        axManager.unsuppressFrameWrites(revealedJobs)
        axManager.applyFramesParallel(frameUpdates)
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: "windowManagement.releasedParkedWindows count=\(frameUpdates.count)"
        )
    }
}
