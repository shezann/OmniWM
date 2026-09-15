// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import os
import QuartzCore

/// Owns presentation only. Workspace selection and hidden/floating state remain unchanged
/// until the spring reaches its destination. The AX mailbox coalesces position updates
/// while ordinary layout and parking writes are excluded from these windows.
@MainActor
final class WorkspaceSlideController {
    private static let logger = Logger(subsystem: "com.barut.OmniWM", category: "WorkspaceSlide")
    struct Window {
        let entry: WindowState
        let originalFrame: CGRect
        let frame: CGRect
    }

    struct Session {
        let monitor: Monitor
        let source: WorkspaceDescriptor.ID
        let previous: WorkspaceDescriptor.ID?
        let next: WorkspaceDescriptor.ID?
        let axis: WorkspaceSwipeAxis
        let naturalDirection: Bool
        let triggerDistance: CGFloat
        let windows: [Window]
        var progress: CGFloat = 0
        var spring: SpringAnimation?

        var workspaceIds: Set<WorkspaceDescriptor.ID> {
            Set([source, previous, next].compactMap { $0 })
        }

        var landingWorkspace: WorkspaceDescriptor.ID? {
            guard let target = spring?.target, target != 0 else { return nil }
            return target > 0 ? next : previous
        }
    }

    private weak var controller: WMController?
    private(set) var session: Session?
    // Tests drive presentation without moving real application windows or starting a display link.
    var presentForTests: (([(WindowToken, CGRect)], CGRect?) -> Bool)?
    var frameProvider: (WindowState) -> CGRect? = { AXWindowService.framePreferFast($0.axRef) }
    var now: () -> TimeInterval = { CACurrentMediaTime() }

    init(controller: WMController) {
        self.controller = controller
    }

    var isActive: Bool {
        session != nil
    }

    func owns(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        session?.workspaceIds.contains(workspaceId) == true
    }

    func owns(windowId: Int) -> Bool {
        session?.windows.contains { $0.entry.windowId == windowId } == true
    }

    func hasDisplayLinkWork(_ displayId: CGDirectDisplayID) -> Bool {
        session?.monitor.displayId == displayId
    }

    @discardableResult
    func begin(
        source: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID,
        axis: WorkspaceSwipeAxis,
        naturalDirection: Bool,
        triggerDistance: CGFloat
    ) -> Bool {
        cancel()
        guard let controller, !controller.isWindowManagementPaused, !controller.isLockScreenActive,
              !controller.isOverviewOpen(), triggerDistance.isFinite, triggerDistance > 0,
              let monitor = controller.workspaceManager.monitor(byId: monitorId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitorId)?.id == source,
              !controller.workspaceManager.hasPendingNativeFullscreenTransition(in: source)
        else {
            Self.logger.notice("Slide unavailable: context")
            return false
        }
        let manager = controller.workspaceManager
        let previous = manager.previousWorkspaceInOrder(on: monitorId, from: source, wrapAround: true)?.id
        let next = manager.nextWorkspaceInOrder(on: monitorId, from: source, wrapAround: true)?.id
        let workspaceIds = Set([source, previous, next].compactMap { $0 })
        guard workspaceIds.count > 1,
              workspaceIds.allSatisfy({ !manager.hasPendingNativeFullscreenTransition(in: $0) })
        else {
            Self.logger.notice("Slide unavailable: neighbor or fullscreen transition")
            return false
        }

        controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
        controller.layoutRefreshController.stopDwindleAnimation(for: monitor.displayId)
        for workspaceId in workspaceIds {
            controller.niriLayoutHandler.cancelActiveAnimations(for: workspaceId)
            controller.dwindleEngine?.cancelAnimations(in: workspaceId)
        }

        let windows = captureWindows(in: workspaceIds, source: source, monitor: monitor, controller: controller)
        // Planning can seed layout animations; none may run alongside the slide.
        for workspaceId in workspaceIds {
            controller.niriLayoutHandler.cancelActiveAnimations(for: workspaceId)
            controller.dwindleEngine?.cancelAnimations(in: workspaceId)
        }
        guard let windows else { return false }
        session = Session(
            monitor: monitor,
            source: source,
            previous: previous == source ? nil : previous,
            next: next == source ? nil : next,
            axis: axis,
            naturalDirection: naturalDirection,
            triggerDistance: triggerDistance,
            windows: windows
        )
        let jobs = windows.map { (pid: $0.entry.pid, windowId: $0.entry.windowId) }
        controller.axManager.cancelPendingFrameJobs(jobs, reason: "workspace-slide")
        // Terminal observers may retire a window and cancel this session synchronously.
        guard isActive else { return false }
        controller.axManager.cancelParkFrameJobs(jobs, reason: "workspace-slide")
        controller.axManager.beginWorkspaceSlideFrameWrites(windows.map(\.entry.token))
        guard isActive else { return false }
        controller.surfaceReconciler.noteWorldChanged()
        guard controller.layoutRefreshController.startWorkspaceSlideDisplayLink(for: monitor.displayId) else {
            Self.logger.notice("Slide unavailable: display link")
            cancel()
            return false
        }
        Self.logger.notice("Slide started: windows=\(windows.count) axis=\(axis.rawValue, privacy: .public)")
        return true
    }

    func update(displacement: CGFloat) {
        guard var session, session.spring == nil else { return }
        var progress = WorkspaceSlideGeometry.progress(
            axis: session.axis,
            displacement: displacement,
            naturalDirection: session.naturalDirection,
            triggerDistance: session.triggerDistance
        )
        if (progress > 0 && session.next == nil) || (progress < 0 && session.previous == nil) { progress = 0 }
        session.progress = progress
        self.session = session
        render()
    }

    func release(velocity: Double, cancelled: Bool) {
        guard var session, session.spring == nil else { return }
        let signedVelocity = WorkspaceSlideGeometry.progress(
            axis: session.axis,
            displacement: CGFloat(velocity),
            naturalDirection: session.naturalDirection,
            triggerDistance: 1
        ) * CGFloat(abs(velocity))
        let flick = TrackpadGestureIntent.releaseFlickDisplacement(
            cumulativeAxisUnits: session.progress, velocity: Double(signedVelocity)
        )
        var target = WorkspaceSlideGeometry.landing(progress: session.progress, flick: flick, cancelled: cancelled)
        if (target > 0 && session.next == nil) || (target < 0 && session.previous == nil) { target = 0 }
        session.spring = SpringAnimation(
            from: Double(session.progress),
            to: Double(target),
            initialVelocity: Double(signedVelocity) / Double(2 * session.triggerDistance),
            startTime: now(),
            config: .niriHorizontalViewMovement
        )
        self.session = session
        if controller?.motionPolicy.animationsEnabled == false { finish() }
    }

    func tick(at time: TimeInterval, displayId: CGDirectDisplayID) {
        guard var session, session.monitor.displayId == displayId else { return }
        guard let controller,
              controller.workspaceManager.monitor(byId: session.monitor.id) == session.monitor,
              controller.workspaceManager.activeWorkspaceOrFirst(on: session.monitor.id)?.id == session.source,
              !controller.isLockScreenActive, !controller.isWindowManagementPaused, !controller.isOverviewOpen()
        else {
            cancel()
            return
        }
        if let spring = session.spring {
            if spring.isComplete(at: time) {
                finish()
                return
            }
            session.progress = CGFloat(spring.value(at: time)).clamped(to: -1 ... 1)
            self.session = session
        } else {
            // A stationary hand may produce no touch callbacks. Hold the preview until
            // the input source delivers a release/cancellation or its lifecycle resets.
            return
        }
        render()
    }

    func prepareForNewGesture() {
        if session?.spring != nil { finish() } else { cancel() }
    }

    func cancelInteraction() {
        guard session?.spring == nil else { return }
        cancel()
    }

    func invalidate(workspaceId: WorkspaceDescriptor.ID?) {
        guard let session, workspaceId.map(session.workspaceIds.contains) ?? true else { return }
        Self.logger.notice("Slide invalidated at progress=\(session.progress)")
        cancel()
    }

    func cancel(requestRelayout: Bool = true) {
        end(commit: false, requestRelayout: requestRelayout)
    }

    private func finish() {
        end(commit: true, requestRelayout: true)
    }

    private func currentWindows(_ session: Session) -> [Window] {
        guard let controller else { return [] }
        return session.windows.filter {
            guard let entry = controller.workspaceManager.entry(for: $0.entry.token) else { return false }
            return sameAXWindowIdentity(entry.axRef, $0.entry.axRef)
                && entry.layoutReason == .standard
                && !controller.workspaceManager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId)
        }
    }

    private func render() {
        guard let session else { return }
        let windows = currentWindows(session)
        let positions = windows.map { window -> (WindowToken, CGRect) in
            let workspace = window.entry.workspaceId
            let page: CGFloat
            if workspace == session.source { page = 0 }
            else if session.progress > 0, workspace == session.next { page = 1 }
            else if session.progress < 0, workspace == session.previous { page = -1 }
            else { return (window.entry.token, window.originalFrame) }
            let offset = WorkspaceSlideGeometry.offset(
                axis: session.axis,
                progress: session.progress,
                page: page,
                monitor: session.monitor.frame
            )
            return (window.entry.token, window.frame.offsetBy(dx: offset.x, dy: offset.y))
        }
        guard move(positions, viewport: session.monitor.frame) else {
            cancel()
            return
        }
    }

    private func move(_ positions: [(WindowToken, CGRect)], viewport: CGRect?) -> Bool {
        guard let controller else { return false }
        if let presentForTests {
            guard presentForTests(positions, viewport) else { return false }
        } else {
            let frames = positions.compactMap { token, frame -> AXFrameApplicationTarget? in
                guard let entry = controller.workspaceManager.entry(for: token) else { return nil }
                return .init(pid: entry.pid, window: entry.axRef, frame: frame, components: .position)
            }
            guard frames.count == positions.count,
                  controller.axManager.applyWorkspaceSlidePositions(frames) else { return false }
        }
        return true
    }

    private func end(commit: Bool, requestRelayout: Bool) {
        guard let session, let controller else { return }
        Self.logger
            .notice("Slide ended: commit=\(commit) progress=\(session.progress) windows=\(session.windows.count)")
        self.session = nil // Release ownership before durable state changes and callbacks.
        let tokens = session.windows.map(\.entry.token)
        controller.axManager.cancelPendingFrameJobs(
            tokens.map { ($0.pid, $0.windowId) }, reason: "workspace-slide-ended"
        )
        let windows = currentWindows(session)
        let target = commit ? session.landingWorkspace : nil
        // Do not restore outgoing windows to the screen on a successful landing.
        // Their final slide position stays in place until the parking write reaches AX.
        let descriptor = target.flatMap { controller.workspaceManager.descriptor(for: $0) }
        let canCommit = descriptor != nil
            && controller.workspaceManager.activeWorkspaceOrFirst(on: session.monitor.id)?.id == session.source
        let landed = canCommit && move(
            windows.filter { $0.entry.workspaceId == target }.map { ($0.entry.token, $0.frame) },
            viewport: session.monitor.frame
        )
        if !landed {
            _ = move(windows.map { ($0.entry.token, $0.originalFrame) }, viewport: session.monitor.frame)
        }
        controller.axManager.endWorkspaceSlideFrameWrites(tokens)
        if landed, let descriptor {
            controller.workspaceNavigationHandler.activateWorkspaceInOrder(
                descriptor, from: session.source, on: session.monitor.id
            )
        }
        // AX restores are queued. Preserve pre-gesture geometry for parking metadata.
        controller.layoutRefreshController.hideInactiveWorkspacesSync(
            restoredFrames: Dictionary(uniqueKeysWithValues: windows.map { ($0.entry.token, $0.originalFrame) })
        )
        for window in windows { controller.axManager.forceApplyNextFrame(for: window.entry.windowId) }
        controller.layoutRefreshController.stopWorkspaceSlideDisplayLinkIfIdle(for: session.monitor.displayId)
        controller.surfaceReconciler.noteWorldChanged()
        if requestRelayout {
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .interactiveGesture,
                affectedWorkspaceIds: session.workspaceIds
            )
        }
    }
}

extension WorkspaceSlideController {
    private func captureWindows(
        in workspaceIds: Set<WorkspaceDescriptor.ID>,
        source: WorkspaceDescriptor.ID,
        monitor: Monitor,
        controller: WMController
    ) -> [Window]? {
        let manager = controller.workspaceManager
        var windows: [Window] = []
        for workspaceId in workspaceIds {
            let plans = controller.withRuntimeFrameJobCancellationSuppressed {
                manager.withBatchedLayoutBuild {
                    manager.activeLayoutKind(for: workspaceId) == .niri
                        ? controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
                        : controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [workspaceId])
                }
            }
            var frames = Dictionary(
                plans.flatMap(\.diff.frameChanges).map { ($0.token, $0.frame) },
                uniquingKeysWith: { _, last in last }
            )
            for entry in manager.floatingEntries(in: workspaceId) {
                frames[entry.token] = manager.resolvedFloatingFrame(for: entry.token, preferredMonitor: monitor)
            }
            for entry in manager.entries(in: workspaceId) {
                guard entry.layoutReason == .standard,
                      entry.hiddenState?.isScratchpad != true,
                      !manager.isAppHidden(pid: entry.pid),
                      !controller.axManager.macOSHiddenAppPIDs.contains(entry.pid),
                      !manager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId),
                      let layoutFrame = frames[entry.token],
                      !layoutFrame.isNull, !layoutFrame.isInfinite, layoutFrame.width > 0, layoutFrame.height > 0
                else { continue }
                let original = frameProvider(entry)
                    ?? controller.axManager.verifiedParkFrame(for: entry.windowId)
                // A partial preview strands unreadable windows on screen. Reject it before taking
                // ownership so the gesture can use the ordinary release-time switch instead.
                // Cached observations may predate parking and cannot safely restore a hidden window.
                guard let original, !original.isNull, !original.isInfinite,
                      original.width > 0, original.height > 0
                else {
                    Self.logger.notice("Slide unavailable: unreadable window=\(entry.windowId)")
                    return nil
                }
                // Position-only AX updates preserve backing size. Keep that size during the slide;
                // the accepted layout reconciles any resize after landing (without per-frame AX writes).
                let frame = workspaceId == source ? original : CGRect(
                    x: layoutFrame.minX, y: layoutFrame.maxY - original.height,
                    width: original.width, height: original.height
                )
                windows.append(Window(entry: entry, originalFrame: original, frame: frame))
            }
        }
        return windows
    }
}
