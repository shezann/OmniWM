// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct DwindleSettings {
    static let splitRatioPresets: [CGFloat] = [0.6, 1.0, 1.4]

    var defaultSplitRatio: CGFloat = 1.0
    var splitWidthMultiplier: CGFloat = 1.0
    var smartSplit: Bool = true
    var resizeStep: CGFloat = 0.1

    var singleWindowFit: SingleWindowFit = .fullScreen

    var innerGap: CGFloat = 8.0

    /// Keeps one master tile in the center of the workspace and stacks every other tile on the
    /// left and right. New tiles alternate sides, starting on the right.
    var centeredMaster: Bool = false

    /// Fraction of the workspace width the master tile takes while `centeredMaster` is on.
    var masterRatio: CGFloat = DwindleSettings.defaultMasterRatio

    static let defaultMasterRatio: CGFloat = 0.5
    static let masterRatioRange: ClosedRange<CGFloat> = 0.2 ... 0.8

    func clampedMasterRatio(_ ratio: CGFloat) -> CGFloat {
        guard ratio.isFinite else { return Self.defaultMasterRatio }
        return min(max(ratio, Self.masterRatioRange.lowerBound), Self.masterRatioRange.upperBound)
    }

    func clampedRatio(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, 0.1), 1.9)
    }

    func ratioToFraction(_ ratio: CGFloat) -> CGFloat {
        let clamped = clampedRatio(ratio)
        return min(max(clamped / 2.0, 0.05), 0.95)
    }
}
