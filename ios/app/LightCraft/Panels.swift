import SwiftUI

/// The desktop's Presets panel: groups (B&W, Color, Film…) that open and close; tap a preset to
/// apply it (`preset.apply`, one undo step).
struct PresetsPanel: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    @AppStorage("presets.closed") private var closedGroups = ""

    private var groups: [(name: String, presets: [PresetItem])] {
        var order: [String] = []
        var by: [String: [PresetItem]] = [:]
        for p in model.presets {
            if by[p.group] == nil { order.append(p.group) }
            by[p.group, default: []].append(p)
        }
        let favorites = model.presets.filter(\.favorite)
        return (favorites.isEmpty ? [] : [("Favorites", favorites)]) + order.map { ($0, by[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelTitle(title: "Presets")
                ForEach(groups, id: \.name) { g in
                    let open = !closedGroups.split(separator: "|").contains(Substring(g.name))
                    Button { toggle(g.name) } label: {
                        HStack(spacing: 8) {
                            LCIconView(icon: open ? .chevronDown : .chevronRight, size: 12, color: t.textLabel)
                            Text(g.name)
                                .font(LCFont.semibold(14))
                                .foregroundStyle(t.text)
                            Spacer()
                        }
                        .padding(.horizontal, 22)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(open ? "Expanded" : "Collapsed")
                    if open {
                        ForEach(g.presets) { p in
                            Button { model.applyPreset(p) } label: {
                                Text(p.name)
                                    .font(LCFont.regular(14))
                                    .foregroundStyle(t.textLabel)
                                    .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
                                    .padding(.leading, 46)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PresetRowStyle())
                            .disabled(model.activeID == nil)
                            .contextMenu {
                                Button(p.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: p.favorite ? "star.slash" : "star") {
                                    model.run("preset.favorite", ["id": p.id, "favorite": !p.favorite])
                                    model.reloadPresets()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(t.chrome)
    }

    private func toggle(_ name: String) {
        var closed = Set(closedGroups.split(separator: "|").map(String.init))
        if closed.contains(name) { closed.remove(name) } else { closed.insert(name) }
        closedGroups = closed.sorted().joined(separator: "|")
    }
}

/// A row that highlights while pressed (the desktop's hover row).
struct PresetRowStyle: ButtonStyle {
    @Environment(\.lc) private var t
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? t.hover : .clear)
    }
}

/// The desktop's History panel: every step of the active photo, newest first; tap one to go back
/// to it (`history.restore`). Later steps stay listed until a new edit, as on desktop.
struct HistoryPanel: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelTitle(title: "History") {
                    LCTextButton(title: "Clear") { model.edit("history.clear") }
                        .disabled((model.history?.history.count ?? 0) < 2)
                }
                let steps = model.history?.history ?? []
                let cursor = model.history?.cursor ?? (steps.count - 1)
                if steps.isEmpty {
                    Note(text: model.activeID == nil ? "Open a photo to see its history." : "No edits yet.")
                }
                ForEach(Array(steps.enumerated().reversed()), id: \.offset) { i, label in
                    Button { model.edit("history.restore", ["index": i]) } label: {
                        Text(label)
                            .font(LCFont.regular(13.5))
                            .foregroundStyle(i > cursor ? t.textDim : t.textLabel)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .padding(.leading, 24)
                            .background(i == cursor ? t.cellSelected : .clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PresetRowStyle())
                    .accessibilityAddTraits(i == cursor ? .isSelected : [])
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(t.chrome)
    }
}

struct PanelTitle<Trailing: View>: View {
    @Environment(\.lc) private var t
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(LCFont.semibold(LCMetrics.editTitleFont))
                .foregroundStyle(t.text)
            Spacer()
            trailing()
        }
        .padding(.horizontal, LCMetrics.sliderPadLeading)
        .frame(height: 52)
    }
}

extension PanelTitle where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// The desktop's tool strip on the right edge: one icon per panel.
struct ToolStrip: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    var vertical = true

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            ForEach(AppModel.Panel.allCases) { p in
                Button { model.panel = p } label: {
                    LCIconView(icon: p.icon, size: 20, color: model.panel == p ? t.text : nil)
                        .frame(width: 40, height: 40)
                        .background(model.panel == p ? t.toolActive : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(LCPressStyle())
                .accessibilityLabel(p.title)
                .accessibilityAddTraits(model.panel == p ? .isSelected : [])
            }
            if vertical { Spacer() }
        }
        .padding(vertical ? .vertical : .horizontal, 8)
        .frame(width: vertical ? t.stripW : nil)
        .frame(maxWidth: vertical ? nil : .infinity)
        .background(t.chrome)
    }
}

/// The selected panel (Edit, Presets or History).
struct SidePanel: View {
    @Bindable var model: AppModel
    var body: some View {
        switch model.panel {
        case .edit: DevelopPanel(model: model)
        case .presets: PresetsPanel(model: model)
        case .history: HistoryPanel(model: model)
        }
    }
}
