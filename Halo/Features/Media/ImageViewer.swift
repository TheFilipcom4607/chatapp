import SwiftUI

/// Full-screen zoomable image viewer.
struct ImageViewer: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(1 - min(0.6, abs(dragOffset.height) / 400))
            if let img = MediaStore.image(for: item) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { v in scale = max(1, min(6, lastScale * v.magnification)) }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1.01 { withAnimation(Motion.smooth) { offset = .zero } }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { v in dragOffset = v.translation }
                            .onEnded { v in
                                if scale <= 1.01 && abs(v.translation.height) > 140 { dismiss(); return }
                                if scale > 1.01 { offset.width += v.translation.width; offset.height += v.translation.height }
                                withAnimation(Motion.smooth) { dragOffset = .zero }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(Motion.smooth) {
                            scale = scale > 1 ? 1 : 2.5
                            lastScale = scale
                            if scale == 1 { offset = .zero }
                        }
                    }
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 40, height: 40) }
                            .buttonStyle(.glass).buttonBorderShape(.circle)
                        Spacer()
                        ShareLink(item: Image(uiImage: img), preview: SharePreview(item.prompt ?? "Image", image: Image(uiImage: img))) {
                            Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).frame(width: 40, height: 40)
                        }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                        Button {
                            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                            Haptics.success()
                            app.showToast("Saved to Photos")
                        } label: { Image(systemName: "arrow.down.to.line").font(.body.weight(.semibold)).frame(width: 40, height: 40) }
                            .buttonStyle(.glass).buttonBorderShape(.circle)
                    }
                    .padding(.horizontal, 16)
                    Spacer()
                    if let prompt = item.prompt, prompt != "Figure" {
                        Text(prompt)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(4)
                            .padding(14)
                            .glassCard(cornerRadius: 18)
                            .padding(16)
                    }
                }
                .opacity(scale > 1.01 ? 0 : 1)
                .animation(Motion.gentle, value: scale)
            }
        }
        .statusBarHidden()
    }
}
