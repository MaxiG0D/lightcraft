import SwiftUI
import UIKit

// The Edit panel's special editors, as the desktop draws them in `panels/edit.rs`: the Curve
// (parametric and point curves), the Color Mixer / B&W Mixer, Point Color and Color Grading.
// Every change is the desktop's command (`develop.curve`, `develop.set`, `pointColor.delete`, …).

// MARK: - Curve

struct CurveEditor: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    let parametric: [String]
    @AppStorage("curve.channel") private var channel = "parametric"
    @State private var info: CurveInfo?
    /// The points while a point is dragged (shown before the engine has them).
    @State private var dragPoints: [CGPoint]?
    @State private var dragIndex: Int?
    @State private var panelWidth: CGFloat = 320
    /// The graph is the panel's width less the slider insets, as on desktop (`w - 48`).
    private var graphSide: CGFloat { max(panelWidth - LCMetrics.sliderPadLeading * 2, 80) }

    private static let channels: [(key: String, name: String)] = [
        ("parametric", "Parametric curve"), ("master", "Point curve"), ("red", "Red channel"), ("green", "Green channel"), ("blue", "Blue channel"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            channelRow
            graph(side: graphSide)
                .frame(width: graphSide, height: graphSide)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(GeometryReader { geo in
                    Color.clear.onAppear { panelWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in panelWidth = w }
                })
            footer
            if channel == "parametric" {
                ForEach(parametric, id: \.self) { id in
                    if let c = model.controls[id] { LCSlider(control: c, model: model) }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.revision) { _, _ in reload() }
        .onChange(of: channel) { _, _ in reload() }
    }

    private func reload() {
        info = model.curve(channel)
    }

    private func color(_ ch: String) -> Color {
        switch ch {
        case "red": LCMetrics.curveRed
        case "green": LCMetrics.curveGreen
        case "blue": LCMetrics.curveBlue
        default: Color(.sRGB, white: 225 / 255)
        }
    }

    private var channelRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.channels, id: \.key) { ch in
                let selected = channel == ch.key
                ZStack {
                    if ch.key == "parametric" {
                        LCIconView(icon: .curve, size: 16, color: selected ? t.text : t.icon)
                    } else {
                        Circle().stroke(color(ch.key), lineWidth: 2).frame(width: 14, height: 14)
                        if selected { Circle().fill(color(ch.key)).frame(width: 7, height: 7) }
                    }
                }
                .frame(width: 30, height: 30)
                .overlay(alignment: .bottom) {
                    if selected { t.text.frame(width: 18, height: 2) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    channel = ch.key
                    model.edit("curve.reset", ["channel": ch.key])
                }
                .onTapGesture { channel = ch.key }
                .accessibilityElement()
                .accessibilityLabel(ch.name)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint("Double-tap twice quickly to reset it")
            }
            Spacer()
        }
        .padding(.horizontal, LCMetrics.sliderPadLeading)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var points: [CGPoint] {
        if let dragPoints { return dragPoints }
        let v = info?.points ?? []
        return stride(from: 0, to: v.count - 1, by: 2).map { CGPoint(x: v[$0], y: v[$0 + 1]) }
    }

    private func graph(side: CGFloat) -> some View {
        let pts = points
        let samples = info?.samples ?? []
        return Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(t.canvas))
            // the photo's histogram behind the curve
            if let h = model.histogram {
                let bins = channel == "red" ? h.r : channel == "green" ? h.g : channel == "blue" ? h.b : h.luma
                let peak = Double(bins.dropFirst(2).prefix(252).max() ?? 1)
                var p = Path()
                p.move(to: CGPoint(x: 0, y: r.maxY))
                for (i, v) in bins.enumerated() {
                    p.addLine(to: CGPoint(x: r.width * CGFloat(i) / 255, y: r.maxY - r.height * CGFloat(min((Double(v) / max(peak, 1)).squareRoot(), 1)) * 0.9))
                }
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                ctx.fill(p, with: .color(Color(.sRGB, white: 0.5, opacity: 0.18)))
            }
            for i in 1..<4 {
                let f = CGFloat(i) / 4
                var g = Path()
                g.move(to: CGPoint(x: r.width * f, y: 0)); g.addLine(to: CGPoint(x: r.width * f, y: r.height))
                g.move(to: CGPoint(x: 0, y: r.height * f)); g.addLine(to: CGPoint(x: r.width, y: r.height * f))
                ctx.stroke(g, with: .color(Color(.sRGB, white: 52 / 255)), lineWidth: 1)
            }
            var diag = Path()
            diag.move(to: CGPoint(x: 0, y: r.height)); diag.addLine(to: CGPoint(x: r.width, y: 0))
            ctx.stroke(diag, with: .color(Color(.sRGB, white: 70 / 255)), lineWidth: 1)
            if samples.count > 1 && dragPoints == nil {
                var c = Path()
                for (i, y) in samples.enumerated() {
                    let q = CGPoint(x: r.width * CGFloat(i) / CGFloat(samples.count - 1), y: r.height * (1 - y))
                    if i == 0 { c.move(to: q) } else { c.addLine(to: q) }
                }
                ctx.stroke(c, with: .color(channel == "parametric" ? Color(.sRGB, white: 220 / 255) : color(channel)), lineWidth: 2)
            } else if dragPoints != nil {
                // while dragging: straight segments until the engine's curve comes back
                var c = Path()
                for (i, q) in pts.enumerated() {
                    let s = CGPoint(x: q.x * r.width, y: (1 - q.y) * r.height)
                    if i == 0 { c.move(to: s) } else { c.addLine(to: s) }
                }
                ctx.stroke(c, with: .color(color(channel)), lineWidth: 2)
            }
            if channel != "parametric" {
                for (i, q) in pts.enumerated() {
                    let s = CGPoint(x: q.x * r.width, y: (1 - q.y) * r.height)
                    let dot = Path(ellipseIn: CGRect(x: s.x - 4.5, y: s.y - 4.5, width: 9, height: 9))
                    ctx.fill(dot, with: .color(i == dragIndex ? .white : t.canvas))
                    ctx.stroke(dot, with: .color(.white), lineWidth: 1.5)
                }
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(channel == "parametric" ? nil : pointDrag(side: side))
        .simultaneousGesture(channel == "parametric" ? nil : SpatialTapGesture(count: 2).onEnded { e in removePoint(at: e.location, side: side) })
        .accessibilityLabel(channel == "parametric" ? "Parametric curve" : "Point curve")
    }

    private func normalized(_ p: CGPoint, side: CGFloat) -> CGPoint {
        CGPoint(x: min(max(p.x / side, 0), 1), y: min(max(1 - p.y / side, 0), 1))
    }

    private func nearest(_ p: CGPoint, side: CGFloat) -> Int? {
        let pts = points
        let hit = pts.indices.min { hypot(pts[$0].x * side - p.x, (1 - pts[$0].y) * side - p.y) < hypot(pts[$1].x * side - p.x, (1 - pts[$1].y) * side - p.y) }
        guard let hit, hypot(pts[hit].x * side - p.x, (1 - pts[hit].y) * side - p.y) < 22 else { return nil }
        return hit
    }

    /// Drag a point (between its neighbours); drag empty space to add a point there and drag it.
    private func pointDrag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragPoints == nil {
                    var pts = points
                    if let i = nearest(g.startLocation, side: side) {
                        dragIndex = i
                    } else {
                        let q = normalized(g.startLocation, side: side)
                        let i = pts.firstIndex { $0.x > q.x } ?? pts.count
                        pts.insert(q, at: i)
                        dragIndex = i
                    }
                    dragPoints = pts
                    model.beginDrag("Tone Curve")
                }
                guard var pts = dragPoints, let i = dragIndex else { return }
                var q = normalized(g.location, side: side)
                let lo = i > 0 ? pts[i - 1].x + 0.01 : 0
                let hi = i < pts.count - 1 ? pts[i + 1].x - 0.01 : 1
                q.x = min(max(q.x, lo), max(lo, hi))
                pts[i] = q
                dragPoints = pts
                model.setCurve(channel, pts)
            }
            .onEnded { _ in
                dragPoints = nil
                dragIndex = nil
                model.endDrag()
            }
    }

    /// Double-tap a point to delete it (the curve keeps at least two).
    private func removePoint(at location: CGPoint, side: CGFloat) {
        var pts = points
        guard pts.count > 2, let i = nearest(location, side: side) else { return }
        pts.remove(at: i)
        model.setCurve(channel, pts)
    }

    private var footer: some View {
        HStack {
            Text("Point Curve")
                .font(LCFont.regular(12))
                .foregroundStyle(t.textLabel)
            Menu {
                ForEach(info?.presets ?? [], id: \.self) { name in
                    Button(name) { model.edit("curve.applyPreset", ["name": name]) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(info?.preset ?? "Custom")
                        .font(LCFont.regular(12))
                        .foregroundStyle(t.text)
                    LCIconView(icon: .chevronDown, size: 10, color: t.textLabel)
                }
            }
            Spacer()
            LCTextButton(title: "Reset") { model.edit("curve.reset") }
        }
        .padding(.horizontal, LCMetrics.sliderPadLeading)
        .padding(.bottom, 6)
    }
}

// MARK: - Color Mixer / B&W Mixer

struct MixerEditor: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    @AppStorage("mixer.band") private var band = "red"

    var body: some View {
        let layout = model.layout?.mixer
        let bands = layout?.bands ?? []
        let bw = model.photo?.blackAndWhite ?? false
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(bands, id: \.self) { b in
                    let selected = b == band
                    Circle()
                        .fill(bandColor(b))
                        .frame(width: 18, height: 18)
                        .overlay { if selected { Circle().fill(.white).frame(width: 4, height: 4) } }
                        .overlay { if selected { Circle().stroke(t.text, lineWidth: 1.5).frame(width: 21, height: 21) } }
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                        .onTapGesture { band = b }
                        .accessibilityLabel(b.capitalized)
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
                Spacer()
            }
            .padding(.horizontal, LCMetrics.sliderPadLeading - 4)
            .padding(.top, 8)
            if bw {
                HStack {
                    LCTextButton(title: "Auto") { model.edit("develop.autoBwMix") }
                    Spacer()
                }
                .padding(.horizontal, LCMetrics.sliderPadLeading)
                .padding(.vertical, 4)
                if let c = model.controls["\(layout?.bwPrefix ?? "bw").\(band)"] { LCSlider(control: c, model: model) }
            } else {
                ForEach(layout?.parts ?? [], id: \.self) { part in
                    if let c = model.controls["mixer.\(band).\(part)"] { LCSlider(control: c, model: model) }
                }
            }
        }
    }

    /// The band's colour: the end of its saturation track (`BAND_COLORS`).
    private func bandColor(_ b: String) -> Color {
        model.controls["mixer.\(b).sat"]?.trackStops.last.map(Color.init(lcHexString:)) ?? .gray
    }
}

// MARK: - Point Color

struct PointColorEditor: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    @State private var selected = 0

    var body: some View {
        let swatches = model.photo?.pointColors ?? []
        let sel = min(selected, max(swatches.count - 1, 0))
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                PickerButton(active: model.tool == .pointColor, label: "Sample a colour on the photo") {
                    model.tool = model.tool == .pointColor ? .none : .pointColor
                }
                .disabled(swatches.count >= 8)
                ForEach(Array(swatches.enumerated()), id: \.offset) { i, hex in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(lcHexString: hex))
                        .frame(width: 18, height: 18)
                        .overlay { if i == sel { RoundedRectangle(cornerRadius: 4).stroke(t.text, lineWidth: 1.5).frame(width: 22, height: 22) } }
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = i }
                        .accessibilityLabel("Sample \(i + 1)")
                }
                Spacer()
            }
            .padding(.horizontal, LCMetrics.sliderPadLeading - 4)
            .padding(.top, 8)
            if swatches.isEmpty {
                Note(text: model.tool == .pointColor ? "Tap the photo to sample a colour." : "Pick a colour on the photo with the eyedropper.")
                    .padding(.bottom, 8)
            } else if let layout = model.layout?.pointColor {
                ForEach(layout.parts, id: \.self) { k in
                    if let c = model.controls["pointColor.\(sel).\(k)"] { LCSlider(control: c, model: model) }
                }
                SubTitle(title: "Range")
                ForEach(layout.range, id: \.self) { k in
                    if let c = model.controls["pointColor.\(sel).\(k)"] { LCSlider(control: c, model: model) }
                }
                HStack {
                    Spacer()
                    LCTextButton(title: "Delete") { model.edit("pointColor.delete", ["index": sel]) }
                }
                .padding(.horizontal, LCMetrics.sliderPadLeading)
                .padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Color Grading

struct GradingEditor: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    @AppStorage("grading.mode") private var mode = "3way"

    var body: some View {
        let layout = model.layout?.grading
        let tabs = model.layout?.gradingTabs ?? []
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.self) { tab in
                    let (key, title, icon) = (tab[0], tab[1], tab.count > 2 ? tab[2] : "gradeAll")
                    Button { mode = key } label: {
                        LCIconView(icon: LCIcon(rawValue: "lc.\(icon)") ?? .gradeAll, size: 18, color: key == mode ? t.text : t.icon)
                            .frame(width: 32, height: 28)
                            .background(key == mode ? t.toolActive : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(key == mode ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, LCMetrics.sliderPadLeading)
            .padding(.top, 6)
            if mode == "3way" {
                GeometryReader { geo in
                    let w = geo.size.width
                    let zones = layout?.zones ?? []
                    let at = [CGPoint(x: w * 0.28, y: 196), CGPoint(x: w / 2, y: 70), CGPoint(x: w * 0.72, y: 196)]
                    ForEach(Array(zones.enumerated()), id: \.offset) { i, zone in
                        if i < at.count {
                            GradingWheel(model: model, zone: zone, radius: 40, readout: true).position(at[i])
                        }
                    }
                }
                .frame(height: 276)
                ForEach(layout?.threeWay ?? [], id: \.self) { id in
                    if let c = model.controls[id] { LCSlider(control: c, model: model) }
                }
            } else {
                GeometryReader { geo in
                    let rad = min(max(geo.size.width * 0.3, 40), 80)
                    GradingWheel(model: model, zone: mode, radius: rad, readout: false).position(x: geo.size.width / 2, y: rad + 10)
                }
                .frame(height: 200)
                ForEach(layout?.parts ?? [], id: \.self) { part in
                    if let c = model.controls["grading.\(mode).\(part)"] { LCSlider(control: c, model: model) }
                }
            }
            ForEach(layout?.shared ?? [], id: \.self) { id in
                if let c = model.controls[id] { LCSlider(control: c, model: model) }
            }
        }
    }
}

/// A colour wheel: drag to set the zone's hue (angle, counter-clockwise from the right, as on
/// desktop) and saturation (distance); double-tap to reset.
struct GradingWheel: View {
    @Environment(\.lc) private var t
    @Bindable var model: AppModel
    let zone: String
    let radius: CGFloat
    let readout: Bool

    private var hue: Double { model.value("grading.\(zone).hue") }
    private var sat: Double { model.value("grading.\(zone).sat") }

    var body: some View {
        let a = hue * .pi / 180
        let dot = CGPoint(x: radius + cos(a) * radius * sat / 100, y: radius - sin(a) * radius * sat / 100)
        VStack(spacing: 4) {
            ZStack {
                // hues counter-clockwise from the right: AngularGradient runs clockwise, so reversed
                Circle().fill(AngularGradient(colors: stride(from: 360.0, through: 0, by: -30).map { Color(hue: $0 / 360, saturation: 0.75, brightness: 0.85) }, center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.55).opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                Circle().fill(.white).frame(width: 4, height: 4)
                Circle().fill(.white).overlay(Circle().stroke(.black, lineWidth: 1)).frame(width: 10, height: 10)
                    .position(dot)
            }
            .frame(width: radius * 2, height: radius * 2)
            .contentShape(Circle())
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    model.beginDrag("\(zone.capitalized) Grading")
                    let dx = g.location.x - radius, dy = radius - g.location.y
                    var h = atan2(dy, dx) * 180 / .pi
                    if h < 0 { h += 360 }
                    let s = min(hypot(dx, dy) / radius, 1) * 100
                    model.setValues(["grading.\(zone).hue": h.rounded(), "grading.\(zone).sat": s.rounded()])
                }
                .onEnded { _ in model.endDrag() })
            .onTapGesture(count: 2) { model.setValues(["grading.\(zone).hue": 0, "grading.\(zone).sat": 0]) }
            Text(readout ? "\(zone.capitalized)  H \(Int(hue))°  S \(Int(sat))" : zone.capitalized)
                .font(LCFont.regular(12))
                .foregroundStyle(t.textLabel)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(zone.capitalized) wheel")
        .accessibilityValue("Hue \(Int(hue)) degrees, saturation \(Int(sat))")
    }
}
