import SwiftUI

/// The Detail view on a phone held upright, laid out the way mobile photo editors are: the photo
/// edge to edge on the darkest canvas, a slim top bar, a row of the Edit panel's categories and a
/// tool bar at the bottom. A category's controls open in a compact sheet only while it is chosen,
/// so the photo has the whole screen otherwise. Categories are the Edit panel's sections from the
/// Rust side (`PanelLayout`); Swift names no slider.
struct PhoneEditView: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    @Bindable var appearance: Appearance
    @State private var tab: PhoneTab = .edit
    /// The open category: a section id, `PhoneEditView.profile`, or nil (sheet closed).
    @State private var category: String?
    @AppStorage("phone.histogram") private var showHistogram = false

    static let profile = "profile"

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                PhoneTopBar(model: model, appearance: appearance, showHistogram: $showHistogram)
                PhotoCanvas(model: model, inset: 0, background: t.gridBg)
                    .overlay(alignment: .topTrailing) {
                        if showHistogram, model.preview != nil {
                            HistogramView(histogram: model.histogram, capture: model.photo?.capture ?? "")
                                .frame(width: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .opacity(0.92)
                                .padding(10)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                if sheetOpen {
                    PhoneSheet(title: sheetTitle, close: closeSheet) { sheetContent }
                        .frame(height: sheetHeight(geo.size))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    switch tab {
                    case .edit: CategoryRow(model: model, category: $category)
                    case .rate: RatingRow(model: model)
                    case .presets, .history: EmptyView()
                    }
                    if tab == .edit || tab == .rate { t.chrome.frame(height: 1) }
                    PhoneToolBar(tab: Binding(get: { tab }, set: select))
                }
                .background(t.canvas.ignoresSafeArea(edges: .bottom))
            }
            .animation(.snappy(duration: 0.28), value: sheetOpen)
            .animation(.snappy(duration: 0.28), value: tab)
            .animation(.easeOut(duration: 0.2), value: showHistogram)
            // previews at the screen's pixel size, so opening a sheet doesn't render again
            .sizesPreviews(model, for: geo.size)
        }
        .background(t.gridBg)
        .sensoryFeedback(.selection, trigger: category)
    }

    private var sheetOpen: Bool {
        switch tab {
        case .edit: category != nil
        case .presets, .history: true
        case .rate: false
        }
    }

    private var sheetTitle: String? {
        guard tab == .edit, let category else { return nil }
        if category == Self.profile { return "Profile" }
        return model.layout?.sections.first { $0.id == category }?.title
    }

    @ViewBuilder private var sheetContent: some View {
        switch tab {
        case .presets: PresetsPanel(model: model)
        case .history: HistoryPanel(model: model)
        case .edit, .rate:
            ScrollView {
                VStack(spacing: 0) {
                    if category == Self.profile {
                        ProfileSheet(model: model)
                    } else if let section = model.layout?.sections.first(where: { $0.id == category }) {
                        LayoutItems(items: section.items, model: model)
                    }
                    Color.clear.frame(height: 16)
                }
                .disabled(model.photo == nil)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Room for Light's six sliders and its Curve row, but never more than about 40% of the screen.
    private func sheetHeight(_ size: CGSize) -> CGFloat {
        let rows: CGFloat = tab == .edit ? 7.6 : 9
        return min(t.sliderRowH * rows + 44, size.height * (tab == .edit ? 0.42 : 0.5))
    }

    private func select(_ new: PhoneTab) {
        if new == tab {
            // the open tab again: back to the photo
            if tab != .edit { tab = .edit } else { category = nil }
        } else {
            tab = new
        }
        model.tool = .none
    }

    private func closeSheet() {
        if tab == .edit { category = nil } else { tab = .edit }
        model.tool = .none
    }
}

enum PhoneTab: CaseIterable, Identifiable {
    case edit, presets, history, rate
    var id: Self { self }
    var title: String {
        switch self {
        case .edit: "Edit"
        case .presets: "Presets"
        case .history: "History"
        case .rate: "Rate"
        }
    }
    var icon: LCIcon {
        switch self {
        case .edit: .sliders
        case .presets: .presets
        case .history: .clock
        case .rate: .star
        }
    }
}

/// The slim top bar: back to the library; Undo, Redo, Before/After, Export and More.
struct PhoneTopBar: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    @Bindable var appearance: Appearance
    @Binding var showHistogram: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button { model.mode = .grid } label: { BarIcon(.chevronLeft, bright: true) }
                .accessibilityLabel("Library")
            if model.isBusy {
                ProgressView().controlSize(.small).tint(t.text).padding(.leading, 4)
            }
            Spacer(minLength: 0)
            Button { model.undo() } label: { BarIcon(.undo, bright: true) }
                .disabled(model.undoLabel == nil)
                .accessibilityLabel(model.undoLabel.map { "Undo \($0)" } ?? "Undo")
            Button { model.redo() } label: { BarIcon(.redo, bright: true) }
                .disabled(model.redoLabel == nil)
                .accessibilityLabel(model.redoLabel.map { "Redo \($0)" } ?? "Redo")
            Button { model.showingOriginal.toggle() } label: {
                BarIcon(.beforeAfter, active: model.showingOriginal, bright: true)
            }
            .accessibilityLabel("Before and After")
            .accessibilityAddTraits(model.showingOriginal ? .isSelected : [])
            .disabled(model.activeID == nil)
            Button { Task { await model.exportToPhotos() } } label: { BarIcon(.share, bright: true) }
                .accessibilityLabel("Export to Photos")
                .disabled(model.activeID == nil || model.isBusy)
            more
        }
        .buttonStyle(LCPressStyle())
        .padding(.horizontal, 4)
        .frame(height: 44)
    }

    private var more: some View {
        Menu {
            Toggle("Show Histogram", systemImage: "chart.bar.xaxis", isOn: $showHistogram)
            Button("Reset All Edits", systemImage: "arrow.counterclockwise", role: .destructive) { model.edit("develop.reset") }
                .disabled(!(model.photo?.edited ?? false))
            Divider()
            Picker("Appearance", selection: $appearance.mode) {
                ForEach(AppearanceMode.allCases) { m in
                    Label(m.label, image: m.icon.rawValue).tag(m)
                }
            }
            Menu("Theme") {
                Picker("Dark Theme", selection: $appearance.darkTheme) {
                    ForEach(LCTokens.all.filter(\.isDark)) { Text($0.label).tag($0.id) }
                }
                Picker("Light Theme", selection: $appearance.lightTheme) {
                    ForEach(LCTokens.all.filter { !$0.isDark }) { Text($0.label).tag($0.id) }
                }
            }
        } label: {
            BarIcon(.dots, bright: true)
        }
        .accessibilityLabel("More")
    }
}

/// The row of categories over the tool bar: Auto (applies it), Profile, then the Edit panel's
/// sections, each an icon over its name with a dot when it holds edits. Tap one to open its
/// controls, tap it again to close them.
struct CategoryRow: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    @Binding var category: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                tile("Auto", symbol: "wand.and.stars", selected: false, edited: false) {
                    model.edit("develop.auto")
                    model.showToast("Auto settings applied")
                }
                t.divider.brightness(t.isDark ? 0.12 : -0.12).frame(width: 1, height: 34).padding(.horizontal, 4)
                tile("Profile", symbol: "square.stack.3d.down.right", selected: category == PhoneEditView.profile,
                     edited: model.photo?.profileId != "lc.color" || (model.photo?.blackAndWhite ?? false)) {
                    toggle(PhoneEditView.profile)
                }
                ForEach(model.layout?.sections ?? []) { s in
                    tile(s.title, symbol: Self.symbol(s.id), selected: category == s.id, edited: edited(s.items)) { toggle(s.id) }
                }
            }
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.hidden)
        .frame(height: 66)
        .disabled(model.photo == nil)
    }

    /// An SF Symbol for a section (presentation only: the sections themselves come from Rust).
    static func symbol(_ id: String) -> String {
        switch id {
        case "light": "sun.max"
        case "color": "thermometer.medium"
        case "effects": "circle.dashed.inset.filled"
        case "detail": "triangle"
        case "optics": "camera.aperture"
        case "calibration": "dial.medium"
        default: "slider.horizontal.3"
        }
    }

    /// Whether any slider among `items` (flyouts included) is off its default.
    private func edited(_ items: [LayoutItem]) -> Bool {
        items.contains { item in
            let ids = [item.id, item.control].compactMap { $0 } + (item.controls ?? [])
            if ids.contains(where: { id in model.controls[id].map { $0.value != $0.default } ?? false }) { return true }
            return edited(item.items ?? [])
        }
    }

    private func toggle(_ id: String) {
        category = category == id ? nil : id
        model.tool = .none
    }

    private func tile(_ title: String, symbol: String, selected: Bool, edited: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .frame(height: 24)
                Text(title)
                    .font(LCFont.medium(11.5))
                    .lineLimit(1)
                Circle()
                    .fill(t.textLabel)
                    .frame(width: 4, height: 4)
                    .opacity(edited ? 1 : 0)
            }
            .foregroundStyle(selected ? t.text : t.textDim)
            .frame(minWidth: 62)
            .padding(.horizontal, 4)
            .frame(height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(LCPressStyle())
        .accessibilityLabel(title)
        .accessibilityValue(edited ? "Edited" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Rating and flags, in place of the categories while Rate is chosen.
struct RatingRow: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            if let p = model.activePhoto {
                ForEach(1...5, id: \.self) { n in
                    Button { model.rate(n) } label: {
                        LCIconView(icon: n <= p.rating ? .starFilled : .star, size: 20, color: n <= p.rating ? t.star : t.icon)
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("\(n) star\(n == 1 ? "" : "s")")
                    .accessibilityAddTraits(n == p.rating ? .isSelected : [])
                }
                t.divider.frame(width: 1, height: 22).padding(.horizontal, 10)
                flag(.flagPick, "Flag as Pick", key: "pick", on: p.flag == "pick")
                flag(.flagReject, "Reject", key: "reject", on: p.flag == "reject")
            }
        }
        .buttonStyle(LCPressStyle())
        .frame(maxWidth: .infinity)
        .frame(height: 66)
    }

    private func flag(_ icon: LCIcon, _ label: String, key: String, on: Bool) -> some View {
        Button { model.flag(key) } label: {
            LCIconView(icon: icon, size: 20, color: on ? (key == "reject" ? t.reject : t.pick) : t.icon)
                .frame(width: 44, height: 40)
                .background(on ? t.toolActive : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The bottom tool bar: Edit, Presets, History, Rate. The chosen one sits on the accent colour.
struct PhoneToolBar: View {
    @Environment(\.lc) private var t
    @Binding var tab: PhoneTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PhoneTab.allCases) { item in
                let on = item == tab
                Button { tab = item } label: {
                    LCIconView(icon: item.icon, size: 22, color: on ? .white : t.text)
                        .frame(width: 50, height: 46)
                        .background(on ? t.accent : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LCPressStyle())
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

/// The compact sheet that holds a category's controls: a grabber (drag down to close), the
/// category's title, and the content, on the panel colour the sliders are drawn for.
struct PhoneSheet<Content: View>: View {
    @Environment(\.lc) private var t
    let title: String?
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(t.textDisabled).frame(width: 36, height: 4).padding(.top, 7)
                if let title {
                    HStack {
                        Text(title)
                            .font(LCFont.semibold(15))
                            .foregroundStyle(t.text)
                        Spacer()
                        Button(action: close) {
                            LCIconView(icon: .chevronDown, size: 14, color: t.textLabel)
                                .frame(width: 40, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(LCPressStyle())
                        .accessibilityLabel("Close \(title)")
                    }
                    .padding(.leading, LCMetrics.sliderPadLeading)
                    .padding(.trailing, 8)
                    .frame(height: 32)
                } else {
                    Color.clear.frame(height: 7)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 12).onEnded { g in
                if g.translation.height > 40 { close() }
            })
            content()
        }
        .background(t.chrome, in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
    }
}

/// Profile, B&W, HDR: the Edit header's switches and the profile picker.
struct ProfileSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LCMetrics.editButtonsSpacing) {
                LCTextButton(title: "B&W", active: model.photo?.blackAndWhite ?? false) { model.edit("develop.treatment") }
                LCTextButton(title: "HDR", active: model.photo?.hdr ?? false) { model.edit("develop.hdr", ["enabled": !(model.photo?.hdr ?? false)]) }
                Spacer(minLength: 0)
                LCTextButton(title: "Reset") { model.edit("develop.reset") }
                    .disabled(!(model.photo?.edited ?? false))
            }
            .padding(.horizontal, LCMetrics.sliderPadLeading)
            .padding(.vertical, 8)
            ProfileRow(model: model)
        }
    }
}

extension View {
    /// Asks for previews at the pixel size of `size` (the engine picks the source level to decode).
    func sizesPreviews(_ model: AppModel, for size: CGSize) -> some View {
        modifier(PreviewSizing(model: model, size: size))
    }
}

private struct PreviewSizing: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    let model: AppModel
    let size: CGSize

    func body(content: Content) -> some View {
        content.onChange(of: size, initial: true) { _, size in
            let edge = UInt32(min(max(max(size.width, size.height) * displayScale, 512), 3072))
            if edge != model.previewEdge {
                model.previewEdge = edge
                model.requestRender(draft: false)
            }
        }
    }
}
