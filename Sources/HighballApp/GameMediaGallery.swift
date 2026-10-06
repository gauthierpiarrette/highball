import SwiftUI
import HighballKit

/// A single full-size image and lazy thumbnails: no web view, video player, or slideshow timer.
struct GameMediaGallery: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: LibraryItem
    let details: SteamGameDetails?
    let width: CGFloat
    @Binding var selectedURL: URL?
    @Binding var choseImage: Bool
    @State private var coverDropTargeted = false

    private var screenshots: [SteamGameDetails.Screenshot] { details?.screenshots ?? [] }
    private var customCover: NSImage? {
        guard let url = state.coverStore.coverURL(for: item.id) else { return nil }
        return NSImage(contentsOf: url)
    }
    private var artworkURL: URL? { item.artworkWide ?? details?.header ?? item.artworkTall }
    private var selection: Int { selectedURL.flatMap { url in screenshots.firstIndex { $0.full == url }.map { $0 + 1 } } ?? 0 }

    var body: some View {
        VStack(spacing: 12) {
            Color.black.opacity(0.24)
                .frame(height: width * 9 / 16)
                .overlay {
                    GalleryImage(url: selectedURL ?? artworkURL, local: selectedURL == nil ? customCover : nil)
                        .id("\(selectedURL?.absoluteString ?? "cover")-\(state.coverVersion)")
                        .transition(.opacity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(selectedURL == nil ? L("Game artwork") : String(format: L("Screenshot %d"), selection))
                }
                .overlay(alignment: .bottomTrailing) {
                    if !screenshots.isEmpty {
                        HStack(spacing: 10) {
                            Button { select((selection + screenshots.count) % (screenshots.count + 1)) } label: {
                                Image(systemName: "chevron.left").frame(width: 28, height: 28)
                            }.accessibilityLabel(L("Previous image"))
                            Text("\(selection + 1) / \(screenshots.count + 1)").font(.caption.monospacedDigit())
                            Button { select((selection + 1) % (screenshots.count + 1)) } label: {
                                Image(systemName: "chevron.right").frame(width: 28, height: 28)
                            }.accessibilityLabel(L("Next image"))
                        }
                        .buttonStyle(.plain).foregroundStyle(.white)
                        .padding(4).padding(.horizontal, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(14)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .stroke(coverDropTargeted ? HB.amber : HB.cardStroke, lineWidth: coverDropTargeted ? 2 : 1))
                .onDrop(of: [.image], isTargeted: $coverDropTargeted) { providers in
                    let accepted = state.acceptCoverDrop(providers, for: item)
                    if accepted { selectedURL = nil; choseImage = true }
                    return accepted
                }

            if !screenshots.isEmpty {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            thumbnail(index: 0, url: artworkURL, local: customCover)
                            ForEach(Array(screenshots.enumerated()), id: \.element.full) { index, screenshot in
                                thumbnail(index: index + 1, url: screenshot.thumbnail)
                            }
                        }.padding(2)
                    }
                    .frame(height: 76)
                    .onChange(of: selection) { _, index in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { scroll.scrollTo(index, anchor: .center) }
                    }
                }
            }
        }
        .onAppear { pickInitialImage() }
        .onChange(of: details?.appID) { _, _ in
            pickInitialImage()
        }
        .onChange(of: state.coverVersion) { _, _ in selectedURL = nil; choseImage = true }
    }

    private func pickInitialImage() {
        if !choseImage, customCover == nil { selectedURL = screenshots.first?.full }
    }

    private func thumbnail(index: Int, url: URL?, local: NSImage? = nil) -> some View {
        Button { select(index) } label: {
            Color.black.opacity(0.24)
                .frame(width: 128, height: 72)
                .overlay { GalleryImage(url: url, local: local, thumbnail: true) }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(index == selection ? HB.amber : HB.cardStroke, lineWidth: index == selection ? 2 : 1))
        }
        .buttonStyle(.plain)
        .id(index)
        .accessibilityLabel(index == 0 ? L("Game artwork") : String(format: L("Screenshot %d"), index))
        .accessibilityAddTraits(index == selection ? .isSelected : [])
    }

    private func select(_ index: Int) {
        choseImage = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            selectedURL = index == 0 ? nil : screenshots[index - 1].full
        }
    }
}

private struct GalleryImage: View {
    let url: URL?
    var local: NSImage? = nil
    var thumbnail = false

    var body: some View {
        if let local = local ?? url.flatMap({ $0.isFileURL ? NSImage(contentsOf: $0) : nil }) {
            Image(nsImage: local).resizable().scaledToFit()
        } else if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .empty:
                    if thumbnail { placeholder } else { ProgressView().controlSize(.small) }
                default: placeholder
                }
            }
        } else { placeholder }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "gamecontroller").font(thumbnail ? .body : .system(size: 40, weight: .light))
            if !thumbnail { Text(L("No image available")).font(.callout) }
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
