// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreFoundation
import Foundation

/// The macOS trackpad gesture that shares fingers and axis with an OmniWM workspace swipe.
enum SystemSwipeGestureGroup: String, Codable, Equatable {
    /// "Swipe between full-screen applications": three- or four-finger horizontal swipe.
    case fullScreenAppSwipe
    /// Mission Control: three- or four-finger upward swipe.
    case missionControl

    var displayName: String {
        switch self {
        case .fullScreenAppSwipe: "Swipe between full-screen applications"
        case .missionControl: "Mission Control"
        }
    }
}

enum SystemSwipeGesturePolicy {
    /// Which macOS gesture OmniWM should hold off while workspace swipe is active, if any.
    static func managedGroup(
        workspaceSwipeEnabled: Bool,
        disablesSystemGesture: Bool,
        fingerCount: GestureFingerCount,
        axis: WorkspaceSwipeAxis
    ) -> SystemSwipeGestureGroup? {
        guard workspaceSwipeEnabled, disablesSystemGesture, fingerCount != .two else { return nil }
        switch axis {
        case .horizontal: return .fullScreenAppSwipe
        case .vertical: return .missionControl
        }
    }
}

enum SystemGesturePreferenceDomain: String, Codable, Equatable, CaseIterable {
    case builtInTrackpad = "com.apple.AppleMultitouchTrackpad"
    case bluetoothTrackpad = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    case dock = "com.apple.dock"
    /// `NSGlobalDomain` for the current host, where the Dock reads its swipe finger counts.
    case globalCurrentHost = "NSGlobalDomain"
}

enum SystemGesturePreferenceValue: Codable, Equatable {
    case integer(Int)
    case boolean(Bool)
}

struct SystemGesturePreferenceAddress: Codable, Equatable, Hashable {
    let domain: SystemGesturePreferenceDomain
    let key: String
}

struct SystemGesturePreferenceSpec: Equatable {
    let address: SystemGesturePreferenceAddress
    let enabledValue: SystemGesturePreferenceValue
    let disabledValue: SystemGesturePreferenceValue
}

extension SystemSwipeGestureGroup {
    private static let trackpadDomains: [SystemGesturePreferenceDomain] = [.builtInTrackpad, .bluetoothTrackpad]

    /// Every preference System Settings touches when this gesture is switched off, in the same
    /// order. The trackpad domains keep the settings UI consistent, the global host domain is what
    /// the Dock consults, and the Dock domain carries the Mission Control master switch.
    var preferenceSpecs: [SystemGesturePreferenceSpec] {
        var specs: [SystemGesturePreferenceSpec] = []
        for domain in Self.trackpadDomains {
            for key in trackpadKeys {
                specs.append(Self.integerSpec(domain: domain, key: key))
            }
        }
        for key in globalKeys {
            specs.append(Self.integerSpec(domain: .globalCurrentHost, key: key))
        }
        if self == .missionControl {
            specs.append(SystemGesturePreferenceSpec(
                address: SystemGesturePreferenceAddress(domain: .dock, key: "showMissionControlGestureEnabled"),
                enabledValue: .boolean(true),
                disabledValue: .boolean(false)
            ))
        }
        return specs
    }

    var domains: [SystemGesturePreferenceDomain] {
        var seen: [SystemGesturePreferenceDomain] = []
        for spec in preferenceSpecs where !seen.contains(spec.address.domain) {
            seen.append(spec.address.domain)
        }
        return seen
    }

    /// Distributed notifications the Trackpad settings extension posts after changing this gesture,
    /// which the Dock and the trackpad stack listen for.
    var changeNotificationNames: [String] {
        let gestureNotifications = switch self {
        case .fullScreenAppSwipe: ["3FHorizSwipeDidChangeNotification", "4FHorizSwipeDidChangeNotification"]
        case .missionControl: ["3FVertSwipeDidChangeNotification", "4FVertSwipeDidChangeNotification"]
        }
        return gestureNotifications + [
            "com.apple.AppleMultitouchTrackpadDomainDidChangeNotification",
            "com.apple.dock.prefchanged"
        ]
    }

    private var trackpadKeys: [String] {
        switch self {
        case .fullScreenAppSwipe: ["TrackpadThreeFingerHorizSwipeGesture", "TrackpadFourFingerHorizSwipeGesture"]
        case .missionControl: ["TrackpadThreeFingerVertSwipeGesture", "TrackpadFourFingerVertSwipeGesture"]
        }
    }

    private var globalKeys: [String] {
        switch self {
        case .fullScreenAppSwipe:
            ["com.apple.trackpad.threeFingerHorizSwipeGesture", "com.apple.trackpad.fourFingerHorizSwipeGesture"]
        case .missionControl:
            ["com.apple.trackpad.threeFingerVertSwipeGesture", "com.apple.trackpad.fourFingerVertSwipeGesture"]
        }
    }

    private static func integerSpec(domain: SystemGesturePreferenceDomain, key: String) -> SystemGesturePreferenceSpec {
        SystemGesturePreferenceSpec(
            address: SystemGesturePreferenceAddress(domain: domain, key: key),
            enabledValue: .integer(2),
            disabledValue: .integer(0)
        )
    }
}

@MainActor
protocol SystemGesturePreferenceBackend: AnyObject {
    func read(_ address: SystemGesturePreferenceAddress) -> SystemGesturePreferenceValue?
    func write(_ value: SystemGesturePreferenceValue, to address: SystemGesturePreferenceAddress)
    func synchronize(_ domain: SystemGesturePreferenceDomain)
    func postNotification(named name: String)
}

struct SystemGesturePreferenceEntry: Codable, Equatable {
    let address: SystemGesturePreferenceAddress
    let value: SystemGesturePreferenceValue?
}

/// The macOS values captured right before OmniWM switched a gesture off, so they can be put back.
struct SystemSwipeGestureSnapshot: Codable, Equatable {
    var group: SystemSwipeGestureGroup
    var entries: [SystemGesturePreferenceEntry]
}

@MainActor
protocol SystemSwipeGestureSnapshotStore: AnyObject {
    func load() -> SystemSwipeGestureSnapshot?
    func save(_ snapshot: SystemSwipeGestureSnapshot)
    func clear()
}

/// Turns the conflicting macOS swipe gesture off while workspace swipe is active and restores it
/// afterwards. The snapshot lives outside the settings file so a crash can be repaired on the next
/// launch.
@MainActor
final class SystemSwipeGestureCoordinator {
    private let backend: any SystemGesturePreferenceBackend
    private let snapshots: any SystemSwipeGestureSnapshotStore
    private(set) var activeGroup: SystemSwipeGestureGroup?

    init(
        backend: any SystemGesturePreferenceBackend = CFPreferencesSystemGestureBackend(),
        snapshots: any SystemSwipeGestureSnapshotStore = DefaultsSwipeGestureSnapshotStore()
    ) {
        self.backend = backend
        self.snapshots = snapshots
        activeGroup = snapshots.load()?.group
    }

    /// Brings macOS in line with `desired`. `force` re-applies the disabled values even when the
    /// group is unchanged, without replacing the captured snapshot; launch uses it in case the user
    /// re-enabled the gesture in System Settings while OmniWM was not running.
    func reconcile(desired: SystemSwipeGestureGroup?, force: Bool = false) {
        if desired == activeGroup {
            if force, let desired {
                disable(desired, replaceSnapshot: false)
            }
            return
        }
        if let activeGroup {
            restore(activeGroup)
        }
        if let desired {
            disable(desired, replaceSnapshot: true)
        }
        activeGroup = desired
    }

    func restoreAll() {
        reconcile(desired: nil)
    }

    private func disable(_ group: SystemSwipeGestureGroup, replaceSnapshot: Bool) {
        let specs = group.preferenceSpecs
        for domain in group.domains {
            backend.synchronize(domain)
        }
        if replaceSnapshot || snapshots.load()?.group != group {
            let entries = specs.map { spec in
                SystemGesturePreferenceEntry(address: spec.address, value: backend.read(spec.address))
            }
            snapshots.save(SystemSwipeGestureSnapshot(group: group, entries: entries))
        }
        for spec in specs {
            backend.write(spec.disabledValue, to: spec.address)
        }
        commit(group)
    }

    private func restore(_ group: SystemSwipeGestureGroup) {
        let specs = group.preferenceSpecs
        let snapshot = snapshots.load()
        let captured = snapshot?.group == group ? (snapshot?.entries ?? []) : []
        let capturedValues = Dictionary(
            captured.compactMap { entry in entry.value.map { (entry.address, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let presentValues = specs.compactMap { spec in capturedValues[spec.address].map { (spec, $0) } }
        let wasEnabled = presentValues.isEmpty
            || presentValues.contains { spec, value in value != spec.disabledValue }
        for spec in specs {
            let value = wasEnabled ? (capturedValues[spec.address] ?? spec.enabledValue) : spec.enabledValue
            backend.write(value, to: spec.address)
        }
        snapshots.clear()
        commit(group)
    }

    private func commit(_ group: SystemSwipeGestureGroup) {
        for domain in group.domains {
            backend.synchronize(domain)
        }
        for name in group.changeNotificationNames {
            backend.postNotification(named: name)
        }
    }
}

@MainActor
final class CFPreferencesSystemGestureBackend: SystemGesturePreferenceBackend {
    init() {}

    func read(_ address: SystemGesturePreferenceAddress) -> SystemGesturePreferenceValue? {
        let key: CFString = address.key as NSString
        let raw: Any? = switch address.domain {
        case .globalCurrentHost:
            CFPreferencesCopyValue(
                key,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        default:
            CFPreferencesCopyAppValue(key, address.domain.rawValue as NSString)
        }
        guard let number = raw as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .boolean(number.boolValue)
        }
        guard CFGetTypeID(number) == CFNumberGetTypeID(), !CFNumberIsFloatType(number) else { return nil }
        return .integer(number.intValue)
    }

    func write(_ value: SystemGesturePreferenceValue, to address: SystemGesturePreferenceAddress) {
        let key: CFString = address.key as NSString
        let propertyList: CFPropertyList = switch value {
        case let .integer(number): NSNumber(value: number)
        case let .boolean(flag): flag ? kCFBooleanTrue : kCFBooleanFalse
        }
        switch address.domain {
        case .globalCurrentHost:
            CFPreferencesSetValue(
                key,
                propertyList,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        default:
            CFPreferencesSetAppValue(key, propertyList, address.domain.rawValue as NSString)
        }
    }

    func synchronize(_ domain: SystemGesturePreferenceDomain) {
        switch domain {
        case .globalCurrentHost:
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        default:
            CFPreferencesAppSynchronize(domain.rawValue as NSString)
        }
    }

    func postNotification(named name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

@MainActor
final class DefaultsSwipeGestureSnapshotStore: SystemSwipeGestureSnapshotStore {
    static let defaultsKey = "systemSwipeGestureSnapshot"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SystemSwipeGestureSnapshot? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SystemSwipeGestureSnapshot.self, from: data)
    }

    func save(_ snapshot: SystemSwipeGestureSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
