import SwiftUI

/// The desktop's window: top bar; the Grid or the Detail view (photo, filmstrip) with the bottom
/// bar; and in Detail the side panel (Edit, Presets, History) with its tool strip on the right, on
/// iPad and in landscape. On a phone held upright, Detail is `PhoneEditView`: the photo edge to edge,
/// with the controls in a compact sheet.
struct ContentView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var phase
    @Bindable var model: AppModel
    @Bindable var appearance: Appearance
    /// Detail with the photo alone: no side panel, tool strip or filmstrip (iPad and landscape).
    @AppStorage("detail.focus") private var focus = false

    var body: some View {
        let t = appearance.tokens(for: scheme)
        GeometryReader { geo in
            let side = geo.size.width >= 700 || geo.size.width > geo.size.height
            if !side && model.mode == .detail {
                PhoneEditView(model: model, appearance: appearance)
            } else {
                VStack(spacing: 0) {
                    TopBar(model: model, appearance: appearance, focus: side && model.mode == .detail ? $focus : nil)
                    PanelDivider()
                    if side {
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                main
                                BottomBar(model: model)
                            }
                            if model.mode == .detail && !focus {
                                PanelDivider().frame(width: 1, height: nil)
                                SidePanel(model: model)
                                    .frame(width: max(t.panelW, min(geo.size.width * 0.3, 360)))
                                    .transition(.move(edge: .trailing))
                                PanelDivider().frame(width: 1, height: nil)
                                ToolStrip(model: model)
                                    .transition(.move(edge: .trailing))
                            }
                        }
                        .animation(.snappy(duration: 0.3), value: focus)
                    } else {
                        LibraryGrid(model: model)
                        BottomBar(model: model)
                    }
                }
            }
        }
        .background(t.chrome)
        .environment(\.lc, t)
        .tint(t.accent)
        .preferredColorScheme(appearance.preferredScheme)
        .onChange(of: phase) { _, p in if p != .active { model.save() } }
        .alert("LightCraft", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder private var main: some View {
        if model.mode == .grid {
            LibraryGrid(model: model)
        } else {
            canvas
            if !focus { Filmstrip(model: model) }
        }
    }

    private var canvas: some View {
        PhotoCanvas(model: model, inset: 12, background: appearance.tokens(for: scheme).gridBg)
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                // previews at the canvas's pixel size: the engine picks the source level to decode
                let edge = UInt32(min(max(max(size.width, size.height) * displayScale, 512), 3072))
                if edge != model.previewEdge {
                    model.previewEdge = edge
                    model.requestRender(draft: false)
                }
            }
    }
}

/// The desktop's top bar (`top_bar_h`): Import on the left; Undo, Redo, Before/After, Appearance and
/// Export on the right, with the desktop's icons.
struct TopBar: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    @Bindable var appearance: Appearance
    /// Shows the photo alone (hides the panels) when set; nil where there is nothing to hide.
    var focus: Binding<Bool>?

    var body: some View {
        HStack(spacing: 4) {
            ImportMenu(model: model) { BarIcon(.plus) }
                .disabled(model.isBusy)
            if model.isBusy {
                ProgressView().controlSize(.small).tint(t.text).padding(.leading, 6)
            }
            Spacer()
            Button { model.undo() } label: { BarIcon(.undo) }
                .disabled(model.undoLabel == nil)
                .accessibilityLabel(model.undoLabel.map { "Undo \($0)" } ?? "Undo")
                .keyboardShortcut("z", modifiers: .command)
            Button { model.redo() } label: { BarIcon(.redo) }
                .disabled(model.redoLabel == nil)
                .accessibilityLabel(model.redoLabel.map { "Redo \($0)" } ?? "Redo")
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button { model.showingOriginal.toggle() } label: {
                BarIcon(.beforeAfter, active: model.showingOriginal)
            }
            .accessibilityLabel("Before and After")
            .accessibilityAddTraits(model.showingOriginal ? .isSelected : [])
            .disabled(model.activeID == nil || model.mode != .detail)
            appearanceMenu
            Button { Task { await model.exportToPhotos() } } label: { BarIcon(.share) }
                .accessibilityLabel("Export to Photos")
                .disabled(model.activeID == nil || model.isBusy)
            if let focus {
                Button { focus.wrappedValue.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 17))
                        .foregroundStyle(focus.wrappedValue ? t.icon : t.text)
                        .frame(width: 44, height: t.topBarH - 6)
                        .background(focus.wrappedValue ? .clear : t.toolActive, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(focus.wrappedValue ? "Show Panels" : "Hide Panels")
                .keyboardShortcut("\\", modifiers: .command)
            }
        }
        .buttonStyle(LCPressStyle())
        .padding(.horizontal, 8)
        .frame(height: t.topBarH)
        .background(t.chrome)
    }

    private var appearanceMenu: some View {
        Menu {
            Picker("Appearance", selection: $appearance.mode) {
                ForEach(AppearanceMode.allCases) { m in
                    Label(m.label, image: m.icon.rawValue).tag(m)
                }
            }
            Picker("Dark Theme", selection: $appearance.darkTheme) {
                ForEach(LCTokens.all.filter(\.isDark)) { Text($0.label).tag($0.id) }
            }
            Picker("Light Theme", selection: $appearance.lightTheme) {
                ForEach(LCTokens.all.filter { !$0.isDark }) { Text($0.label).tag($0.id) }
            }
        } label: {
            BarIcon(t.isDark ? .moon : .sun)
        }
        .accessibilityLabel("Appearance")
    }
}

/// A top-bar icon at the desktop's size, highlighted while its mode is on.
struct BarIcon: View {
    @Environment(\.lc) private var t
    @Environment(\.isEnabled) private var enabled
    let icon: LCIcon
    var active = false
    /// In the text colour rather than the icon colour (the phone's photo-first bar).
    var bright = false

    nonisolated init(_ icon: LCIcon, active: Bool = false, bright: Bool = false) {
        self.icon = icon
        self.active = active
        self.bright = bright
    }

    var body: some View {
        LCIconView(icon: icon, size: 20, color: active || (bright && enabled) ? t.text : enabled ? nil : t.textDisabled)
            .frame(width: 44, height: t.topBarH - 6)
            .background(active ? t.toolActive : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

/// The photo on the desktop canvas colour. Press and hold to see the "before" state; with an
/// eyedropper on, a tap samples the photo there.
struct PhotoCanvas: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    /// Margin around the photo.
    var inset: CGFloat = 16
    /// The canvas colour (the desktop canvas when nil).
    var background: Color?
    @State private var wasShowingOriginal = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background ?? t.canvas
                if let image = shown {
                    let frame = fitted(image, in: geo.size.insetBy(inset))
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX + inset, y: frame.midY + inset)
                        .accessibilityLabel(model.showingOriginal ? "Original photo" : "Edited photo")
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard model.tool != .none else { return }
                            let x = (location.x - inset - frame.minX) / frame.width
                            let y = (location.y - inset - frame.minY) / frame.height
                            guard (0...1).contains(x), (0...1).contains(y) else { return }
                            model.sample(x: x, y: y)
                        }
                        .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 30) {} onPressingChanged: { pressing in
                            guard model.tool == .none else { return }
                            if pressing {
                                wasShowingOriginal = model.showingOriginal
                                model.showingOriginal = true
                            } else {
                                model.showingOriginal = wasShowingOriginal
                            }
                        }
                } else if model.activeID == nil && !model.isBusy {
                    EmptyLibrary(model: model)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if model.tool != .none {
                chip(model.tool == .whiteBalance ? "Tap a neutral grey to set white balance" : "Tap a colour to sample it")
            } else if model.showingOriginal, model.preview != nil {
                chip("Before")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast { chip(toast).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .clipped()
    }

    private var shown: CGImage? {
        model.showingOriginal ? (model.original ?? model.preview) : model.preview
    }

    private func fitted(_ image: CGImage, in size: CGSize) -> CGRect {
        let s = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// The desktop's overlay label ("Preset: Warm Film" in the corner of the photo).
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(LCFont.medium(12.5))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            .padding(24)
    }
}

extension CGSize {
    func insetBy(_ d: CGFloat) -> CGSize { CGSize(width: max(width - 2 * d, 1), height: max(height - 2 * d, 1)) }
}
