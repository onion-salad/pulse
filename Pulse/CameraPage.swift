import SwiftUI

struct CameraPage: View {
    @EnvironmentObject private var store: PulseStore
    @State private var moment: CaptureMoment?
    @State private var captureSessionID = UUID()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let moment {
                CaptureMomentView(
                    moment: moment,
                    onComplete: restartCamera
                )
                .id(captureSessionID)
                .environmentObject(store)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("カメラ準備中")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .task {
            if moment == nil {
                moment = store.prepareCameraMoment()
            }
        }
        .onChange(of: store.selectedMomentID) {
            moment = store.prepareCameraMoment()
            captureSessionID = UUID()
        }
        .preferredColorScheme(.dark)
    }

    private func restartCamera() {
        moment = store.prepareCameraMoment()
        captureSessionID = UUID()
    }
}
