import SwiftUI

@main
struct NamecardApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MainView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.nfc.backgrounded() }
                }
        }
    }
}
