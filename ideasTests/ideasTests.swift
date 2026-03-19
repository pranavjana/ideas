//
//  ideasTests.swift
//  ideasTests
//
//  Created by Pranav Janakiraman on 2/3/26.
//

import Foundation
import Testing
import SwiftData
@testable import ideas

@MainActor
struct ideasTests {

    @Test func keychainRoundTrip() async throws {
        _ = AIProviderKeychain.clearAPIKey()
        defer { _ = AIProviderKeychain.clearAPIKey() }

        #expect(AIProviderKeychain.apiKey().isEmpty)
        #expect(AIProviderKeychain.setAPIKey("sk-or-test-123"))
        #expect(AIProviderKeychain.apiKey() == "sk-or-test-123")
        #expect(AIProviderKeychain.clearAPIKey())
        #expect(AIProviderKeychain.apiKey().isEmpty)
    }

    @Test func pendingMigrationMovesStoredKeyToKeychain() async throws {
        _ = AIProviderKeychain.clearAPIKey()
        defer {
            UserDefaults.standard.removeObject(forKey: AIProviderKeychain.pendingMigrationKey)
            _ = AIProviderKeychain.clearAPIKey()
        }

        UserDefaults.standard.set("sk-or-migrated", forKey: AIProviderKeychain.pendingMigrationKey)
        AIProviderKeychain.consumePendingMigrationValue()

        #expect(AIProviderKeychain.apiKey() == "sk-or-migrated")
        #expect(UserDefaults.standard.string(forKey: AIProviderKeychain.pendingMigrationKey) == nil)
    }

    @Test func currentVersionedContainerBuildsInMemory() throws {
        let schema = Schema(versionedSchema: AppSchemaV2.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)

        _ = try ModelContainer(
            for: schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [config]
        )
    }

    @Test func fileBackedV1StoreMigratesIntoV2AndMovesKeyToKeychain() throws {
        _ = AIProviderKeychain.clearAPIKey()
        UserDefaults.standard.removeObject(forKey: AIProviderKeychain.pendingMigrationKey)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            UserDefaults.standard.removeObject(forKey: AIProviderKeychain.pendingMigrationKey)
            _ = AIProviderKeychain.clearAPIKey()
        }

        let storeURL = tempDir.appendingPathComponent("Ideas.store")

        let v1Schema = Schema(versionedSchema: AppSchemaV1.self)
        let v1Config = ModelConfiguration(schema: v1Schema, url: storeURL)
        let v1Container = try ModelContainer(for: v1Schema, configurations: [v1Config])
        let legacyProfile = AppSchemaV1.UserProfile()
        legacyProfile.bio = "builder"
        legacyProfile.openaiAPIKey = "sk-or-from-v1-store"
        v1Container.mainContext.insert(legacyProfile)
        try v1Container.mainContext.save()

        let v2Schema = Schema(versionedSchema: AppSchemaV2.self)
        let v2Config = ModelConfiguration(schema: v2Schema, url: storeURL)
        let v2Container = try ModelContainer(
            for: v2Schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [v2Config]
        )

        let profiles = try v2Container.mainContext.fetch(FetchDescriptor<UserProfile>())
        #expect(profiles.count == 1)
        #expect(profiles.first?.bio == "builder")
        #expect(AIProviderKeychain.apiKey() == "sk-or-from-v1-store")
    }

    @Test func migrationPlanIncludesLegacyAndLiveSchemas() {
        #expect(AppMigrationPlan.schemas.count == 2)
        #expect(AppMigrationPlan.stages.count == 1)
    }

}
