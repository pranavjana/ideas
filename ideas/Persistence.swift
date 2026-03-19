import SwiftUI
import SwiftData

enum AppSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [
        Idea.self,
        UserProfile.self,
        Folder.self,
    ]
}

enum AppSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static let models: [any PersistentModel.Type] = [
        Idea.self,
        UserProfile.self,
        Folder.self,
    ]
}

enum AppMigrationPlan: SchemaMigrationPlan {
    private static let apiKeyMigrationStage = MigrationStage.custom(
        fromVersion: AppSchemaV1.self,
        toVersion: AppSchemaV2.self,
        willMigrate: { context in
            let descriptor = FetchDescriptor<AppSchemaV1.UserProfile>()
            let profiles = try context.fetch(descriptor)
            if let apiKey = profiles.lazy.map(\.openaiAPIKey).first(where: { !$0.isEmpty }) {
                UserDefaults.standard.set(apiKey, forKey: AIProviderKeychain.pendingMigrationKey)
            }
        },
        didMigrate: { _ in
            AIProviderKeychain.consumePendingMigrationValue()
        }
    )

    static let schemas: [any VersionedSchema.Type] = [
        AppSchemaV1.self,
        AppSchemaV2.self,
    ]

    static let stages: [MigrationStage] = [
        apiKeyMigrationStage,
    ]
}

typealias Idea = AppSchemaV2.Idea
typealias UserProfile = AppSchemaV2.UserProfile
typealias Folder = AppSchemaV2.Folder

enum AppPersistence {
    enum LoadState {
        case ready(ModelContainer)
        case failed(String)
    }

    static let loadState = load()

    private static func load() -> LoadState {
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        let schema = Schema(versionedSchema: AppSchemaV2.self)

        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: AppMigrationPlan.self,
                configurations: [config]
            )
            AIProviderKeychain.consumePendingMigrationValue()
            return .ready(container)
        } catch {
            let message = """
            ideas could not open the local database.

            your data was not deleted. this usually means the store needs a migration the app does not know how to perform yet.

            error:
            \(error.localizedDescription)
            """
            return .failed(message)
        }
    }
}

struct StartupFailureView: View {
    let message: String

    var body: some View {
        ZStack {
            Color.bgBase.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("database migration needed")
                    .font(.custom("Switzer-Semibold", size: 22))
                    .foregroundStyle(Color.fg.opacity(0.9))

                Text(message)
                    .font(.custom("Switzer-Regular", size: 14))
                    .foregroundStyle(Color.fg.opacity(0.7))
                    .lineSpacing(4)
                    .textSelection(.enabled)

                Text("do not delete the app data manually unless you intentionally want a full reset.")
                    .font(.custom("Switzer-Light", size: 12))
                    .foregroundStyle(Color.fg.opacity(0.4))
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.bgElevated)
                    .stroke(Color.fg.opacity(0.08), lineWidth: 1)
            )
            .padding(24)
        }
    }
}
