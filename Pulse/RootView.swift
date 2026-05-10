import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: PulseStore
    @State private var page = 0

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $page) {
                CameraPage(isActive: page == 0).tag(0)
                ContentView().tag(1)
                ArchiveView().tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Page indicator — top center
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Color.white : Color.white.opacity(0.22))
                        .frame(width: i == page ? 18 : 6, height: 4)
                        .animation(.spring(response: 0.3), value: page)
                }
            }
            .padding(.top, 6)
        }
        .onChange(of: store.showingCapture) { _, showing in
            if showing {
                page = 0
                store.showingCapture = false
            }
        }
        .preferredColorScheme(.dark)
    }
}
