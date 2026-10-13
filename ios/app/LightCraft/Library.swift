import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The library grid (the desktop's Grid view): every photo of the current view, newest first.
struct LibraryGrid: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 2)], spacing: 2) {
                ForEach(model.photos) { p in
                    GridCell(photo: p, model: model)
                        .onTapGesture { model.select(p.id) }
                }
            }
            .padding(2)
        }
        .background(t.gridBg)
        .overlay {
            if model.photos.isEmpty && !model.isBusy {
                EmptyLibrary(model: model)
            }
        }
    }
}

/// A grid cell: thumbnail on the cell colour, the file name and type above, rating and flag below.
struct GridCell: View {
    @Environment(\.lc) private var t
    let photo: LibraryPhoto
    @Bindable var model: AppModel

    var body: some View {
        let selected = photo.id == model.activeID
        VStack(spacing: 4) {
            HStack {
                Text(photo.fileName.split(separator: ".").first.map(String.init) ?? photo.fileName)
                    .font(LCFont.regular(LCMetrics.filmNameFont))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(photo.format)
                    .font(LCFont.semibold(LCMetrics.filmFormatFont))
            }
            .foregroundStyle(t.textDim)
            Thumbnail(image: model.thumbnail(photo.id), selected: selected)
                .aspectRatio(1, contentMode: .fit)
            HStack(spacing: 2) {
                Stars(rating: photo.rating, size: 10)
                Spacer()
                FlagMark(flag: photo.flag)
            }
            .frame(height: 12)
        }
        .padding(.horizontal, LCMetrics.filmImageInsetSide)
        .padding(.vertical, 6)
        .background(selected ? t.cellSelected : t.cell)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.fileName)
        .accessibilityValue("\(photo.rating) stars\(photo.flag == "pick" ? ", picked" : photo.flag == "reject" ? ", rejected" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The filmstrip under the photo (`detail.rs` `filmstrip`).
struct Filmstrip: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Color(.sRGB, white: 0x20 / 255).frame(height: LCMetrics.filmTopStrip)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(model.photos) { p in
                            let selected = p.id == model.activeID
                            VStack(spacing: 0) {
                                HStack {
                                    Text(p.fileName.split(separator: ".").first.map(String.init) ?? p.fileName)
                                        .font(LCFont.regular(LCMetrics.filmNameFont))
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text(p.format).font(LCFont.semibold(LCMetrics.filmFormatFont))
                                }
                                .foregroundStyle(t.textDim)
                                .frame(height: LCMetrics.filmImageInsetTop - 4)
                                Thumbnail(image: model.thumbnail(p.id), selected: selected)
                                    .overlay(alignment: .bottomLeading) { Stars(rating: p.rating, size: 8).padding(3) }
                            }
                            .padding(.horizontal, LCMetrics.filmImageInsetSide)
                            .padding(.bottom, LCMetrics.filmImageInsetBottom)
                            .frame(width: t.filmH * 1.05)
                            .background(selected ? t.cellSelected : t.canvas)
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(p.id) }
                            .id(p.id)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(p.fileName)
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.activeID) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .frame(height: t.filmH * 0.8)
        .background(t.canvas)
    }
}

struct Thumbnail: View {
    let image: CGImage?
    let selected: Bool

    var body: some View {
        GeometryReader { geo in
            if let image {
                let s = min(geo.size.width / CGFloat(image.width), geo.size.height / CGFloat(image.height))
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)
                    .overlay(Rectangle().stroke(selected ? Color.white : Color.clear, lineWidth: LCMetrics.filmSelectedStroke))
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                Color.clear
            }
        }
    }
}

struct Stars: View {
    @Environment(\.lc) private var t
    let rating: Int
    let size: CGFloat
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<rating, id: \.self) { _ in LCIconView(icon: .starFilled, size: size, color: t.star) }
        }
    }
}

struct FlagMark: View {
    @Environment(\.lc) private var t
    let flag: String
    var body: some View {
        switch flag {
        case "pick": LCIconView(icon: .flagPick, size: 11, color: t.pick)
        case "reject": LCIconView(icon: .flagReject, size: 11, color: t.reject)
        default: EmptyView()
        }
    }
}

/// The desktop's bottom bar: view mode, rating, flags.
struct BottomBar: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            barButton(.gridPhoto, "Grid", active: model.mode == .grid) { model.mode = .grid }
            barButton(.single, "Detail", active: model.mode == .detail) {
                if let id = model.activeID ?? model.photos.first?.id { model.select(id) }
            }
            .disabled(model.photos.isEmpty)
            Spacer()
            if let p = model.activePhoto {
                HStack(spacing: 0) {
                    ForEach(1...5, id: \.self) { n in
                        Button { model.rate(n) } label: {
                            LCIconView(icon: n <= p.rating ? .starFilled : .star, size: 16, color: n <= p.rating ? t.star : t.icon)
                                .frame(width: 30, height: 36)
                        }
                        .accessibilityLabel("\(n) star\(n == 1 ? "" : "s")")
                        .accessibilityAddTraits(n == p.rating ? .isSelected : [])
                    }
                }
                barButton(.flagPick, "Flag as Pick", active: p.flag == "pick") { model.flag("pick") }
                barButton(.flagReject, "Reject", active: p.flag == "reject") { model.flag("reject") }
            }
        }
        .buttonStyle(LCPressStyle())
        .padding(.horizontal, 8)
        .frame(height: t.bottomBarH)
        .background(t.chrome)
    }

    private func barButton(_ icon: LCIcon, _ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LCIconView(icon: icon, size: 18, color: active ? t.text : nil)
                .frame(width: 40, height: 34)
                .background(active ? t.toolActive : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct EmptyLibrary: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            LCIconView(icon: .photos, size: 40, color: t.textDim)
            Text("Your library is empty")
                .font(LCFont.semibold(15))
                .foregroundStyle(t.text)
            Text("Import photos from your Photos library or from Files.\nThey're copied into LightCraft's library; the originals stay as they are.")
                .font(LCFont.regular(13))
                .foregroundStyle(t.textLabel)
                .multilineTextAlignment(.center)
            ImportMenu(model: model) {
                Text("Import Photos…")
                    .font(LCFont.semibold(LCMetrics.buttonFont))
                    .foregroundStyle(t.text)
                    .padding(.horizontal, LCMetrics.buttonPadding)
                    .frame(minHeight: 30)
                    .background(t.button, in: RoundedRectangle(cornerRadius: LCMetrics.buttonRadius))
                    .overlay(RoundedRectangle(cornerRadius: LCMetrics.buttonRadius).strokeBorder(t.buttonBorder))
            }
        }
        .padding(32)
    }
}

/// Import from Photos or Files. Picked files are copied to a temporary folder, then into the
/// library (`library.import` with mode `copy`).
struct ImportMenu<Label: View>: View {
    @Bindable var model: AppModel
    @ViewBuilder let label: () -> Label
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var browsing = false

    var body: some View {
        Menu {
            Button("From Photos…", systemImage: "photo.on.rectangle") { picking = true }
            Button("From Files…", systemImage: "folder") { browsing = true }
        } label: {
            label()
        }
        .accessibilityLabel("Import Photos")
        .photosPicker(isPresented: $picking, selection: $picked, maxSelectionCount: 100, matching: .images, preferredItemEncoding: .current)
        .fileImporter(isPresented: $browsing, allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.importFiles(Self.copyIn(urls)) }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                var files: [URL] = []
                for item in items {
                    if let f = try? await item.loadTransferable(type: PickedFile.self) { files.append(AppModel.importable(f.url)) }
                }
                await model.importFiles(files)
            }
        }
    }

    /// Files from the Files app: read through their security scope into the temporary folder.
    private static func copyIn(_ urls: [URL]) -> [URL] {
        urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let dest = try? PickedFile.temporaryCopy(of: url) else { return nil }
            return AppModel.importable(dest)
        }
    }
}

/// A photo from the Photos picker, as its original file (name and format kept).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedFile(url: try temporaryCopy(of: received.file))
        }
    }

    static func temporaryCopy(of file: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: dest)
        return dest
    }
}
