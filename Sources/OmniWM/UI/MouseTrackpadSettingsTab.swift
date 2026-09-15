// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct MouseTrackpadSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var missionControlGestureProbe: MissionControlGestureProbe

    init(
        settings: SettingsStore,
        controller: WMController,
        missionControlGestureProbe: MissionControlGestureProbe = MissionControlGestureProbe()
    ) {
        self.settings = settings
        self.controller = controller
        _missionControlGestureProbe = State(initialValue: missionControlGestureProbe)
    }

    var body: some View {
        Form {
            niriColumnScrollingSection
            workspaceSwipeSection
            trackpadDirectionSection
            mouseMoveAndResizeSection
            focusFollowsMouseSection
        }
        .formStyle(.grouped)
        .onAppear(perform: missionControlGestureProbe.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            missionControlGestureProbe.refresh()
        }
    }

    private var niriColumnScrollingSection: some View {
        Section("Niri Column Scrolling") {
            Toggle("Enable Column Scrolling", isOn: $settings.scrollGestureEnabled)

            SettingsSliderRow(
                label: "Scroll Sensitivity",
                value: $settings.scrollSensitivity,
                range: 0.1 ... 100.0,
                step: 0.1,
                valueText: String(format: "%.1f", settings.scrollSensitivity) + "x"
            )
            .disabled(!settings.scrollGestureEnabled)

            Picker("Trackpad Gesture Fingers", selection: $settings.gestureFingerCount) {
                ForEach(GestureFingerCount.allCases, id: \.self) { count in
                    Text(count.displayName).tag(count)
                }
            }
            .disabled(!settings.scrollGestureEnabled)

            Picker("Trackpad Scroll Style", selection: $settings.trackpadScrollStyle) {
                ForEach(TrackpadScrollStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .disabled(!settings.scrollGestureEnabled)

            SettingsCaption(settings.trackpadScrollStyle == .momentum
                ? "Free inertial scrolling with rubber-band edges"
                : "Scroll snaps to the nearest column")

            Picker("Mouse Scroll Modifier", selection: $settings.scrollModifierKey) {
                ForEach(ScrollModifierKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .disabled(!settings.scrollGestureEnabled)

            SettingsCaption("Hold this key + scroll wheel to scroll through columns")
        }
    }

    private var workspaceSwipeSection: some View {
        Section("Workspace Swipe") {
            Toggle("Enable Workspace Swipe", isOn: $settings.workspaceSwipeEnabled)

            SettingsCaption("Swipe to switch workspaces on the monitor under the cursor")

            Picker("Swipe Fingers", selection: $settings.workspaceSwipeFingerCount) {
                ForEach(GestureFingerCount.allCases, id: \.self) { count in
                    Text(count.displayName).tag(count)
                }
            }
            .disabled(!settings.workspaceSwipeEnabled)
            .accessibilityHint(workspaceSwipeFingerPickerHint)

            if showTwoFingerWorkspaceSwipeWarning {
                SettingsCaption(twoFingerWorkspaceSwipeWarning)
            }

            Picker("Swipe Axis", selection: workspaceSwipeAxisSelection) {
                ForEach(WorkspaceSwipeAxis.allCases) { axis in
                    Text(axis.displayName).tag(axis)
                }
            }
            .disabled(!settings.workspaceSwipeEnabled || settings.workspaceSwipeAxisLockedToVertical)

            Toggle("Invert Direction (Natural)", isOn: $settings.workspaceSwipeInvertDirection)
                .disabled(!settings.workspaceSwipeEnabled)

            SettingsCaption(workspaceSwipeCaption)

            SettingsSliderRow(
                label: "Swipe Distance",
                value: $settings.workspaceSwipeDistance,
                range: SettingsStore.workspaceSwipeDistanceRange,
                step: 0.01,
                valueText: "\(Int((settings.workspaceSwipeDistance * 100).rounded()))%"
            )
            .disabled(!settings.workspaceSwipeEnabled)

            SettingsCaption(
                "How far across the trackpad the fingers travel before the workspace switches. A quick flick switches sooner."
            )

            Toggle("Turn Off Conflicting macOS Gesture", isOn: $settings.workspaceSwipeDisablesSystemGesture)
                .disabled(!settings.workspaceSwipeEnabled)

            SettingsCaption(systemGestureCaption)

            if !settings.workspaceSwipeDisablesSystemGesture,
               missionControlGestureProbe.shouldWarn(
                   axis: settings.effectiveWorkspaceSwipeAxis,
                   fingerCount: settings.workspaceSwipeFingerCount
               )
            {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("\(conflictingSystemGestureName) gesture conflict")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    Text(systemGestureConflictWarning)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Trackpad Settings", action: missionControlGestureProbe.openTrackpadSettings)
                        .controlSize(.small)
                        .accessibilityHint(
                            "Opens System Settings. Select More Gestures, then turn off \(conflictingSystemGestureName)."
                        )
                }
            }
        }
    }

    private var trackpadDirectionSection: some View {
        Section("Trackpad Direction") {
            Toggle("Invert Direction (Natural)", isOn: $settings.gestureInvertDirection)
                .disabled(!settings.scrollGestureEnabled)

            SettingsCaption(settings.gestureInvertDirection
                ? "Affects Niri column scrolling only. Swipe right = scroll right."
                : "Affects Niri column scrolling only. Swipe right = scroll left.")
        }
    }

    private var mouseMoveAndResizeSection: some View {
        Section("Mouse Move & Resize") {
            Picker("Left Mouse Move Modifier", selection: $settings.mouseMoveModifierKey) {
                ForEach(MouseMoveModifierKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }

            SettingsCaption(
                "Hold this modifier and left-drag to swap Niri tiled windows. "
                    + "Add Shift to insert instead; choose Off to leave modified drags to apps."
            )

            Picker("Right Mouse Resize Modifier", selection: $settings.mouseResizeModifierKey) {
                ForEach(MouseResizeModifierKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }

            SettingsCaption("Hold this modifier combo + right mouse drag to resize tiled windows")
        }
    }

    private var focusFollowsMouseSection: some View {
        Section("Focus Follows Mouse") {
            Toggle("Enable Focus Follows Mouse", isOn: $settings.focusFollowsMouse)
                .onChange(of: settings.focusFollowsMouse) { _, newValue in
                    controller.setFocusFollowsMouse(newValue)
                }

            Toggle("Raise Window When Focus Follows Mouse", isOn: $settings.raiseOnMouseFocus)
                .disabled(!settings.focusFollowsMouse)

            Picker("Focus Lock Modifier", selection: $settings.focusLockModifier) {
                ForEach(FocusLockModifier.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .disabled(!settings.focusFollowsMouse)

            SettingsCaption("Hold this modifier to move the cursor over other windows without changing focus.")
        }
    }

    private var conflictingSystemGestureGroup: SystemSwipeGestureGroup {
        settings.effectiveWorkspaceSwipeAxis == .horizontal ? .fullScreenAppSwipe : .missionControl
    }

    private var conflictingSystemGestureName: String {
        conflictingSystemGestureGroup.displayName
    }

    private var systemGestureCaption: String {
        guard settings.workspaceSwipeFingerCount != .two else {
            return "Two-finger swipes have no matching macOS gesture to turn off."
        }
        return "While workspace swipe is on, OmniWM turns off \(conflictingSystemGestureName) in macOS"
            + " and turns it back on when workspace swipe is off or OmniWM quits."
    }

    private var systemGestureConflictWarning: String {
        let intercept = switch settings.effectiveWorkspaceSwipeAxis {
        case .vertical:
            "Mission Control’s three- or four-finger upward swipe can intercept vertical workspace swipes."
        case .horizontal:
            "The three- or four-finger swipe between full-screen applications can intercept horizontal"
                + " workspace swipes."
        }
        return intercept + " Turn on “Turn Off Conflicting macOS Gesture” above, or turn off"
            + " \(conflictingSystemGestureName) in System Settings → Trackpad → More Gestures."
    }

    private var workspaceSwipeAxisSelection: Binding<WorkspaceSwipeAxis> {
        Binding(
            get: { settings.effectiveWorkspaceSwipeAxis },
            set: { settings.workspaceSwipeAxis = $0 }
        )
    }

    private var workspaceSwipeCaption: String {
        let natural = settings.workspaceSwipeInvertDirection
        let hint = switch settings.effectiveWorkspaceSwipeAxis {
        case .horizontal:
            natural ? "Swipe left = next workspace, right = previous" : "Swipe right = next workspace, left = previous"
        case .vertical:
            natural ? "Swipe up = next workspace, down = previous" : "Swipe down = next workspace, up = previous"
        }
        let lockHint = settings.workspaceSwipeAxisLockedToVertical
            ? " Vertical is required while column scrolling uses the same finger count."
            : ""
        return hint + "." + lockHint + " Pick a combination not already used by macOS trackpad gestures."
    }

    private var showTwoFingerWorkspaceSwipeWarning: Bool {
        settings.workspaceSwipeEnabled && settings.workspaceSwipeFingerCount == .two
    }

    private var workspaceSwipeFingerPickerHint: String {
        showTwoFingerWorkspaceSwipeWarning ? twoFingerWorkspaceSwipeWarning : ""
    }

    private var twoFingerWorkspaceSwipeWarning: String {
        "Two-finger workspace swipes can intercept normal scrolling in apps."
    }
}
