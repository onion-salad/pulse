import SwiftUI

@main
struct PulseApp: App {
    @StateObject private var store = PulseStore()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear {
                    appDelegate.store = store
                    store.load()
                }
                .onOpenURL { url in
                    store.handle(url: url)
                }
        }
    }
}

