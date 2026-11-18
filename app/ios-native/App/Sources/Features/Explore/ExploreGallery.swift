import ImageIO
import SwiftUI
import UIKit

struct ExploreGalleryItem: Identifiable, Hashable, Sendable {
    let id: Int32
    let title: String
    let coverURL: String
    var backdropURL: String = ""
}

/// 一条纵向内容流承载当季海报与热门网格，场景底色跟随当前海报。
struct ExploreGallery: View {
    let features: [ExploreGalleryItem]
    let seasonTitle: String
    let trending: [ExploreGalleryItem]
    let isLoading: Bool
    let error: String?
    let onSelect: (ExploreGalleryItem) -> Void
    let onShowSchedule: () -> Void
    let onRefresh: () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var selection: Int32?
    @State private var artwork: [Int32: GalleryArtwork] = [:]
    @State private var heroVisible = true
    @GestureState private var isSwiping = false

    private var selectedIndex: Int {
        features.firstIndex { $0.id == selection } ?? 0
    }
    private var surface: Color { Color(uiColor: .systemBackground) }
    private var paper: Color {
        colorScheme == .dark ? Color(red: 0.08, green: 0.10, blue: 0.14) : Color(red: 0.955, green: 0.965, blue: 0.985)
    }
    private var rotation: Rotation {
        Rotation(
            selected: selection,
            ids: features.map(\.id),
            enabled: heroVisible && !isSwiping && !reduceMotion && !voiceOver && scenePhase == .active
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let top = geometry.safeAreaInsets.top
            let windowHeight = geometry.size.height + top + geometry.safeAreaInsets.bottom
            let headerHeight = max(top + 140, windowHeight * 2 / 3)
            ZStack {
                ambientBackdrop.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        if features.isEmpty {
                            heading.padding(.top, top + 8).padding(.bottom, 8)
                        } else {
                            hero(height: headerHeight, top: top)
                                .onScrollVisibilityChange(threshold: 0.45) { heroVisible = $0 }
                        }
                        gallery(width: geometry.size.width)
                    }
                    .padding(.bottom, 24)
                }
                .refreshable { await onRefresh() }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .onChange(of: features.map(\.id), initial: true) { _, ids in
            if !ids.contains(where: { $0 == selection }) { selection = ids.first }
        }
        .task(id: features) { await loadArtwork() }
        .task(id: rotation) {
            guard rotation.enabled, features.count > 1 else { return }
            do {
                try await Task.sleep(for: .seconds(7))
                try Task.checkCancellation()
                advance(by: 1)
            } catch is CancellationError {}
            catch {}
        }
    }

    private var heading: some View {
        HStack {
            Text("探索").font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Button(action: onShowSchedule) {
                Label("时间表", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("explore-schedule")
        }
        .padding(.horizontal, 16)
    }

    private func hero(height: CGFloat, top: CGFloat) -> some View {
        TabView(selection: $selection) {
            ForEach(features) { item in
                heroPage(item, height: height, top: top)
                    .onTapGesture { onSelect(item) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.title)
                    .accessibilityHint("打开番剧详情")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onSelect(item) }
                    .accessibilityIdentifier("explore-hero-\(item.id)")
                    .tag(Optional(item.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: height)
        .simultaneousGesture(DragGesture(minimumDistance: 12).updating($isSwiping) { _, state, _ in state = true })
        .overlay(alignment: .top) { heading.padding(.top, top + 8) }
        .overlay(alignment: .bottomTrailing) {
            if features.count > 1 { pageIndicator.padding(.trailing, 18).padding(.bottom, 20) }
        }
    }

    private func heroPage(_ item: ExploreGalleryItem, height: CGFloat, top: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                heroArtwork(artwork[item.id], width: geometry.size.width, height: height, top: top)
                VStack(alignment: .leading, spacing: 3) {
                    Text(seasonTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.65)
                        .multilineTextAlignment(.leading)
                }
                .padding(.leading, 16)
                .padding(.trailing, features.count > 1 ? 112 : 16)
                .padding(.bottom, 14)
            }
            .frame(width: geometry.size.width, height: height)
            .clipped()
            .contentShape(.rect)
        }
    }

    private func heroArtwork(_ art: GalleryArtwork?, width: CGFloat, height: CGFloat, top: CGFloat) -> some View {
        let edge = min(0.3, (top + 32) / height)
        return ZStack {
            if let art {
                if art.isLandscape {
                    art.image.resizable().scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                        .mask(heroFade)
                } else {
                    art.image.resizable().scaledToFit()
                        .frame(maxWidth: width * 0.48, maxHeight: height * 0.74)
                        .clipShape(.rect(cornerRadius: 14))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, 20)
                        .padding(.top, top + 30)
                        .mask(heroFade)
                }
            }
            LinearGradient(
                stops: [
                    .init(color: paper.opacity(reduceTransparency ? 1 : 0.82), location: 0),
                    .init(color: paper.opacity(0.55), location: edge),
                    .init(color: .clear, location: 0.43),
                    .init(color: .clear, location: 0.64),
                    .init(color: paper.opacity(0.75), location: 0.88),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .frame(width: width, height: height)
        // 海报和可读性遮罩一起从固定背景淡入，滚动回弹时接缝仍然透明。
        .mask {
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .white, location: edge)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private var heroFade: some View {
        LinearGradient(
            stops: [.init(color: .white, location: 0.56), .init(color: .clear, location: 1)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var ambientBackdrop: some View {
        GeometryReader { geometry in
            ZStack {
                paper
                if !reduceTransparency,
                   let current = features.indices.contains(selectedIndex) ? features[selectedIndex] : nil,
                   let art = artwork[current.id] {
                    art.image.resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .scaleEffect(1.2)
                        .blur(radius: 72)
                        .opacity(colorScheme == .dark ? 0.28 : 0.36)
                        .mask {
                            LinearGradient(colors: [.white, .white.opacity(0.32)], startPoint: .top, endPoint: .bottom)
                        }
                        .id(current.id)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: selection)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Array(features.enumerated()), id: \.element.id) { index, item in
                Button {
                    selectPage(index)
                } label: {
                    Capsule()
                        .fill(index == selectedIndex ? Color.accentColor : Color.secondary.opacity(0.55))
                        .frame(width: index == selectedIndex ? 16 : 5, height: 5)
                        .frame(minWidth: 18, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(index + 1) 张，\(item.title)")
                .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                .accessibilityIdentifier("explore-page-\(index + 1)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("选择海报")
        .padding(.horizontal, 3)
    }

    private func gallery(width: CGFloat) -> some View {
        let featuredIDs = Set(features.map(\.id))
        let titles = trending.filter { !featuredIDs.contains($0.id) }
        let counts = typeSize.isAccessibilitySize ? 2 : max(3, Int(width / 145))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: counts)
        return VStack(alignment: .leading, spacing: 12) {
            if !titles.isEmpty || features.isEmpty {
                Text("热门番剧").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            }
            if !titles.isEmpty {
                LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
                    ForEach(titles) { title in
                        Button { onSelect(title) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Rectangle().fill(surface.opacity(0.72))
                                    .aspectRatio(0.7, contentMode: .fit)
                                    .overlay {
                                        AsyncImage(url: URL(string: title.coverURL)) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            Image(systemName: "sparkles.tv").foregroundStyle(.tertiary)
                                        }
                                    }
                                    .clipShape(.rect(cornerRadius: 12))
                                Text(title.title)
                                    .font(.subheadline.weight(.medium))
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2, reservesSpace: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.primary)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(title.title)
                    }
                }
            } else if isLoading {
                ProgressView("正在加载番剧").frame(maxWidth: .infinity).padding(.vertical, 36)
            } else if error != nil {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("重试") { Task { await onRefresh() } }
                }
            } else if features.isEmpty {
                ContentUnavailableView("暂无热门番剧", systemImage: "sparkles.tv")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func advance(by step: Int) {
        guard !features.isEmpty else { return }
        selectPage((selectedIndex + step + features.count) % features.count)
    }

    private func selectPage(_ index: Int) {
        guard features.indices.contains(index) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.34)) {
            selection = features[index].id
        }
    }

    private func loadArtwork() async {
        let items = features
        artwork = artwork.filter { entry in items.contains { $0.id == entry.key } }
        await withTaskGroup(of: (Int32, GalleryArtwork?).self) { group in
            for item in items {
                group.addTask { (item.id, await GalleryArtwork.load(item)) }
            }
            for await (id, image) in group where !Task.isCancelled {
                artwork[id] = image
            }
        }
    }

    private struct Rotation: Hashable {
        let selected: Int32?
        let ids: [Int32]
        let enabled: Bool
    }
}

private struct GalleryArtwork: Sendable {
    let bitmap: CGImage
    let isLandscape: Bool

    var image: Image { Image(decorative: bitmap, scale: 1) }

    static func load(_ item: ExploreGalleryItem) async -> Self? {
        if let bitmap = await decode(item.backdropURL) {
            return Self(bitmap: bitmap, isLandscape: bitmap.width >= bitmap.height)
        }
        guard !Task.isCancelled, let bitmap = await decode(item.coverURL) else { return nil }
        return Self(bitmap: bitmap, isLandscape: bitmap.width >= bitmap.height)
    }

    private static func decode(_ address: String) async -> CGImage? {
        guard let url = URL(string: address), url.scheme == "https" else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 12 * 1024 * 1024, !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1280,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
