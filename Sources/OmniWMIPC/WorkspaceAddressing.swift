// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

public enum WorkspaceIDPolicy {
    /// Letter workspace IDs, in the order they sort after the numeric IDs. They follow the keyboard
    /// row so that `q`, `w`, `e` read left to right in the workspace bar, the same way `1`, `2`, `3` do.
    public static let letterRawIDs: [String] = ["q", "w", "e"]

    private static let letterRank: [String: Int] = Dictionary(
        uniqueKeysWithValues: letterRawIDs.enumerated().map { ($1, $0) }
    )

    public static func normalizeRawID(_ candidate: String) -> String? {
        if let value = Int(candidate), value > 0 {
            let normalized = String(value)
            guard normalized == candidate else { return nil }
            return normalized
        }
        let lowered = candidate.lowercased()
        guard letterRank[lowered] != nil else { return nil }
        return lowered
    }

    public static func isLetterRawID(_ rawID: String) -> Bool {
        letterRank[rawID] != nil
    }

    public static func rawID(from workspaceNumber: Int) -> String? {
        guard workspaceNumber > 0 else { return nil }
        return String(workspaceNumber)
    }

    public static func workspaceNumber(from rawID: String) -> Int? {
        guard let normalized = normalizeRawID(rawID), !isLetterRawID(normalized) else { return nil }
        return Int(normalized)
    }

    public static func lowestUnusedRawID<S: Sequence>(in rawIDs: S) -> String where S.Element == String {
        let usedNumbers = Set(rawIDs.compactMap(workspaceNumber(from:)))
        var candidate = 1
        while usedNumbers.contains(candidate) {
            candidate += 1
        }
        return String(candidate)
    }

    /// Numeric IDs sort first in ascending order, then the letter IDs in keyboard order, then
    /// anything else alphabetically.
    public static func sortsBefore(_ lhs: String, _ rhs: String) -> Bool {
        switch (sortKey(lhs), sortKey(rhs)) {
        case let (.number(lhs), .number(rhs)):
            return lhs < rhs
        case (.number, _):
            return true
        case (_, .number):
            return false
        case let (.letter(lhs), .letter(rhs)):
            return lhs < rhs
        case (.letter, .other):
            return true
        case (.other, .letter):
            return false
        case let (.other(lhs), .other(rhs)):
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private enum SortKey {
        case number(Int)
        case letter(Int)
        case other(String)
    }

    private static func sortKey(_ rawID: String) -> SortKey {
        if let number = workspaceNumber(from: rawID) {
            return .number(number)
        }
        if let rank = letterRank[rawID] {
            return .letter(rank)
        }
        return .other(rawID)
    }
}

public enum WorkspaceTarget: Equatable, Sendable {
    case rawID(String)
    case displayName(String)

    public init(resolvingInput value: String) {
        if let rawID = WorkspaceIDPolicy.normalizeRawID(value) {
            self = .rawID(rawID)
        } else {
            self = .displayName(value)
        }
    }

    public init?(workspaceNumber: Int) {
        guard let rawID = WorkspaceIDPolicy.rawID(from: workspaceNumber) else { return nil }
        self = .rawID(rawID)
    }
}

extension WorkspaceTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case rawID = "raw-id"
        case displayName = "display-name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)

        switch kind {
        case .rawID:
            self = .rawID(WorkspaceIDPolicy.normalizeRawID(value) ?? value)
        case .displayName:
            self = .displayName(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .rawID(rawID):
            try container.encode(Kind.rawID, forKey: .kind)
            try container.encode(rawID, forKey: .value)
        case let .displayName(displayName):
            try container.encode(Kind.displayName, forKey: .kind)
            try container.encode(displayName, forKey: .value)
        }
    }
}
