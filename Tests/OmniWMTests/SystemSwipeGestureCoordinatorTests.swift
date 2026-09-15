// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SystemSwipeGestureCoordinatorTests: XCTestCase {
    private final class FakeBackend: SystemGesturePreferenceBackend {
        var values: [SystemGesturePreferenceAddress: SystemGesturePreferenceValue] = [:]
        var notifications: [String] = []
        var synchronizedDomains: [SystemGesturePreferenceDomain] = []

        func read(_ address: SystemGesturePreferenceAddress) -> SystemGesturePreferenceValue? {
            values[address]
        }

        func write(_ value: SystemGesturePreferenceValue, to address: SystemGesturePreferenceAddress) {
            values[address] = value
        }

        func synchronize(_ domain: SystemGesturePreferenceDomain) {
            synchronizedDomains.append(domain)
        }

        func postNotification(named name: String) {
            notifications.append(name)
        }

        func seed(_ group: SystemSwipeGestureGroup, enabled: Bool) {
            for spec in group.preferenceSpecs {
                values[spec.address] = enabled ? spec.enabledValue : spec.disabledValue
            }
        }

        func value(_ domain: SystemGesturePreferenceDomain, _ key: String) -> SystemGesturePreferenceValue? {
            values[SystemGesturePreferenceAddress(domain: domain, key: key)]
        }
    }

    private final class FakeSnapshots: SystemSwipeGestureSnapshotStore {
        var snapshot: SystemSwipeGestureSnapshot?

        func load() -> SystemSwipeGestureSnapshot? {
            snapshot
        }

        func save(_ snapshot: SystemSwipeGestureSnapshot) {
            self.snapshot = snapshot
        }

        func clear() {
            snapshot = nil
        }
    }

    private let threeHoriz = "TrackpadThreeFingerHorizSwipeGesture"
    private let fourHoriz = "TrackpadFourFingerHorizSwipeGesture"
    private let threeVert = "TrackpadThreeFingerVertSwipeGesture"
    private let globalThreeHoriz = "com.apple.trackpad.threeFingerHorizSwipeGesture"
    private let missionControlKey = "showMissionControlGestureEnabled"

    private func makeCoordinator(
        backend: FakeBackend = FakeBackend(),
        snapshots: FakeSnapshots = FakeSnapshots()
    ) -> (SystemSwipeGestureCoordinator, FakeBackend, FakeSnapshots) {
        (SystemSwipeGestureCoordinator(backend: backend, snapshots: snapshots), backend, snapshots)
    }

    func testPolicyRequiresOptInAndPicksGroupFromAxis() {
        XCTAssertEqual(
            SystemSwipeGesturePolicy.managedGroup(
                workspaceSwipeEnabled: true, disablesSystemGesture: true, fingerCount: .four, axis: .horizontal
            ),
            .fullScreenAppSwipe
        )
        XCTAssertEqual(
            SystemSwipeGesturePolicy.managedGroup(
                workspaceSwipeEnabled: true, disablesSystemGesture: true, fingerCount: .three, axis: .vertical
            ),
            .missionControl
        )
        XCTAssertNil(SystemSwipeGesturePolicy.managedGroup(
            workspaceSwipeEnabled: false, disablesSystemGesture: true, fingerCount: .four, axis: .horizontal
        ))
        XCTAssertNil(SystemSwipeGesturePolicy.managedGroup(
            workspaceSwipeEnabled: true, disablesSystemGesture: false, fingerCount: .four, axis: .horizontal
        ))
        XCTAssertNil(SystemSwipeGesturePolicy.managedGroup(
            workspaceSwipeEnabled: true, disablesSystemGesture: true, fingerCount: .two, axis: .horizontal
        ))
    }

    func testDisablingWritesOffValuesEverywhereAndNotifies() {
        let (coordinator, backend, snapshots) = makeCoordinator()
        backend.seed(.fullScreenAppSwipe, enabled: true)

        coordinator.reconcile(desired: .fullScreenAppSwipe)

        for spec in SystemSwipeGestureGroup.fullScreenAppSwipe.preferenceSpecs {
            XCTAssertEqual(backend.values[spec.address], spec.disabledValue, spec.address.key)
        }
        XCTAssertEqual(backend.value(.builtInTrackpad, threeHoriz), .integer(0))
        XCTAssertEqual(backend.value(.bluetoothTrackpad, fourHoriz), .integer(0))
        XCTAssertEqual(backend.value(.globalCurrentHost, globalThreeHoriz), .integer(0))
        XCTAssertNil(backend.value(.dock, missionControlKey))
        XCTAssertEqual(
            backend.notifications,
            [
                "3FHorizSwipeDidChangeNotification",
                "4FHorizSwipeDidChangeNotification",
                "com.apple.AppleMultitouchTrackpadDomainDidChangeNotification",
                "com.apple.dock.prefchanged"
            ]
        )
        XCTAssertEqual(snapshots.snapshot?.group, .fullScreenAppSwipe)
        XCTAssertEqual(coordinator.activeGroup, .fullScreenAppSwipe)
    }

    func testMissionControlGroupAlsoFlipsDockSwitch() {
        let (coordinator, backend, _) = makeCoordinator()
        backend.seed(.missionControl, enabled: true)

        coordinator.reconcile(desired: .missionControl)

        XCTAssertEqual(backend.value(.dock, missionControlKey), .boolean(false))
        XCTAssertEqual(backend.value(.builtInTrackpad, threeVert), .integer(0))
        XCTAssertTrue(backend.notifications.contains("3FVertSwipeDidChangeNotification"))
        XCTAssertTrue(backend.notifications.contains("com.apple.dock.prefchanged"))
    }

    func testRestoreWritesCapturedValuesWhenGestureWasEnabled() {
        let (coordinator, backend, snapshots) = makeCoordinator()
        backend.seed(.fullScreenAppSwipe, enabled: true)
        backend.values[SystemGesturePreferenceAddress(domain: .builtInTrackpad, key: threeHoriz)] = .integer(1)
        coordinator.reconcile(desired: .fullScreenAppSwipe)
        backend.notifications.removeAll()

        coordinator.reconcile(desired: nil)

        XCTAssertEqual(backend.value(.builtInTrackpad, threeHoriz), .integer(1))
        XCTAssertEqual(backend.value(.builtInTrackpad, fourHoriz), .integer(2))
        XCTAssertEqual(backend.value(.globalCurrentHost, globalThreeHoriz), .integer(2))
        XCTAssertNil(snapshots.snapshot)
        XCTAssertNil(coordinator.activeGroup)
        XCTAssertTrue(backend.notifications.contains("com.apple.dock.prefchanged"))
    }

    func testRestoreTurnsGestureOnWhenItWasAlreadyOff() {
        let (coordinator, backend, _) = makeCoordinator()
        backend.seed(.missionControl, enabled: false)
        coordinator.reconcile(desired: .missionControl)

        coordinator.reconcile(desired: nil)

        for spec in SystemSwipeGestureGroup.missionControl.preferenceSpecs {
            XCTAssertEqual(backend.values[spec.address], spec.enabledValue, spec.address.key)
        }
        XCTAssertEqual(backend.value(.dock, missionControlKey), .boolean(true))
    }

    func testRestoreUsesEnabledDefaultsWhenNothingWasCaptured() {
        let (coordinator, backend, _) = makeCoordinator()
        coordinator.reconcile(desired: .fullScreenAppSwipe)

        coordinator.reconcile(desired: nil)

        for spec in SystemSwipeGestureGroup.fullScreenAppSwipe.preferenceSpecs {
            XCTAssertEqual(backend.values[spec.address], spec.enabledValue, spec.address.key)
        }
    }

    func testSwitchingGroupsRestoresPreviousBeforeDisablingNext() {
        let (coordinator, backend, snapshots) = makeCoordinator()
        backend.seed(.missionControl, enabled: true)
        backend.seed(.fullScreenAppSwipe, enabled: true)
        coordinator.reconcile(desired: .missionControl)
        XCTAssertEqual(backend.value(.dock, missionControlKey), .boolean(false))

        coordinator.reconcile(desired: .fullScreenAppSwipe)

        XCTAssertEqual(backend.value(.dock, missionControlKey), .boolean(true))
        XCTAssertEqual(backend.value(.builtInTrackpad, threeVert), .integer(2))
        XCTAssertEqual(backend.value(.builtInTrackpad, threeHoriz), .integer(0))
        XCTAssertEqual(snapshots.snapshot?.group, .fullScreenAppSwipe)
        XCTAssertEqual(coordinator.activeGroup, .fullScreenAppSwipe)
    }

    func testSameGroupIsIdempotentUnlessForced() {
        let (coordinator, backend, snapshots) = makeCoordinator()
        backend.seed(.fullScreenAppSwipe, enabled: true)
        coordinator.reconcile(desired: .fullScreenAppSwipe)
        let captured = snapshots.snapshot
        backend.notifications.removeAll()

        coordinator.reconcile(desired: .fullScreenAppSwipe)
        XCTAssertTrue(backend.notifications.isEmpty)

        backend.values[SystemGesturePreferenceAddress(domain: .builtInTrackpad, key: threeHoriz)] = .integer(2)
        coordinator.reconcile(desired: .fullScreenAppSwipe, force: true)

        XCTAssertEqual(backend.value(.builtInTrackpad, threeHoriz), .integer(0))
        XCTAssertFalse(backend.notifications.isEmpty)
        XCTAssertEqual(snapshots.snapshot, captured, "force must not overwrite the captured snapshot")
    }

    func testStaleSnapshotFromPreviousRunIsRestoredWhenNothingIsManaged() {
        let backend = FakeBackend()
        let snapshots = FakeSnapshots()
        backend.seed(.missionControl, enabled: false)
        snapshots.snapshot = SystemSwipeGestureSnapshot(
            group: .missionControl,
            entries: SystemSwipeGestureGroup.missionControl.preferenceSpecs.map {
                SystemGesturePreferenceEntry(address: $0.address, value: $0.enabledValue)
            }
        )
        let (coordinator, _, _) = makeCoordinator(backend: backend, snapshots: snapshots)
        XCTAssertEqual(coordinator.activeGroup, .missionControl)

        coordinator.reconcile(desired: nil)

        XCTAssertEqual(backend.value(.dock, missionControlKey), .boolean(true))
        XCTAssertEqual(backend.value(.builtInTrackpad, threeVert), .integer(2))
        XCTAssertNil(snapshots.snapshot)
    }

    func testStaleSnapshotForSameGroupIsKeptOnForcedLaunchReconcile() {
        let backend = FakeBackend()
        let snapshots = FakeSnapshots()
        backend.seed(.fullScreenAppSwipe, enabled: true)
        let original = SystemSwipeGestureSnapshot(
            group: .fullScreenAppSwipe,
            entries: SystemSwipeGestureGroup.fullScreenAppSwipe.preferenceSpecs.map {
                SystemGesturePreferenceEntry(address: $0.address, value: .integer(1))
            }
        )
        snapshots.snapshot = original
        let (coordinator, _, _) = makeCoordinator(backend: backend, snapshots: snapshots)

        coordinator.reconcile(desired: .fullScreenAppSwipe, force: true)

        XCTAssertEqual(backend.value(.builtInTrackpad, threeHoriz), .integer(0))
        XCTAssertEqual(snapshots.snapshot, original)
    }

    func testUserDefaultsSnapshotStoreRoundTrips() throws {
        let suite = "SystemSwipeGestureCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DefaultsSwipeGestureSnapshotStore(defaults: defaults)
        let snapshot = SystemSwipeGestureSnapshot(
            group: .missionControl,
            entries: [
                SystemGesturePreferenceEntry(
                    address: SystemGesturePreferenceAddress(domain: .dock, key: missionControlKey),
                    value: .boolean(true)
                ),
                SystemGesturePreferenceEntry(
                    address: SystemGesturePreferenceAddress(domain: .builtInTrackpad, key: threeVert),
                    value: nil
                )
            ]
        )

        XCTAssertNil(store.load())
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
        store.clear()
        XCTAssertNil(store.load())
    }
}
