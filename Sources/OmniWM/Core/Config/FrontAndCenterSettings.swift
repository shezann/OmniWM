// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

/// Shared knobs for the "Bring Focused Window Front and Center" action: the window is floated,
/// sized to a share of the monitor's visible frame on both axes (so it keeps the screen's aspect
/// ratio), and centered there.
enum FrontAndCenterSettings {
    static let defaultSizeRatio = 0.7
    static let sizeRatioRange: ClosedRange<Double> = 0.2 ... 1.0
    static let sizeRatioStep = 0.05

    static func clampedSizeRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return defaultSizeRatio }
        return min(max(ratio, sizeRatioRange.lowerBound), sizeRatioRange.upperBound)
    }

    /// Centered rectangle covering `sizeRatio` of `visibleFrame` on each axis, snapped to whole
    /// points so the AX write lands where we asked.
    static func frame(in visibleFrame: CGRect, sizeRatio: Double) -> CGRect {
        let ratio = CGFloat(clampedSizeRatio(sizeRatio))
        let width = (visibleFrame.width * ratio).rounded(.down)
        let height = (visibleFrame.height * ratio).rounded(.down)
        let originX = (visibleFrame.midX - width / 2).rounded()
        let originY = (visibleFrame.midY - height / 2).rounded()
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}

struct MonitorFrontAndCenterSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?

    var sizeRatio: Double?

    var hasOverrides: Bool {
        sizeRatio != nil
    }

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        sizeRatio: Double? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.sizeRatio = sizeRatio
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayUUID, monitorDisplayId
        case sizeRatio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        sizeRatio = try container.decodeIfPresent(Double.self, forKey: .sizeRatio)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try DisplayUUID.encode(
            monitorDisplayUUID,
            displayId: monitorDisplayId,
            to: &container,
            uuidKey: .monitorDisplayUUID,
            displayIdKey: .monitorDisplayId
        )
        try container.encodeIfPresent(sizeRatio, forKey: .sizeRatio)
    }
}
