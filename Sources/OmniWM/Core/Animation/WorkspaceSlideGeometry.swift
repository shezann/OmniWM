// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

/// Positive progress always means the next workspace. Coordinates are AppKit coordinates.
enum WorkspaceSlideGeometry {
    static func progress(
        axis: WorkspaceSwipeAxis,
        displacement: CGFloat,
        naturalDirection: Bool,
        triggerDistance: CGFloat
    ) -> CGFloat {
        guard displacement.isFinite, triggerDistance.isFinite, triggerDistance > 0,
              let next = TrackpadGestureIntent.isNextWorkspace(
                  axis: axis, displacement: displacement, naturalDirection: naturalDirection
              ) else { return 0 }
        return min(1, abs(displacement) / (2 * triggerDistance)) * (next ? 1 : -1)
    }

    static func offset(axis: WorkspaceSwipeAxis, progress: CGFloat, page: CGFloat, monitor: CGRect) -> CGPoint {
        switch axis {
        case .horizontal: CGPoint(x: (page - progress) * monitor.width, y: 0)
        case .vertical: CGPoint(x: 0, y: (progress - page) * monitor.height)
        }
    }

    static func landing(progress: CGFloat, flick: CGFloat?, cancelled: Bool) -> CGFloat {
        guard !cancelled else { return 0 }
        if abs(progress) >= 0.5 { return progress > 0 ? 1 : -1 }
        guard let flick, flick != 0 else { return 0 }
        return flick > 0 ? 1 : -1
    }
}
