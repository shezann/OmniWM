// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class DwindleCenteredMasterContractTests: XCTestCase {
    func testSwapWithMasterIsADwindleOnlyLayoutAction() throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: .swapWithMaster))

        XCTAssertEqual(spec.id, "swapWithMaster")
        XCTAssertEqual(spec.title, "Swap with Master")
        XCTAssertEqual(spec.category, .layout)
        XCTAssertEqual(spec.visibility, .normal)
        XCTAssertEqual(spec.layoutCompatibility, .dwindle)
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertEqual(spec.ipcCommandName, .swapWithMaster)

        let terms = Set(spec.searchTerms.map(ActionCatalog.normalizedSearchTerm))
        for term in ["master", "center", "promote"] {
            XCTAssertTrue(terms.contains(ActionCatalog.normalizedSearchTerm(term)), term)
        }

        let descriptor = try XCTUnwrap(spec.ipcDescriptor)
        XCTAssertEqual(descriptor.commandWords, ["swap-with-master"])
        XCTAssertEqual(descriptor.layoutCompatibility, .dwindle)
        XCTAssertTrue(descriptor.arguments.isEmpty)
    }

    func testSwapWithMasterIPCRequestRoundTrips() throws {
        XCTAssertEqual(IPCCommandName(rawValue: "swap-with-master"), .swapWithMaster)
        XCTAssertEqual(IPCCommandRequest.swapWithMaster.name, .swapWithMaster)

        let request = try IPCCommandRequest(name: .swapWithMaster, argumentValues: [])
        XCTAssertEqual(request, .swapWithMaster)
        XCTAssertThrowsError(try IPCCommandRequest(name: .swapWithMaster, argumentValues: [.direction(.left)]))

        let data = try JSONEncoder().encode(IPCCommandRequest.swapWithMaster)
        XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), .swapWithMaster)
    }

    func testCenteredMasterSettingsRoundTripThroughTOML() throws {
        var export = SettingsExport.defaults()
        XCTAssertFalse(export.dwindleCenteredMaster)
        XCTAssertEqual(export.dwindleMasterRatio, 0.5)

        export.dwindleCenteredMaster = true
        export.dwindleMasterRatio = 0.65
        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("centeredMaster = true"), toml)
        XCTAssertTrue(toml.contains("masterRatio = 0.65"), toml)

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertTrue(decoded.dwindleCenteredMaster)
        XCTAssertEqual(decoded.dwindleMasterRatio, 0.65)
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: data), [])
    }

    func testSettingsFilesWithoutCenteredMasterKeysStillLoad() throws {
        let toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let stripped = toml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("centeredMaster = ") && !$0.hasPrefix("masterRatio = ") }
            .joined(separator: "\n")
        XCTAssertNotEqual(stripped, toml)

        let decoded = try SettingsTOMLCodec.decode(Data(stripped.utf8))
        XCTAssertFalse(decoded.dwindleCenteredMaster)
        XCTAssertEqual(decoded.dwindleMasterRatio, 0.5)
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: Data(stripped.utf8)), [])
    }

    func testResolvedDwindleSettingsCarryCenteredMaster() {
        let settings = makeSettingsStore()
        settings.dwindleCenteredMaster = true
        settings.dwindleMasterRatio = 0.7

        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            hasNotch: false,
            name: "Primary"
        )
        let resolved = settings.resolvedDwindleSettings(for: monitor)
        XCTAssertTrue(resolved.centeredMaster)
        XCTAssertEqual(resolved.masterRatio, 0.7, accuracy: 0.0001)
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMCenteredMasterTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
