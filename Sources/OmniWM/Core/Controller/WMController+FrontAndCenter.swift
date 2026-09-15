// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension WMController {
    /// The window a Front and Center request acts on.
    struct FrontAndCenterTarget: Equatable {
        let pid: pid_t
        let axRef: AXWindowRef
    }

    /// How a managed window looked before it was brought front and center, so a second press can put
    /// it back. Recorded once per window and kept until the window is put back or re-tiled by hand.
    struct FrontAndCenterRestoreState: Equatable {
        let previousMode: TrackedWindowMode
        let previousFloatingState: FloatingState?
        let previousManualOverride: ManualWindowOverride?
    }

    /// The same for a window driven through raw Accessibility (paused, or not tracked by OmniWM).
    struct FrontAndCenterUnmanagedRecord: Equatable {
        let previousFrame: CGRect
        let centeredFrame: CGRect
    }

    /// Brings the frontmost app's focused window back in front of the user: floats it, sizes it to
    /// the configured share of the current monitor, centers it there, then focuses and raises it.
    /// Windows parked for an inactive workspace, tucked into a scratchpad, minimized, hidden with
    /// the app, or living on another monitor are all pulled back. Pressing again on a window that is
    /// still where the first press left it puts it back: a tiled window rejoins the layout of the
    /// workspace it is on now, a floating window returns to its previous spot. While window
    /// management is paused (or the window is one OmniWM does not track) the Accessibility API is
    /// driven directly, the second press restores the previous frame, and the remembered layout
    /// still wins when management resumes.
    @discardableResult
    func bringFocusedWindowFrontAndCenter() -> ExternalCommandResult {
        guard !isLockScreenActive else { return .ignoredDisabled }
        guard let target = frontAndCenterTarget() else { return .notFound }
        return bringWindowFrontAndCenter(target)
    }

    /// The frontmost app's focused window, falling back to the selected managed window when OmniWM
    /// itself is frontmost or the app exposes no focused window.
    func frontAndCenterTarget() -> FrontAndCenterTarget? {
        let frontmostPid = commandHandler.frontmostAppPidProvider?()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let frontmostPid, frontmostPid != ProcessInfo.processInfo.processIdentifier {
            if let token = commandHandler.frontmostFocusedWindowTokenProvider?(),
               let entry = workspaceManager.entry(for: token)
            {
                return FrontAndCenterTarget(pid: entry.pid, axRef: entry.axRef)
            }
            if let axRef = frontAndCenterFocusedWindowResolver(frontmostPid) {
                let entry = workspaceManager.entry(forWindowId: axRef.windowId)
                return FrontAndCenterTarget(pid: entry?.pid ?? frontmostPid, axRef: entry?.axRef ?? axRef)
            }
        }
        if let token = workspaceManager.selectedManagedToken,
           let entry = workspaceManager.entry(for: token)
        {
            return FrontAndCenterTarget(pid: entry.pid, axRef: entry.axRef)
        }
        return nil
    }

    /// The monitor the user is working on: the one under the pointer, falling back to the interaction
    /// monitor. Activating a lost window can already have moved the interaction monitor to wherever
    /// that window sits, so the pointer is the more trustworthy "where I am" signal; the target
    /// window's own monitor is deliberately never used.
    func frontAndCenterMonitor() -> Monitor? {
        let monitors = workspaceManager.monitors.isEmpty ? Monitor.current() : workspaceManager.monitors
        if let monitor = currentMouseLocation().monitorApproximation(in: monitors) {
            return monitor
        }
        if let monitorId = workspaceManager.interactionMonitorId,
           let monitor = monitors.first(where: { $0.id == monitorId })
        {
            return monitor
        }
        return monitors.first
    }

    @discardableResult
    func bringWindowFrontAndCenter(
        _ target: FrontAndCenterTarget,
        retryAfterUnhide: Bool = true,
        allowRestore: Bool = true
    ) -> ExternalCommandResult {
        guard let monitor = frontAndCenterMonitor() else { return .notFound }
        let frame = FrontAndCenterSettings.frame(
            in: monitor.visibleFrame,
            sizeRatio: settings.resolvedFrontAndCenterSizeRatio(for: monitor)
        )
        pruneFrontAndCenterRestoreStates()

        guard isEnabled, hasStartedServices,
              let entry = workspaceManager.entry(forWindowId: target.axRef.windowId)
        else {
            return frontAndCenterUnmanagedWindow(target, frame: frame)
        }
        frontAndCenterUnmanagedRecords.removeValue(forKey: entry.windowId)

        if workspaceManager.isAppHidden(pid: entry.pid) {
            // Cmd+H hides the whole app; macOS reports the unhide asynchronously and every managed
            // path refuses hidden apps until then, so unhide first and come back once. That retry
            // must bring the window forward, never put it back.
            NSRunningApplication(processIdentifier: entry.pid)?.unhide()
            if retryAfterUnhide {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.bringWindowFrontAndCenter(target, retryAfterUnhide: false, allowRestore: false)
                }
                return .executed
            }
        }
        if allowRestore,
           let state = frontAndCenterRestoreStates[entry.token],
           isRestorableFromFrontAndCenter(entry)
        {
            return restoreFromFrontAndCenter(entry, state: state)
        }
        return frontAndCenterManagedWindow(entry, monitor: monitor, frame: frame)
    }

    /// A second press only puts a window back while it is still where the first press left it:
    /// floating, visible, and on a workspace the user can see. A window that went missing again is
    /// simply brought back once more.
    private func isRestorableFromFrontAndCenter(_ entry: WindowState) -> Bool {
        entry.mode == .floating
            && workspaceManager.hiddenState(for: entry.token) == nil
            && workspaceManager.visibleWorkspaceIds().contains(entry.workspaceId)
            && !workspaceManager.isAppHidden(pid: entry.pid)
    }

    /// Drops records for windows that are gone or that the user has tiled again by other means.
    private func pruneFrontAndCenterRestoreStates() {
        frontAndCenterRestoreStates = frontAndCenterRestoreStates.filter { token, _ in
            workspaceManager.entry(for: token)?.mode == .floating
        }
    }

    private func frontAndCenterManagedWindow(
        _ entry: WindowState,
        monitor: Monitor,
        frame: CGRect
    ) -> ExternalCommandResult {
        let token = entry.token
        guard !isManagedWindowSuspendedForNativeFullscreen(token) else { return .windowActionFailed }
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [entry.workspaceId]
        rememberFrontAndCenterRestoreState(for: entry)
        revealForFrontAndCenter(entry)

        // Float it so no layout engine claims the space back.
        if workspaceManager.windowMode(for: token) == .tiling {
            workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
            _ = transitionWindowMode(
                for: token,
                to: .floating,
                preferredMonitor: monitor,
                applyFloatingFrame: false,
                observedFrame: frame,
                allowLiveFrameFallback: false
            )
        }

        // Bring it to the workspace the user is looking at.
        if let targetWorkspace = workspaceManager.activeWorkspace(on: monitor.id)
            ?? workspaceManager.activeWorkspaceOrFirst(on: monitor.id),
            workspaceManager.workspace(for: token) != targetWorkspace.id,
            case let .changed(mutation) = workspaceNavigationHandler.moveWindow(
                handle: WindowHandle(id: token),
                toWorkspaceId: targetWorkspace.id
            )
        {
            affectedWorkspaceIds.formUnion(mutation.affectedWorkspaceIds)
        }
        if let workspaceId = workspaceManager.workspace(for: token) {
            affectedWorkspaceIds.insert(workspaceId)
        }

        Self.unminimize(entry.axRef)
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: monitor,
            restoreToFloating: true
        )
        axManager.forceApplyNextFrame(for: entry.windowId)
        axManager.applyFramesParallel([.init(pid: entry.pid, window: entry.axRef, frame: frame)])

        layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: affectedWorkspaceIds)
        focusWindow(token, origin: .keyboardOrProgrammatic, raisesWindow: true)
        performWindowOrdering(windowId: entry.windowId)
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: "frontAndCenter.managed windowId=\(entry.windowId) monitor=\(monitor.displayId)"
        )
        return .executed
    }

    /// Puts a window back the way the first press found it. A previously tiled window rejoins the
    /// layout of the workspace it is on now, not the one it was lost on; a previously floating window
    /// returns to its old spot, mapped onto its current monitor.
    private func restoreFromFrontAndCenter(
        _ entry: WindowState,
        state: FrontAndCenterRestoreState
    ) -> ExternalCommandResult {
        let token = entry.token
        frontAndCenterRestoreStates.removeValue(forKey: token)
        workspaceManager.setManualLayoutOverride(state.previousManualOverride, for: token)

        switch state.previousMode {
        case .tiling:
            _ = transitionWindowMode(for: token, to: .tiling)
        case .floating:
            let monitor = workspaceManager.monitor(for: entry.workspaceId)
            if let previousFloatingState = state.previousFloatingState {
                workspaceManager.setFloatingState(previousFloatingState, for: token)
            }
            if let restoredFrame = workspaceManager.resolvedFloatingFrame(for: token, preferredMonitor: monitor) {
                workspaceManager.updateFloatingGeometry(
                    frame: restoredFrame,
                    for: token,
                    referenceMonitor: monitor,
                    restoreToFloating: true
                )
                axManager.forceApplyNextFrame(for: entry.windowId)
                axManager.applyFramesParallel([.init(pid: entry.pid, window: entry.axRef, frame: restoredFrame)])
            }
        }

        layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [entry.workspaceId])
        focusWindow(token, origin: .keyboardOrProgrammatic, raisesWindow: true)
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: "frontAndCenter.restored windowId=\(entry.windowId) mode=\(state.previousMode)"
        )
        return .executed
    }

    /// Remembers how the window looked before the first press. Re-centering a window that went missing
    /// again keeps the original record, so the eventual restore still knows the way back.
    private func rememberFrontAndCenterRestoreState(for entry: WindowState) {
        guard frontAndCenterRestoreStates[entry.token] == nil else { return }
        frontAndCenterRestoreStates[entry.token] = FrontAndCenterRestoreState(
            previousMode: entry.mode,
            previousFloatingState: workspaceManager.floatingState(for: entry.token),
            previousManualOverride: workspaceManager.manualLayoutOverride(for: entry.token)
        )
    }

    /// Leaves the scratchpad (a member would be re-hidden on the next toggle) and comes out of hiding,
    /// whether parked off-screen for an inactive workspace or tucked into a corner.
    private func revealForFrontAndCenter(_ entry: WindowState) {
        let token = entry.token
        if workspaceManager.scratchpadIndex(for: token) != nil {
            cleanupScratchpadWindowResources(for: token)
            _ = workspaceManager.setScratchpadMembership(token, to: nil)
        }
        if workspaceManager.hiddenState(for: token) != nil {
            workspaceManager.setHiddenState(nil, for: token)
            axManager.markWindowActive(entry.windowId)
            axManager.unsuppressFrameWrites([(entry.pid, entry.windowId)])
        }
    }

    private func frontAndCenterUnmanagedWindow(
        _ target: FrontAndCenterTarget,
        frame: CGRect
    ) -> ExternalCommandResult {
        let windowId = target.axRef.windowId
        if let app = NSRunningApplication(processIdentifier: target.pid), app.isHidden {
            app.unhide()
        }
        Self.unminimize(target.axRef)

        let currentFrame = try? AXWindowService.frame(target.axRef)
        let record = frontAndCenterUnmanagedRecords[windowId]
        // A second press on a window still sitting where we centered it puts it back. If the window
        // has moved on since, it is centered again and the original spot stays remembered.
        if let record, let currentFrame, Self.isCentered(currentFrame, at: record.centeredFrame) {
            frontAndCenterUnmanagedRecords.removeValue(forKey: windowId)
            return frontAndCenterApplyUnmanaged(target, frame: record.previousFrame, label: "restored")
        }
        let result = frontAndCenterApplyUnmanaged(target, frame: frame, label: "unmanaged")
        if result == .executed, let previousFrame = record?.previousFrame ?? currentFrame {
            frontAndCenterUnmanagedRecords[windowId] = FrontAndCenterUnmanagedRecord(
                previousFrame: previousFrame,
                centeredFrame: frame
            )
        }
        return result
    }

    private func frontAndCenterApplyUnmanaged(
        _ target: FrontAndCenterTarget,
        frame: CGRect,
        label: String
    ) -> ExternalCommandResult {
        let write = AXWindowService.setFrame(target.axRef, frame: frame, verify: false)
        windowFocusOperations.activateApp(target.pid)
        windowFocusOperations.focusSpecificWindow(target.pid, UInt32(target.axRef.windowId), target.axRef.element)
        windowFocusOperations.raiseWindow(target.axRef.element)
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: "frontAndCenter.\(label) windowId=\(target.axRef.windowId) "
                + "frameWrite=\(write.failureReason.map { "\($0)" } ?? "ok")"
        )
        return write.failureReason == nil ? .executed : .windowActionFailed
    }

    /// Apps may clamp the size we asked for, so "still centered" compares centers, not full frames.
    nonisolated static func isCentered(_ frame: CGRect, at centeredFrame: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(frame.midX - centeredFrame.midX) <= tolerance && abs(frame.midY - centeredFrame.midY) <= tolerance
    }

    private static func unminimize(_ axRef: AXWindowRef) {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(axRef.element, kAXMinimizedAttribute as CFString, &value) == .success,
              let minimized = value as? Bool, minimized
        else { return }
        AXUIElementSetAttributeValue(axRef.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    /// Live Accessibility lookup of the window an app currently considers focused. Falls back to the
    /// main window and finally the first listed window, which is where a minimized-only app ends up.
    nonisolated static func liveFocusedAXWindow(pid: pid_t) -> AXWindowRef? {
        let app = AXUIElementCreateApplication(pid)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { continue }
            if let axRef = try? AXWindowRef(element: unsafeDowncast(value, to: AXUIElement.self)) {
                return axRef
            }
        }
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let elements = windowsValue as? [AXUIElement]
        else { return nil }
        return elements.lazy.compactMap { try? AXWindowRef(element: $0) }.first
    }
}
