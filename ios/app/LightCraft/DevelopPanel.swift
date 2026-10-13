import SwiftUI
import UIKit

/// The desktop's Edit panel: histogram, Edit header (Auto, B&W, HDR, Reset), Profile, then the
/// sections of `PanelLayout` (from the Rust side, which mirrors the desktop's `panels/edit.rs`).
/// Geometry and colours come from `LCTokens` / `LCMetrics` (generated from the desktop UI).
struct DevelopPanel: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HistogramView(histogram: model.histogram, capture: model.photo?.capture ?? "")
                EditHeader(model: model)
                PanelDivider()
                ProfileRow(model: model)
                PanelDivider()
                if let layout = model.layout {
                    ForEach(layout.sections) { section in
                        PanelSectionView(section: section, model: model)
                        PanelDivider()
                    }
                }
                Color.clear.frame(height: 40)
            }
            .disabled(model.photo == nil)
        }
        .scrollIndicators(.hidden)
        .background(t.chrome)
    }
}

struct PanelDivider: View {
    @Environment(\.lc) private var t
    var body: some View { t.divider.frame(height: 1) }
}

/// A sub-title inside a section ("Vignette", "Grain", "Manual"; `edit.rs` `sub_title`).
struct SubTitle: View {
    @Environment(\.lc) private var t
    let title: String
    var body: some View {
        Text(title)
            .font(LCFont.semibold(LCMetrics.subtitleFont))
            .foregroundStyle(t.textLabel)
            .frame(maxWidth: .infinity, minHeight: LCMetrics.subtitleHeight, alignment: .leading)
            .padding(.leading, LCMetrics.sliderPadLeading)
            .padding(.top, 8)
    }
}

// MARK: - histogram

/// The desktop histogram (`panels/edit.rs` `histogram`): smoothed R, G, B lines over a luminance
/// fill, square-root scale, clipping indicators, and the capture line under the plot.
struct HistogramView: View {
    @Environment(\.lc) private var t
    let histogram: Histogram?
    let capture: String

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(t.button))
            let plot = CGRect(x: 0, y: LCMetrics.histogramPlotTop, width: size.width,
                              height: size.height - LCMetrics.histogramPlotTop - LCMetrics.histogramPlotBottomInset)
            if let h = histogram { draw(h, in: plot, ctx: &ctx) }
        }
        .frame(height: LCMetrics.histogramHeight)
        .overlay(alignment: .bottom) {
            Text(capture)
                .font(LCFont.regular(LCMetrics.captureLineFont))
                .foregroundStyle(t.textLabel)
                .frame(height: LCMetrics.captureLineInset * 2)
        }
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(capture)
    }

    private func smooth(_ v: [UInt32]) -> [Double] {
        let r = Int(LCMetrics.histogramSmoothRadius)
        guard v.count >= 256 else { return Array(repeating: 0, count: 256) }
        return (0..<256).map { i in
            let a = max(i, r) - r, b = min(i + r + 1, 256)
            return v[a..<b].reduce(0.0) { $0 + Double($1) } / Double(b - a)
        }
    }

    private func draw(_ h: Histogram, in plot: CGRect, ctx: inout GraphicsContext) {
        let chans = [(smooth(h.r), LCMetrics.histogramRed), (smooth(h.g), LCMetrics.histogramGreen), (smooth(h.b), LCMetrics.histogramBlue)]
        let peak = chans.flatMap { $0.0.dropFirst(2).prefix(252) }.reduce(1.0, max)
        func pt(_ i: Int, _ v: Double) -> CGPoint {
            CGPoint(x: plot.minX + plot.width * CGFloat(i) / 255, y: plot.maxY - plot.height * CGFloat(min((v / peak).squareRoot(), 1)))
        }
        let lum = smooth(h.luma)
        var fill = Path()
        fill.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        for i in 0..<256 { fill.addLine(to: pt(i, lum[i])) }
        fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(Color(.sRGB, white: LCMetrics.histogramLumaGray / 255, opacity: LCMetrics.histogramLumaOpacity)))
        // greyscale images: the channels coincide, one neutral line
        let spread = (0..<256).reduce(0.0) { $0 + abs(chans[0].0[$1] - chans[1].0[$1]) + abs(chans[1].0[$1] - chans[2].0[$1]) }
        let total = max(chans[1].0.reduce(0, +), 1)
        let lines: [([Double], Color)] = spread / total < 0.02 ? [(chans[1].0, Color(.sRGB, white: 200 / 255))] : chans
        for (v, c) in lines {
            var p = Path()
            p.move(to: pt(0, v[0]))
            for i in 1..<256 { p.addLine(to: pt(i, v[i])) }
            ctx.stroke(p, with: .color(c), lineWidth: LCMetrics.histogramLineWidth)
        }
        for (clipped, x) in [(h.clippedShadows, plot.minX + LCMetrics.histogramClipInset), (h.clippedHighlights, plot.maxX - LCMetrics.histogramClipInset)] {
            let r = CGRect(x: x - 7, y: plot.minY + 4, width: 14, height: 12)
            ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Color(.sRGB, white: 60 / 255)))
            var icon = ctx.resolve(Image(lc: .chevronDown).renderingMode(.template))
            icon.shading = .color(Double(clipped) > LCMetrics.histogramClipThreshold ? .white : Color(.sRGB, white: 130 / 255))
            ctx.draw(icon, in: r.insetBy(dx: 2, dy: 1))
        }
    }
}

// MARK: - Edit header and Profile

/// "Edit" with the Auto / B&W / HDR / Reset buttons (`panels/edit.rs`).
struct EditHeader: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit")
                .font(LCFont.semibold(LCMetrics.editTitleFont))
                .foregroundStyle(t.text)
                .frame(height: LCMetrics.editHeaderHeight - LCMetrics.editTitleBaselineInset, alignment: .bottom)
                .padding(.leading, LCMetrics.sliderPadLeading)
            HStack(spacing: LCMetrics.editButtonsSpacing) {
                LCTextButton(title: "Auto") {
                    model.edit("develop.auto")
                    model.showToast("Auto settings applied")
                }
                LCTextButton(title: "B&W", active: model.photo?.blackAndWhite ?? false) { model.edit("develop.treatment") }
                LCTextButton(title: "HDR", active: model.photo?.hdr ?? false) { model.edit("develop.hdr", ["enabled": !(model.photo?.hdr ?? false)]) }
                Spacer(minLength: 0)
                LCTextButton(title: "Reset") { model.edit("develop.reset") }
                    .disabled(!(model.photo?.edited ?? false))
            }
            .padding(EdgeInsets(top: LCMetrics.editButtonsTop + LCMetrics.editTitleBaselineInset / 2, leading: LCMetrics.sliderPadLeading,
                                bottom: LCMetrics.editButtonsBottom, trailing: LCMetrics.sliderPadTrailing))
        }
    }
}

/// "Profile  Color ⌄" (`panels/edit.rs` `profile_menu`): favourites, then one submenu per group;
/// the Amount slider for every profile but the default.
struct ProfileRow: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Profile")
                    .font(LCFont.regular(13))
                    .foregroundStyle(t.textDim)
                Menu {
                    if let menu = model.profiles {
                        if !menu.favorites.isEmpty {
                            Section("Favorites") { ForEach(menu.favorites) { item($0) } }
                        }
                        ForEach(menu.groups) { g in
                            Menu(g.name) { ForEach(g.profiles) { item($0) } }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.photo?.profileName ?? "Color")
                            .font(LCFont.regular(15))
                            .foregroundStyle(t.textLabel)
                        LCIconView(icon: .chevronDown, size: 12, color: t.textLabel)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, LCMetrics.sliderPadLeading)
            .padding(.vertical, 14)
            if let amount = model.layout?.profile.amount, model.photo?.profileId != "lc.color", let c = model.controls[amount] {
                LCSlider(control: c, model: model)
                Color.clear.frame(height: 6)
            }
        }
    }

    private func item(_ p: ProfilesMenu.Profile) -> some View {
        Button {
            model.edit("develop.profile", ["id": p.id])
        } label: {
            if p.id == model.photo?.profileId { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
        }
    }
}

/// The desktop's small text button (`widgets.rs` `text_button`).
struct LCTextButton: View {
    @Environment(\.lc) private var t
    @Environment(\.isEnabled) private var enabled
    let title: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(LCFont.semibold(LCMetrics.buttonFont))
                .foregroundStyle(enabled ? t.text : t.textDisabled)
                .padding(.horizontal, LCMetrics.buttonPadding / 2)
                .frame(minWidth: LCMetrics.buttonMinWidth, minHeight: LCMetrics.buttonHeight)
                .background(active ? t.pressed : t.button, in: RoundedRectangle(cornerRadius: LCMetrics.buttonRadius))
                .overlay(RoundedRectangle(cornerRadius: LCMetrics.buttonRadius).strokeBorder(t.buttonBorder, lineWidth: 1))
                .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(LCPressStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Pressed feedback in the desktop's colours rather than iOS's default dimming.
struct LCPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The desktop's segmented control (`widgets.rs` `segmented`).
struct LCSegmented: View {
    @Environment(\.lc) private var t
    let items: [(label: String, key: String)]
    let selected: String?
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: LCMetrics.segmentGap) {
            ForEach(items, id: \.key) { item in
                Button { pick(item.key) } label: {
                    Text(item.label)
                        .font(LCFont.semibold(LCMetrics.buttonFont))
                        .foregroundStyle(t.text)
                        .frame(maxWidth: .infinity, minHeight: LCMetrics.segmentHeight)
                        .background(item.key == selected ? t.pressed : t.button, in: RoundedRectangle(cornerRadius: LCMetrics.buttonRadius))
                        .overlay(RoundedRectangle(cornerRadius: LCMetrics.buttonRadius).strokeBorder(t.buttonBorder))
                }
                .buttonStyle(LCPressStyle())
                .accessibilityAddTraits(item.key == selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, LCMetrics.sliderPadLeading)
        .padding(.vertical, 4)
    }
}

// MARK: - sections

/// A collapsible section ("› Light") and its rows. Open/closed is remembered, as on desktop.
struct PanelSectionView: View {
    @Environment(\.lc) private var t
    let section: PanelSectionLayout
    @Bindable var model: AppModel
    @AppStorage private var open: Bool

    init(section: PanelSectionLayout, model: AppModel) {
        self.section = section
        self.model = model
        _open = AppStorage(wrappedValue: section.id == "light" || section.id == "color", "section.\(section.id).open")
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                ZStack(alignment: .leading) {
                    Color.clear
                    LCIconView(icon: open ? .chevronDown : .chevronRight, size: LCMetrics.sectionChevronSize, color: t.textLabel)
                        .position(x: LCMetrics.sectionChevronX, y: LCMetrics.sectionHeaderHeight / 2)
                    Text(section.title)
                        .font(LCFont.semibold(LCMetrics.sectionTitleFont))
                        .foregroundStyle(t.text)
                        .padding(.leading, LCMetrics.sectionTitleX)
                }
                .frame(height: LCMetrics.sectionHeaderHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section.title)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                LayoutItems(items: section.items, model: model)
                Color.clear.frame(height: 8)
            }
        }
    }
}

/// The rows of a section or flyout.
struct LayoutItems: View {
    let items: [LayoutItem]
    @Bindable var model: AppModel

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            LayoutItemView(item: item, model: model)
        }
    }
}

struct LayoutItemView: View {
    @Environment(\.lc) private var t
    let item: LayoutItem
    @Bindable var model: AppModel

    var body: some View {
        switch item.kind {
        case "control":
            if let id = item.id, let c = model.controls[id] {
                LCSlider(control: c, model: model)
                    .disabled(item.enabledWhenNonZero.map { model.value($0) == 0 } ?? false)
            }
        case "subtitle":
            SubTitle(title: item.title ?? "")
        case "space":
            Color.clear.frame(height: 6)
        case "flyout":
            if !(item.onlyWhenHdr ?? false) || (model.photo?.hdr ?? false) {
                Flyout(item: item, model: model)
            }
        case "hdrRow":
            if model.photo?.hdr ?? false, let id = item.control, let c = model.controls[id] {
                LCSlider(control: c, model: model)
            }
        case "whiteBalance":
            WhiteBalanceRow(model: model)
        case "curve":
            CurveEditor(model: model, parametric: item.parametric ?? [])
        case "mixer":
            MixerEditor(model: model)
        case "pointColor":
            PointColorEditor(model: model)
        case "grading":
            GradingEditor(model: model)
        case "vignetteStyle":
            if let styles = model.layout?.vignetteStyles {
                LCSegmented(items: styles.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil },
                            selected: model.settings.string("vignette.style")) { key in
                    model.edit("develop.merge", ["settings": ["vignette": ["style": key]]])
                }
            }
        case "toggle":
            if let path = item.settings {
                LCToggleRow(title: item.title ?? "", on: model.settings.bool(path)) { on in
                    model.edit("develop.merge", ["settings": nestedJSON(path, on), "label": item.label ?? item.title ?? ""])
                }
            }
        case "lensProfile":
            if model.settings.bool("optics.lens_profile") {
                if !(model.photo?.hasLens ?? false) {
                    Note(text: "No lens data embedded in this file (DNG lens opcodes only).")
                }
                ForEach(item.controls ?? [], id: \.self) { id in
                    if let c = model.controls[id] {
                        LCSlider(control: c, model: model).disabled(!(model.photo?.hasLens ?? false))
                    }
                }
            }
        case "denoise":
            Note(text: model.photo?.denoiseApplicable ?? false
                 ? "AI Denoise isn't available on iOS yet: denoise this raw in the desktop app."
                 : "AI Denoise works on raw photos.")
            if let id = item.control, let c = model.controls[id] {
                LCSlider(control: c, model: model).disabled(true)
            }
        default:
            // a kind added upstream that this app doesn't draw yet
            EmptyView()
        }
    }
}

/// A short dim note under a control (`text_dim`, as the desktop's hints).
struct Note: View {
    @Environment(\.lc) private var t
    let text: String
    var body: some View {
        Text(text)
            .font(LCFont.regular(11.5))
            .foregroundStyle(t.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LCMetrics.sliderPadLeading)
            .padding(.vertical, 4)
    }
}

/// A checkbox row (Remove Chromatic Aberration, Enable Lens Corrections).
struct LCToggleRow: View {
    @Environment(\.lc) private var t
    let title: String
    let on: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button { set(!on) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(on ? t.accent : t.field)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? t.accent : t.fieldBorder))
                    .overlay { if on { LCIconView(icon: .check, size: 12, color: .white) } }
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(LCFont.regular(LCMetrics.sliderFont))
                    .foregroundStyle(t.textLabel)
                Spacer()
            }
            .padding(.horizontal, LCMetrics.sliderPadLeading)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// A flyout row (`widgets.rs` `flyout_row`): an inset box with an icon tile; opens its rows below.
struct Flyout: View {
    @Environment(\.lc) private var t
    let item: LayoutItem
    @Bindable var model: AppModel
    @AppStorage private var open: Bool

    init(item: LayoutItem, model: AppModel) {
        self.item = item
        self.model = model
        _open = AppStorage(wrappedValue: false, "flyout.\(item.id ?? "").open")
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                let h = LCMetrics.flyoutHeight - LCMetrics.flyoutInsetY * 2
                HStack(spacing: LCMetrics.flyoutTitleGap) {
                    RoundedRectangle(cornerRadius: LCMetrics.flyoutTileRadius)
                        .fill(t.chrome.opacity(1))
                        .brightness(t.isDark ? 0.04 : -0.04)
                        .overlay { LCIconView(icon: LCIcon(rawValue: "lc.\(item.icon ?? "sliders")") ?? .sliders, size: h - LCMetrics.flyoutTileInset * 2 - 6, color: t.textLabel) }
                        .frame(width: h - LCMetrics.flyoutTileInset * 2, height: h - LCMetrics.flyoutTileInset * 2)
                    Text(title)
                        .font(LCFont.semibold(LCMetrics.flyoutTitleFont))
                        .foregroundStyle(t.textLabel)
                    Spacer()
                    LCIconView(icon: open ? .chevronDown : .triangleLeft, size: 12, color: t.textLabel)
                        .padding(.trailing, 8)
                }
                .padding(.leading, LCMetrics.flyoutTileInset)
                .frame(height: h)
                .background(t.inset, in: RoundedRectangle(cornerRadius: LCMetrics.flyoutRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, LCMetrics.flyoutInsetX)
            .padding(.vertical, LCMetrics.flyoutInsetY)
            .accessibilityLabel(title)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open, let items = item.items {
                LayoutItems(items: items, model: model)
            }
        }
    }

    /// The mixer's title follows B&W, as on desktop.
    private var title: String {
        item.id == "mixer" && (model.photo?.blackAndWhite ?? false) ? "B&W Mixer" : (item.title ?? "")
    }
}

/// "White Balance  As Shot ⌄" with the eyedropper (`panels/edit.rs`).
struct WhiteBalanceRow: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel

    var body: some View {
        HStack {
            Text("White Balance")
                .font(LCFont.regular(13))
                .foregroundStyle(t.textDim)
            Menu {
                ForEach(model.whiteBalanceModes, id: \.id) { m in
                    Button(m.label) { model.edit("develop.wb", ["mode": m.id]) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.photo?.wbModeLabel ?? "As Shot")
                        .font(LCFont.regular(14))
                        .foregroundStyle(t.textLabel)
                    LCIconView(icon: .chevronDown, size: 12, color: t.textLabel)
                }
            }
            Spacer()
            PickerButton(active: model.tool == .whiteBalance, label: "White Balance Selector") {
                model.tool = model.tool == .whiteBalance ? .none : .whiteBalance
            }
        }
        .padding(.horizontal, LCMetrics.sliderPadLeading)
        .padding(.vertical, 2)
    }
}

/// The eyedropper button: while on, a tap on the photo samples it.
struct PickerButton: View {
    @Environment(\.lc) private var t
    let active: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LCIconView(icon: .picker, size: 18, color: active ? t.text : t.icon)
                .frame(width: 32, height: 28)
                .background(active ? t.toolActive : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - slider

/// The desktop slider row (`widgets.rs` `slider`): label and value above a thin track with a hollow
/// ring thumb. Same gestures as desktop, translated to touch:
/// - drag anywhere on the row to move the value (relative, so a touch never jumps it), one undo step;
/// - double-tap to reset (desktop: double-click the label or thumb);
/// - tap the value to type one (desktop: click the value).
struct LCSlider: View {
    @Environment(\.lc) private var t
    @Environment(\.isEnabled) private var enabled
    let control: ControlInfo
    @Bindable var model: AppModel

    @State private var dragStart: Double?
    @State private var horizontal: Bool?
    @State private var typing = false
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool
    private let haptics = UISelectionFeedbackGenerator()

    private var rel: Bool { model.relativeWB }
    private var value: Double { model.controls[control.id]?.value ?? control.value }
    private var shown: String { (try? formatValue(id: control.id, value: value, relativeWb: rel)) ?? "" }

    var body: some View {
        GeometryReader { geo in
            let trackWidth = max(geo.size.width - LCMetrics.sliderPadLeading - LCMetrics.sliderPadTrailing, 1)
            let pos = CGFloat((try? controlPosition(id: control.id, value: value, relativeWb: rel)) ?? 0.5)
            ZStack(alignment: .topLeading) {
                HStack {
                    Text(control.label)
                    Spacer()
                    if typing {
                        TextField("", text: $typed)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($fieldFocused)
                            .frame(width: 64)
                            .onSubmit(commitTyped)
                    } else {
                        Text(shown)
                            .monospacedDigit()
                            .onTapGesture { startTyping() }
                            .accessibilityHidden(true)
                    }
                }
                .font(LCFont.regular(LCMetrics.sliderFont))
                .foregroundStyle(enabled ? t.textLabel : t.textDisabled)
                .frame(height: LCMetrics.sliderLabelHeight)
                .padding(.top, LCMetrics.sliderLabelTop)
                .padding(.leading, LCMetrics.sliderPadLeading)
                .padding(.trailing, LCMetrics.sliderPadTrailing)

                track(width: trackWidth, position: pos)
                    .offset(x: LCMetrics.sliderPadLeading,
                            y: (LCMetrics.sliderTrackTop + LCMetrics.sliderTrackBottom) / 2 - LCMetrics.sliderRing - LCMetrics.sliderRingStroke)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .simultaneousGesture(drag(trackWidth: trackWidth), including: enabled ? .all : .subviews)
            .onTapGesture(count: 2) { if enabled { reset() } }
        }
        .frame(height: t.sliderRowH)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(control.label)
        .accessibilityValue(shown)
        .accessibilityAdjustableAction { direction in
            let steps: Double = direction == .increment ? 1 : -1
            if let v = try? nudgeValue(id: control.id, value: value, steps: steps, relativeWb: rel) { model.setValue(control.id, v) }
        }
        .accessibilityAction(named: "Reset") { reset() }
        .onChange(of: fieldFocused) { _, focused in if !focused && typing { commitTyped() } }
    }

    private func track(width: CGFloat, position: CGFloat) -> some View {
        let ring = LCMetrics.sliderRing
        let lineH = control.trackStops.isEmpty ? LCMetrics.trackHalfThickness * 2 : LCMetrics.trackHalfThickness * 2 + 1
        let x = width * position
        return ZStack(alignment: .leading) {
            Group {
                if control.trackStops.isEmpty {
                    RoundedRectangle(cornerRadius: 1).fill(t.track)
                } else {
                    Rectangle().fill(LinearGradient(colors: control.trackStops.map(Color.init(lcHexString:)), startPoint: .leading, endPoint: .trailing))
                }
            }
            .frame(width: width, height: lineH)
            .opacity(enabled ? 1 : 0.5)
            Rectangle().fill(t.chrome)
                .frame(width: ring * 2 + LCMetrics.thumbGapExtra, height: 6)
                .offset(x: x - ring - LCMetrics.thumbGapExtra / 2)
            Circle()
                .fill(t.chrome)
                .overlay(Circle().stroke(enabled ? (dragStart != nil ? t.thumbHover : t.thumb) : t.textDisabled, lineWidth: LCMetrics.sliderRingStroke))
                .frame(width: ring * 2, height: ring * 2)
                .offset(x: x - ring)
        }
        .frame(width: width, height: (ring + LCMetrics.sliderRingStroke) * 2)
    }

    private func drag(trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { g in
                // a mostly vertical drag scrolls the panel instead
                if horizontal == nil { horizontal = abs(g.translation.width) > abs(g.translation.height) }
                guard horizontal == true else { return }
                if dragStart == nil {
                    dragStart = (try? controlPosition(id: control.id, value: value, relativeWb: rel)) ?? 0.5
                    model.beginDrag(control.label)
                    haptics.prepare()
                }
                let p = (dragStart ?? 0.5) + Double(g.translation.width / trackWidth)
                guard let v = try? controlValueAt(id: control.id, position: min(max(p, 0), 1), relativeWb: rel) else { return }
                let old = value
                // a tick when crossing the default, as iOS sliders do at detents
                if (old - control.default) * (v - control.default) <= 0 && v != old { haptics.selectionChanged() }
                model.setValue(control.id, v)
            }
            .onEnded { _ in
                if dragStart != nil { model.endDrag() }
                dragStart = nil
                horizontal = nil
            }
    }

    private func reset() {
        model.setValue(control.id, control.default)
        haptics.selectionChanged()
    }

    private func startTyping() {
        guard enabled else { return }
        typed = shown.hasPrefix("+") ? String(shown.dropFirst()) : shown
        typing = true
        fieldFocused = true
    }

    private func commitTyped() {
        if let v = (try? parseTypedValue(id: control.id, text: typed, relativeWb: rel)) ?? nil { model.setValue(control.id, v) }
        typing = false
    }
}

extension Color {
    /// `#rrggbb` or `#rrggbbaa` (the control specs' track colours).
    init(lcHexString s: String) {
        let hex = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(hex, radix: 16) ?? 0x808080
        if hex.count == 8 {
            self.init(lcHex: v >> 8, alpha: Double(v & 0xff) / 255)
        } else {
            self.init(lcHex: v)
        }
    }
}
