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
            switch AppPersistence.loadState {
            case .ready(let container):
                ContentView()
                    .modelContainer(container)
            case .failed(let message):
                StartupFailureView(message: message)
            }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 750)
        #endif
    }

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
