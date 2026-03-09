import SwiftUI
import SwiftData
import CoreText

@main
struct ideasApp: App {
    init() {
        registerCustomFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 750)
        #endif
        .modelContainer(Self.sharedContainer)
    }

    static let sharedContainer: ModelContainer = {
        let schema = Schema([Idea.self, UserProfile.self, Folder.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Schema changed — delete old store and retry
            let urls = [
                config.url,
                config.url.deletingPathExtension().appendingPathExtension("store-shm"),
                config.url.deletingPathExtension().appendingPathExtension("store-wal"),
            ]
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    private func registerCustomFonts() {
        let fontFiles = [
            "Gambarino-Regular",
            "Switzer-Regular",
            "Switzer-Medium",
            "Switzer-Semibold",
            "Switzer-Light",
        ]
        for name in fontFiles {
            if let url = Bundle.main.url(forResource: name, withExtension: "otf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}
