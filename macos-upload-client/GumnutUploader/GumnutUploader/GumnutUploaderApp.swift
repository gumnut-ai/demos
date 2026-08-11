import SwiftUI

@main
struct GumnutUploaderApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
        }
        .defaultSize(width: 1100, height: 660)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
