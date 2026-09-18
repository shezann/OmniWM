// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct WorkspaceLabelEditRequest {
    let workspaceId: WorkspaceDescriptor.ID
    let currentName: String
    /// The label's frame in screen coordinates; the editor is centred on it.
    let anchorFrame: CGRect
    let barLevel: NSWindow.Level
    let accentColor: Color?
    let textColor: Color?
}

@MainActor @Observable
final class WorkspaceLabelEditorModel {
    var text = ""
    var accentColor: Color?
    var textColor: Color?
}

/// Inline editor for a workspace's ID, opened by double-clicking a label in the workspace bar.
///
/// The bar panel never becomes key, so the editor lives in its own small non-activating panel
/// floating over the label, like the command palette: it takes keyboard focus without activating
/// OmniWM and hands focus back to the previously frontmost app when it closes. Enter commits,
/// Escape or a click anywhere else cancels, and a rejected ID (invalid or already taken) keeps the
/// editor open and beeps.
@MainActor
final class WorkspaceLabelEditorController {
    private static let minimumWidth: CGFloat = 40
    private static let horizontalPadding: CGFloat = 24
    private static let verticalPadding: CGFloat = 8

    private(set) var panel: NonactivatingPanel?
    private let model = WorkspaceLabelEditorModel()
    private let dismissalMonitor = PanelDismissalMonitor()
    private var previousApp: NSRunningApplication?
    private var onCommit: ((String) -> Bool)?

    var isEditing: Bool {
        panel != nil
    }

    static func frame(anchoredTo anchor: CGRect) -> CGRect {
        let size = CGSize(
            width: max(minimumWidth, anchor.width + horizontalPadding),
            height: max(20, anchor.height + verticalPadding)
        )
        return CGRect(
            x: anchor.midX - size.width / 2,
            y: anchor.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    func begin(_ request: WorkspaceLabelEditRequest, onCommit: @escaping (String) -> Bool) {
        dismiss()
        previousApp = NSWorkspace.shared.frontmostApplication
        self.onCommit = onCommit
        model.text = request.currentName
        model.accentColor = request.accentColor
        model.textColor = request.textColor

        let frame = Self.frame(anchoredTo: request.anchorFrame)
        let panel = NonactivatingPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: request.barLevel.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.appearance = NSApplication.shared.appearance

        let hostingView = NSHostingView(
            rootView: WorkspaceLabelEditorView(
                model: model,
                onSubmit: { [weak self] in self?.submit() },
                onCancel: { [weak self] in self?.dismiss() }
            )
        )
        hostingView.appearance = panel.appearance
        panel.contentView = hostingView
        panel.setFrame(frame, display: true)
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
        dismissalMonitor.start(
            panels: [panel],
            isExemptWindow: { _ in false },
            onEscape: { [weak self] in self?.dismiss() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        DispatchQueue.main.async { [weak panel] in
            (panel?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    func submit() {
        guard let onCommit else { return }
        if onCommit(model.text) {
            dismiss()
        } else {
            NSSound.beep()
            (panel?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    func dismiss() {
        dismissalMonitor.stop()
        onCommit = nil
        guard let panel else {
            previousApp = nil
            return
        }
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil

        // Ordering out the key panel gives keyboard focus back to the frontmost app; re-activating
        // that app covers the case where the window server did not do it on its own.
        if let previousApp,
           !previousApp.isTerminated,
           previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            previousApp.activate()
        }
        previousApp = nil
    }
}

private struct WorkspaceLabelEditorView: View {
    @Bindable var model: WorkspaceLabelEditorModel
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        TextField("", text: $model.text)
            .textFieldStyle(.plain)
            .font(WorkspaceBarLabelStyle.font)
            .multilineTextAlignment(.center)
            .foregroundStyle(model.textColor ?? .primary)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .onExitCommand(perform: onCancel)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                shape
                    .fill(.regularMaterial)
                    .overlay {
                        shape.strokeBorder(model.accentColor ?? .accentColor, lineWidth: 1)
                    }
            }
            .onAppear {
                isFocused = true
            }
            .accessibilityLabel("Workspace ID")
    }
}
