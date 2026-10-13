import SwiftUI

@main
struct LightCraftApp: App {
    @State private var model = AppModel()
    @State private var appearance = Appearance()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, appearance: appearance)
        }
    }
}
