//! Generates the iOS app's design layer from the desktop UI crate, so the two apps look alike and a
//! pull from upstream carries design changes over by itself:
//!
//! - `Theme.generated.swift`: every desktop theme's colours and metrics (`ui_egui::theme::Tokens`),
//!   plus the layout numbers the desktop keeps as literals in its widget code ([`MIRRORS`]);
//! - `Icons.xcassets`: the desktop's own icons (`ui_egui::icons`, drawn in code), painted with egui
//!   and written as vector SVG template images, and the app icon (`assets/app-icon`).
//!
//! Each mirrored literal names the upstream line it copies. `gen-theme` fails when one of those
//! lines no longer exists upstream (and `--check` only checks), so a design change upstream can't
//! leave the iOS app silently behind: update the value here (and in `lightcraft-ffi` for the Rust
//! mirrors) and the line it cites.
//!
//! Usage: `gen-theme <repo root> <output dir>` or `gen-theme --check <repo root>`.

#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use egui::epaint::{ColorMode, Shape};
use egui::{Color32, Pos2, Rect, vec2};
use lightcraft_ui_egui::icons::{self, Icon};
use lightcraft_ui_egui::theme::{ThemeKind, Tokens};

/// A value copied from upstream source, and the upstream line that proves it is still current.
struct Mirror {
    /// Swift constant name in `LCMetrics` (None: mirrored in Rust, in `lightcraft-ffi`).
    swift: Option<&'static str>,
    value: f64,
    file: &'static str,
    line: &'static str,
}

const WIDGETS: &str = "crates/ui-egui/src/widgets.rs";
const EDIT: &str = "crates/ui-egui/src/panels/edit.rs";
const ENGINE_DEVELOP: &str = "crates/engine/src/cmd/develop.rs";
const UI_LIB: &str = "crates/ui-egui/src/lib.rs";
const DETAIL: &str = "crates/ui-egui/src/panels/detail.rs";
const APP_ICON_README: &str = "assets/app-icon/README.md";
/// The desktop's 1024 px app icon (a rounded tile); iOS masks its own corners.
const APP_ICON: &str = "assets/app-icon/lightcraft-1024.png";
/// The icon's field colour, filled into the tile's transparent corners.
const APP_ICON_FIELD: [u8; 3] = [0xf2, 0xa5, 0x16];

const fn m(swift: &'static str, value: f64, file: &'static str, line: &'static str) -> Mirror {
    Mirror { swift: Some(swift), value, file, line }
}
const fn rust(file: &'static str, line: &'static str) -> Mirror {
    Mirror { swift: None, value: 0.0, file, line }
}

const MIRRORS: &[Mirror] = &[
    // slider row (widgets.rs `slider`)
    m("sliderPadLeading", 24.0, WIDGETS, "let pad_l = 24.0;"),
    m("sliderPadTrailing", 22.0, WIDGETS, "let pad_r = 22.0;"),
    m("sliderLabelTop", 4.0, WIDGETS, "pos2(row.left() + pad_l, row.top() + 4.0), vec2(w - pad_l - pad_r, 18.0)"),
    m("sliderLabelHeight", 18.0, WIDGETS, "pos2(row.left() + pad_l, row.top() + 4.0), vec2(w - pad_l - pad_r, 18.0)"),
    m("sliderTrackTop", 22.0, WIDGETS, "pos2(row.left() + pad_l, row.top() + 22.0), pos2(row.right() - pad_r, row.top() + 40.0)"),
    m("sliderTrackBottom", 40.0, WIDGETS, "pos2(row.left() + pad_l, row.top() + 22.0), pos2(row.right() - pad_r, row.top() + 40.0)"),
    m("sliderFont", 12.5, WIDGETS, "label_override.unwrap_or(spec.label)), t.font(12.5), text_c)"),
    m("sliderRing", 7.0, WIDGETS, "let ring = 7.0;"),
    m("sliderRingStroke", 2.0, WIDGETS, "p.circle_stroke(pos2(tx, track_rect.center().y), ring, Stroke::new(2.0, ring_c));"),
    m("trackHalfThickness", 1.0, WIDGETS, "let h = 1.0;"),
    m("thumbGapExtra", 4.0, WIDGETS, "vec2(ring * 2.0 + 4.0, 6.0)"),
    // section header (widgets.rs `section_header`)
    m("sectionHeaderHeight", 52.0, WIDGETS, "ui.allocate_exact_size(vec2(w, 52.0), Sense::click())"),
    m("sectionChevronX", 30.0, WIDGETS, "pos2(r.left() + 30.0, r.center().y), vec2(14.0, 14.0)"),
    m("sectionChevronSize", 14.0, WIDGETS, "pos2(r.left() + 30.0, r.center().y), vec2(14.0, 14.0)"),
    m("sectionTitleX", 44.0, WIDGETS, "p.text(pos2(r.left() + 44.0, r.center().y), Align2::LEFT_CENTER, title, t.semibold(14.0), t.text);"),
    m("sectionTitleFont", 14.0, WIDGETS, "p.text(pos2(r.left() + 44.0, r.center().y), Align2::LEFT_CENTER, title, t.semibold(14.0), t.text);"),
    // text buttons (widgets.rs `text_button`)
    m("buttonFont", 11.5, WIDGETS, "let font = t.semibold(11.5);"),
    m("buttonPadding", 18.0, WIDGETS, "let size = vec2((galley.size().x + 18.0).max(37.0), 24.0);"),
    m("buttonMinWidth", 37.0, WIDGETS, "let size = vec2((galley.size().x + 18.0).max(37.0), 24.0);"),
    m("buttonHeight", 24.0, WIDGETS, "let size = vec2((galley.size().x + 18.0).max(37.0), 24.0);"),
    m("buttonRadius", 4.0, WIDGETS, "p.rect(r, CornerRadius::same(4), fill, Stroke::new(1.0, t.button_border), StrokeKind::Inside);"),
    // flyout rows (widgets.rs `flyout_row`): Curve, Color Mixer, Defringe…
    m("flyoutHeight", 40.0, WIDGETS, "let (outer, _) = ui.allocate_exact_size(vec2(w, 40.0), Sense::hover());"),
    m(
        "flyoutInsetX",
        16.0,
        WIDGETS,
        "let r = Rect::from_min_max(pos2(outer.left() + 16.0, outer.top() + 4.0), pos2(outer.right() - 16.0, outer.bottom() - 4.0));",
    ),
    m(
        "flyoutInsetY",
        4.0,
        WIDGETS,
        "let r = Rect::from_min_max(pos2(outer.left() + 16.0, outer.top() + 4.0), pos2(outer.right() - 16.0, outer.bottom() - 4.0));",
    ),
    m("flyoutRadius", 4.0, WIDGETS, "p.rect_filled(r, 4.0, if resp.hovered() { t.hover.gamma_multiply(0.8) } else { t.inset });"),
    m(
        "flyoutTileInset",
        4.0,
        WIDGETS,
        "let tile = Rect::from_min_size(pos2(r.left() + 4.0, r.top() + 4.0), vec2(r.height() - 8.0, r.height() - 8.0));",
    ),
    m("flyoutTileRadius", 3.0, WIDGETS, "p.rect_filled(tile, 3.0, t.chrome.gamma_multiply(1.15));"),
    m("flyoutTileBrightness", 1.15, WIDGETS, "p.rect_filled(tile, 3.0, t.chrome.gamma_multiply(1.15));"),
    m(
        "flyoutTitleGap",
        10.0,
        WIDGETS,
        "p.text(pos2(tile.right() + 10.0, r.center().y), Align2::LEFT_CENTER, title, t.semibold(13.0), t.text_label);",
    ),
    m(
        "flyoutTitleFont",
        13.0,
        WIDGETS,
        "p.text(pos2(tile.right() + 10.0, r.center().y), Align2::LEFT_CENTER, title, t.semibold(13.0), t.text_label);",
    ),
    // sub-titles (edit.rs `sub_title`) and segmented controls (widgets.rs `segmented`)
    m("subtitleHeight", 30.0, EDIT, "let (r, _) = ui.allocate_exact_size(vec2(ui.available_width(), 30.0), Sense::hover());"),
    m(
        "subtitleFont",
        13.0,
        EDIT,
        "ui.painter().text(pos2(r.left() + 24.0, r.center().y + 4.0), Align2::LEFT_CENTER, crate::i18n::tr(title), t.semibold(13.0), t.text_label);",
    ),
    m("segmentGap", 4.0, WIDGETS, "let gap = 4.0;"),
    m("segmentHeight", 24.0, WIDGETS, "let (r, resp) = ui.allocate_exact_size(vec2(seg_w, 24.0), Sense::click());"),
    // filmstrip (detail.rs `filmstrip`)
    m("filmTopStrip", 4.0, DETAIL, "ui.painter().rect_filled(Rect::from_min_size(r.min, vec2(r.width(), 4.0)), 0.0, Color32::from_gray(0x20));"),
    m(
        "filmNameFont",
        10.0,
        DETAIL,
        "p.text(pos2(cr.left() + 8.0, cr.top() + 10.0), Align2::LEFT_CENTER, film_label(name), t.font(10.0), t.text_dim);",
    ),
    m(
        "filmFormatFont",
        8.5,
        DETAIL,
        "p.text(pos2(cr.right() - 8.0, cr.top() + 10.0), Align2::RIGHT_CENTER, &ph.format, t.semibold(8.5), t.text_dim);",
    ),
    m("filmImageInsetSide", 10.0, DETAIL, "let img_area = Rect::from_min_max(cr.min + vec2(10.0, 22.0), cr.max - vec2(10.0, 8.0));"),
    m("filmImageInsetTop", 22.0, DETAIL, "let img_area = Rect::from_min_max(cr.min + vec2(10.0, 22.0), cr.max - vec2(10.0, 8.0));"),
    m("filmImageInsetBottom", 8.0, DETAIL, "let img_area = Rect::from_min_max(cr.min + vec2(10.0, 22.0), cr.max - vec2(10.0, 8.0));"),
    m("filmSelectedStroke", 1.5, DETAIL, "p.rect_stroke(fr, 0.0, Stroke::new(1.5, Color32::WHITE), StrokeKind::Outside);"),
    // grading wheel (edit.rs `grading_wheel`): hue counter-clockwise from the right
    rust(EDIT, "let dot = c + vec2(a.cos(), -a.sin()) * rad * (wh.sat as f32 / 100.0);"),
    // Edit header (edit.rs `show`)
    m("editHeaderHeight", 40.0, EDIT, "let (hr, _) = ui.allocate_exact_size(vec2(ui.available_width(), 40.0), Sense::hover());"),
    m("editTitleFont", 15.0, EDIT, "crate::i18n::tr(\"Edit\"), t.semibold(15.0), t.text);"),
    m("editTitleBaselineInset", 10.0, EDIT, "ui.painter().text(pos2(hr.left() + 24.0, hr.bottom() - 10.0)"),
    m("editButtonsTop", 8.0, EDIT, "egui::Frame::NONE.inner_margin(egui::Margin { left: 24, right: 22, top: 8, bottom: 14 }).show(ui, |ui| {"),
    m("editButtonsBottom", 14.0, EDIT, "egui::Frame::NONE.inner_margin(egui::Margin { left: 24, right: 22, top: 8, bottom: 14 }).show(ui, |ui| {"),
    m("editButtonsSpacing", 8.0, EDIT, "ui.spacing_mut().item_spacing.x = 8.0;"),
    // histogram (edit.rs `histogram`)
    m("histogramHeight", 118.0, EDIT, "let (r, resp) = ui.allocate_exact_size(vec2(w, 118.0 + legend), Sense::click());"),
    m("histogramPlotTop", 6.0, EDIT, "let plot = Rect::from_min_max(r.min + vec2(0.0, 6.0), pos2(r.right(), r.bottom() - 26.0 - legend));"),
    m("histogramPlotBottomInset", 26.0, EDIT, "let plot = Rect::from_min_max(r.min + vec2(0.0, 6.0), pos2(r.right(), r.bottom() - 26.0 - legend));"),
    m("histogramSmoothRadius", 2.0, EDIT, "let (a, b) = (i.max(2) - 2, (i + 3).min(256));"),
    m("histogramLineWidth", 1.5, EDIT, "p.add(egui::Shape::line(pts, Stroke::new(1.5, *c)));"),
    m("histogramLumaGray", 120.0, EDIT, "Color32::from_gray(120).gamma_multiply(0.35)"),
    m("histogramLumaOpacity", 0.35, EDIT, "Color32::from_gray(120).gamma_multiply(0.35)"),
    m("histogramClipThreshold", 0.003, EDIT, "(lo > 0.003, plot.left() + 12.0, app.ui.show_clipping)"),
    m("histogramClipInset", 12.0, EDIT, "(lo > 0.003, plot.left() + 12.0, app.ui.show_clipping)"),
    m("captureLineInset", 13.0, EDIT, "let y = r.bottom() - 13.0;"),
    m("captureLineFont", 12.5, EDIT, "p.text(pos2(x, y), Align2::CENTER_CENTER, text, t.font(12.5), t.text_label);"),
    // histogram channel colours, as 0xRRGGBB
    m(
        "histogramRed",
        0xdf3939 as f64,
        EDIT,
        "let chans = [(smooth(&h.r), hex(\"#df3939\")), (smooth(&h.g), hex(\"#44b072\")), (smooth(&h.b), hex(\"#3b6fe0\"))];",
    ),
    m(
        "histogramGreen",
        0x44b072 as f64,
        EDIT,
        "let chans = [(smooth(&h.r), hex(\"#df3939\")), (smooth(&h.g), hex(\"#44b072\")), (smooth(&h.b), hex(\"#3b6fe0\"))];",
    ),
    m(
        "histogramBlue",
        0x3b6fe0 as f64,
        EDIT,
        "let chans = [(smooth(&h.r), hex(\"#df3939\")), (smooth(&h.g), hex(\"#44b072\")), (smooth(&h.b), hex(\"#3b6fe0\"))];",
    ),
    // Rust mirrors in lightcraft-ffi/src/controls.rs and lib.rs
    rust(
        EDIT,
        "id: \"wb.tempRel\",\n    label: \"Temp\",\n    section: Section::Color,\n    min: -100.0,\n    max: 100.0,\n    default: 0.0,\n    step: 1.0,\n    decimals: 0,\n    track: Track::Temp,",
    ),
    rust(
        EDIT,
        "id: \"wb.tintRel\",\n    label: \"Tint\",\n    section: Section::Color,\n    min: -100.0,\n    max: 100.0,\n    default: 0.0,\n    step: 1.0,\n    decimals: 0,\n    track: Track::Tint,",
    ),
    rust(EDIT, "((1e6 / 6500.0 - 1e6 / k) / 0.8).clamp(-100.0, 100.0)"),
    rust(EDIT, "1e6 / (1e6 / 6500.0 - r * 0.8)"),
    rust(WIDGETS, "Track::Temp => [\"#193961\", \"#47566a\", \"#60666d\", \"#70705b\", \"#737339\", \"#75742a\"]"),
    rust(WIDGETS, "Track::Tint => [\"#246123\", \"#2c552c\", \"#394739\", \"#4a3d4c\", \"#6b336b\", \"#872c87\"]"),
    rust(
        WIDGETS,
        "let shown = if spec.id == \"wb.temp\" { format!(\"{v:.0}\") } else { spec.format(v).replace(\"+0.00\", \"0\").replace(\"-0.00\", \"0\") };",
    ),
    rust(WIDGETS, "let unit = if spec.id == \"wb.temp\" { 50.0 } else { (((spec.max - spec.min) / 200.0 / step).round().max(1.0)) * step };"),
    rust(WIDGETS, "let t = t.trim_end_matches(|c: char| c == '%' || c == 'K' || c == 'k' || c.is_whitespace());"),
    rust(
        ENGINE_DEVELOP,
        "d.light.exposure = a.exposure;\n                d.light.contrast = a.contrast;\n                d.light.highlights = a.highlights;\n                d.light.shadows = a.shadows;\n                d.light.whites = a.whites;\n                d.light.blacks = a.blacks;\n                d.color.vibrance = a.vibrance;\n                d.color.saturation = a.saturation;",
    ),
    rust(ENGINE_DEVELOP, "d.treatment = if bw { Treatment::Bw } else { Treatment::Color };"),
    // lightcraft-ffi lib.rs: which photos show Kelvin sliders, `is_bw`, the capture line
    rust(EDIT, "let raw = app.session.catalog.photo(id).is_some_and(|p| p.develops_raw() && !p.relative_wb());"),
    rust(UI_LIB, "d.treatment == lightcraft_develop::Treatment::Bw || d.profile.id == \"lc.mono\" || d.profile.id.starts_with(\"lc.bw.\")"),
    rust(
        EDIT,
        "m.iso.map(|i| format!(\"ISO {i}\")),\n            m.focal_mm.map(|f| format!(\"{f:.0}mm\")),\n            m.aperture.map(|a| format!(\"f/{a:.1}\")),",
    ),
    // lightcraft-ffi controls.rs: the mixer / grading tracks
    rust(
        WIDGETS,
        "pub const BAND_COLORS: [&str; 8] = [\"#aa0000\", \"#bb6600\", \"#aaaa00\", \"#009900\", \"#00aaaa\", \"#0044cc\", \"#7722aa\", \"#aa0077\"];",
    ),
    rust(
        WIDGETS,
        "                prev.gamma_multiply(0.7),\n                lerp(prev, me, 0.5).gamma_multiply(0.7),\n                me.gamma_multiply(0.7),\n                lerp(me, next, 0.5).gamma_multiply(0.7),\n                next.gamma_multiply(0.7),",
    ),
    rust(
        WIDGETS,
        "Track::Sat { band } => vec![hex(\"#454343\"), lerp(hex(\"#454343\"), hex(BAND_COLORS[*band as usize]), 0.6), hex(BAND_COLORS[*band as usize])],",
    ),
    rust(WIDGETS, "vec![c.gamma_multiply(0.2), c.gamma_multiply(0.55), lerp(c, Color32::WHITE, 0.35), lerp(c, Color32::WHITE, 0.6)]"),
    rust(WIDGETS, "Track::Rainbow => [\"#aa0000\", \"#aaaa00\", \"#009900\", \"#00aaaa\", \"#0044cc\", \"#aa0077\", \"#aa0000\"]"),
    // lightcraft-ffi panel.rs `vignetteStyles`, `gradingTabs`; lib.rs `oklch_color`
    rust(
        EDIT,
        "(V::HighlightPriority, \"Highlight\", \"highlightPriority\"),\n                (V::ColorPriority, \"Color\", \"colorPriority\"),\n                (V::PaintOverlay, \"Paint\", \"paintOverlay\"),",
    ),
    rust(
        EDIT,
        "(\"3way\", \"3-Way\", Icon::GradeAll),\n    (\"shadows\", \"Shadows\", Icon::GradeShadows),\n    (\"midtones\", \"Midtones\", Icon::GradeMidtones),\n    (\"highlights\", \"Highlights\", Icon::GradeHighlights),",
    ),
    rust(EDIT, "let lin = oklab_to_2020(lch_to_lab([l as f32, c as f32, (h_deg as f32).to_radians()]));"),
    // lightcraft-ffi lib.rs `curve`: the parametric curve as the desktop draws it, the identity's points
    rust(EDIT, "let (ctr, half) = ((a + b) / 2.0, (b - a) * 0.75 + 0.05);"),
    rust(EDIT, "dd += amt / 100.0 * 0.22 * (0.5 + 0.5 * (tt * std::f64::consts::PI).cos());"),
    rust(EDIT, "to_screen(x, (x + dd * 4.0 * x * (1.0 - x)).clamp(0.0, 1.0))"),
    rust(EDIT, "if v.is_empty() { vec![Point::new(0.0, 0.0), Point::new(1.0, 1.0)] } else { v.clone() }"),
    rust(EDIT, "let curve = lightcraft_color::spline::MonotoneCurve::new(&pts.iter().map(|q| (q.x, q.y)).collect::<Vec<_>>());"),
    // the curve channels' colours (Swift `CurveEditor`)
    m(
        "curveRed",
        0xdd3333 as f64,
        EDIT,
        "\"red\" => hex(\"#dd3333\"),\n        \"green\" => hex(\"#33bb55\"),\n        \"blue\" => hex(\"#3377ee\"),",
    ),
    m(
        "curveGreen",
        0x33bb55 as f64,
        EDIT,
        "\"red\" => hex(\"#dd3333\"),\n        \"green\" => hex(\"#33bb55\"),\n        \"blue\" => hex(\"#3377ee\"),",
    ),
    m(
        "curveBlue",
        0x3377ee as f64,
        EDIT,
        "\"red\" => hex(\"#dd3333\"),\n        \"green\" => hex(\"#33bb55\"),\n        \"blue\" => hex(\"#3377ee\"),",
    ),
    // lightcraft-ffi panel.rs: the special editors' control families, as the desktop panel builds their ids
    rust(EDIT, "control(app, ui, d, &format!(\"mixer.{b}.{k}\"), true);"),
    rust(EDIT, "control(app, ui, d, &format!(\"bw.{b}\"), true);"),
    rust(EDIT, "control(app, ui, d, &format!(\"grading.{mode}.{part}\"), true);"),
    rust(EDIT, "for k in [\"hueShift\", \"satShift\", \"lumShift\", \"variance\"] {"),
    rust(EDIT, "for k in [\"range\", \"hueRange\", \"satRange\", \"lumRange\"] {"),
    rust(
        EDIT,
        "control(app, ui, d, &format!(\"calibration.{k}Hue\"), true);\n            control(app, ui, d, &format!(\"calibration.{k}Sat\"), true);",
    ),
    rust(EDIT, "for (title, k) in [(\"Red Primary\", \"red\"), (\"Green Primary\", \"green\"), (\"Blue Primary\", \"blue\")] {"),
    // the app icon's field colour (APP_ICON_FIELD)
    rust(APP_ICON_README, "| LightCraft amber | `#f2a516` | the full-bleed field (the app colour) |"),
];

/// The desktop icons the app uses: (asset name, icon).
const ICONS: &[(&str, Icon)] = &[
    ("lc.share", Icon::Share),
    ("lc.photos", Icon::Photos),
    ("lc.plus", Icon::Plus),
    ("lc.sliders", Icon::Sliders),
    ("lc.presets", Icon::Presets),
    ("lc.clock", Icon::Clock),
    ("lc.beforeAfter", Icon::BeforeAfter),
    ("lc.chevronDown", Icon::ChevronDown),
    ("lc.chevronRight", Icon::ChevronRight),
    ("lc.chevronLeft", Icon::ChevronLeft),
    ("lc.triangleLeft", Icon::TriangleLeft),
    ("lc.info", Icon::Info),
    ("lc.moon", Icon::Moon),
    ("lc.sun", Icon::Sun),
    ("lc.monitor", Icon::Monitor),
    ("lc.close", Icon::Close),
    ("lc.check", Icon::Check),
    ("lc.curve", Icon::Curve),
    ("lc.radial", Icon::Radial),
    ("lc.picker", Icon::Picker),
    ("lc.profileGrid", Icon::ProfileGrid),
    ("lc.gridPhoto", Icon::GridPhoto),
    ("lc.single", Icon::Single),
    ("lc.star", Icon::Star),
    ("lc.starFilled", Icon::StarFilled),
    ("lc.flagPick", Icon::FlagPick),
    ("lc.flagReject", Icon::FlagReject),
    ("lc.target", Icon::Target),
    ("lc.gradeAll", Icon::GradeAll),
    ("lc.gradeShadows", Icon::GradeShadows),
    ("lc.gradeMidtones", Icon::GradeMidtones),
    ("lc.gradeHighlights", Icon::GradeHighlights),
    ("lc.undo", Icon::Back),
    ("lc.redo", Icon::Forward),
    ("lc.dots", Icon::Dots),
];

/// The develop control ids `edit.rs` names as string literals (what the desktop panel shows), and the
/// families it builds with `format!` (mixer bands, grading zones, point colours, calibration).
fn desktop_panel_controls(edit_rs: &str) -> Vec<String> {
    let mut ids: Vec<String> = edit_rs
        .split('"')
        .skip(1)
        .step_by(2)
        .filter(|s| s.contains('.') && lightcraft_develop::controls::find(s).is_some())
        .map(str::to_string)
        .collect();
    // `calibration.{k}Hue` / `{k}Sat` for the three primaries (checked as a MIRROR line)
    for k in ["red", "green", "blue"] {
        ids.push(format!("calibration.{k}Hue"));
        ids.push(format!("calibration.{k}Sat"));
    }
    ids.sort();
    ids.dedup();
    ids
}

/// Every slider of the desktop's Edit panel has a place in the iOS layout (`lightcraft-ffi`
/// `panel.rs`), and the iOS layout places nothing the desktop panel no longer shows.
fn check_panel(repo: &Path) -> Result<(), String> {
    let edit = std::fs::read_to_string(repo.join(EDIT)).map_err(|e| format!("{EDIT}: {e}"))?;
    let desktop = desktop_panel_controls(&edit);
    let ios = lightcraft_ffi::placed_controls();
    let missing: Vec<&String> = desktop.iter().filter(|id| !ios.contains(id)).collect();
    let extra: Vec<&String> = ios.iter().filter(|id| !desktop.contains(id)).collect();
    if missing.is_empty() && extra.is_empty() {
        return Ok(());
    }
    Err(format!(
        "the desktop Edit panel ({EDIT}) changed; update ios/lightcraft-ffi/src/panel.rs:\n  shown on desktop, not placed on iOS: {missing:?}\n  placed on iOS, no longer on desktop: {extra:?}"
    ))
}

fn check(repo: &Path) -> Result<(), String> {
    check_panel(repo)?;
    let mut stale = Vec::new();
    for mi in MIRRORS {
        let src = std::fs::read_to_string(repo.join(mi.file)).map_err(|e| format!("{}: {e}", mi.file))?;
        if !src.contains(mi.line) {
            stale.push(format!(
                "  {} ({}): no longer contains\n      {}",
                mi.swift.unwrap_or("lightcraft-ffi mirror"),
                mi.file,
                mi.line.replace('\n', "\n      ")
            ));
        }
    }
    if stale.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "upstream design code changed; update the iOS mirrors in ios/tools/gen-theme/src/main.rs (and lightcraft-ffi where noted):\n{}",
            stale.join("\n")
        ))
    }
}

fn hex(c: Color32) -> String {
    let [r, g, b, a] = c.to_srgba_unmultiplied();
    if a == 255 { format!("0x{r:02x}{g:02x}{b:02x}") } else { format!("0x{r:02x}{g:02x}{b:02x}, alpha: {:.3}", a as f32 / 255.0) }
}

fn swift_name(snake: &str) -> String {
    let mut out = String::new();
    for (i, part) in snake.split('_').enumerate() {
        let mut ch = part.chars();
        if let Some(f) = ch.next() {
            if i == 0 {
                out.push(f);
            } else {
                out.extend(f.to_uppercase());
            }
            out.push_str(ch.as_str());
        }
    }
    out
}

/// `Tokens`' fields, by name. Listed here so a token added upstream that isn't listed fails to
/// reach Swift loudly: the `Tokens { .. }` destructuring below stops compiling.
type TokenFields = (Vec<(&'static str, Color32)>, Vec<(&'static str, f32)>);

fn token_fields(t: &Tokens) -> TokenFields {
    let Tokens {
        chrome,
        canvas,
        grid_bg,
        cell,
        cell_selected,
        divider,
        inset,
        field,
        field_border,
        button,
        button_border,
        hover,
        pressed,
        tool_active,
        text,
        text_label,
        text_dim,
        text_disabled,
        icon,
        track,
        thumb,
        thumb_hover,
        accent,
        star,
        pick,
        reject,
        caution,
        mask_overlay,
        top_bar_h,
        bottom_bar_h,
        panel_w,
        strip_w,
        slider_row_h,
        section_h,
        film_h,
    } = *t;
    (
        vec![
            ("chrome", chrome),
            ("canvas", canvas),
            ("grid_bg", grid_bg),
            ("cell", cell),
            ("cell_selected", cell_selected),
            ("divider", divider),
            ("inset", inset),
            ("field", field),
            ("field_border", field_border),
            ("button", button),
            ("button_border", button_border),
            ("hover", hover),
            ("pressed", pressed),
            ("tool_active", tool_active),
            ("text", text),
            ("text_label", text_label),
            ("text_dim", text_dim),
            ("text_disabled", text_disabled),
            ("icon", icon),
            ("track", track),
            ("thumb", thumb),
            ("thumb_hover", thumb_hover),
            ("accent", accent),
            ("star", star),
            ("pick", pick),
            ("reject", reject),
            ("caution", caution),
            ("mask_overlay", mask_overlay),
        ],
        vec![
            ("top_bar_h", top_bar_h),
            ("bottom_bar_h", bottom_bar_h),
            ("panel_w", panel_w),
            ("strip_w", strip_w),
            ("slider_row_h", slider_row_h),
            ("section_h", section_h),
            ("film_h", film_h),
        ],
    )
}

fn theme_swift() -> String {
    let mut s = String::new();
    let _ = writeln!(s, "// Generated by ios/tools/gen-theme from crates/ui-egui (theme.rs, widgets.rs, panels/edit.rs).");
    let _ = writeln!(s, "// Do not edit: run ios/build-xcframework.sh.\n");
    let _ = writeln!(s, "import SwiftUI\n");
    let base = Tokens::default();
    let (colors, metrics) = token_fields(&base);
    let _ = writeln!(s, "/// The desktop app's design tokens (`Tokens`) for one theme.");
    let _ = writeln!(s, "struct LCTokens: Sendable, Identifiable {{");
    let _ = writeln!(s, "    let id: String\n    let label: String\n    let isDark: Bool");
    for (name, _) in &colors {
        let _ = writeln!(s, "    let {}: Color", swift_name(name));
    }
    for (name, _) in &metrics {
        let _ = writeln!(s, "    let {}: CGFloat", swift_name(name));
    }
    let _ = writeln!(s);
    for kind in ThemeKind::ALL {
        let t = Tokens::for_kind(kind);
        let (colors, metrics) = token_fields(&t);
        let _ = writeln!(s, "    static let {} = LCTokens(", kind.id());
        let _ = writeln!(s, "        id: \"{}\", label: \"{}\", isDark: {},", kind.id(), kind.label(), kind.is_dark());
        let mut fields: Vec<String> = colors.iter().map(|(n, c)| format!("        {}: Color(lcHex: {})", swift_name(n), hex(*c))).collect();
        fields.extend(metrics.iter().map(|(n, v)| format!("        {}: {v:?}", swift_name(n))));
        let _ = writeln!(s, "{}\n    )\n", fields.join(",\n"));
    }
    let all: Vec<&str> = ThemeKind::ALL.iter().map(|k| k.id()).collect();
    let _ = writeln!(s, "    static let all: [LCTokens] = [{}]", all.iter().map(|k| format!(".{k}")).collect::<Vec<_>>().join(", "));
    let _ = writeln!(s, "}}\n");
    let _ = writeln!(s, "/// Layout numbers the desktop keeps as literals in its widget code, each checked against its upstream line.");
    let _ = writeln!(s, "enum LCMetrics {{");
    for mi in MIRRORS {
        if let Some(name) = mi.swift {
            let cited: Vec<&str> = mi.line.lines().map(str::trim).collect();
            let _ = writeln!(s, "    /// {} — `{}`", mi.file, cited.join(" "));
            if (name.starts_with("histogram") || name.starts_with("curve")) && ["Red", "Green", "Blue"].iter().any(|c| name.ends_with(c)) {
                let _ = writeln!(s, "    static let {name} = Color(lcHex: 0x{:06x})", mi.value as u32);
            } else {
                let _ = writeln!(s, "    static let {name}: CGFloat = {:?}", mi.value);
            }
        }
    }
    let _ = writeln!(s, "}}\n");
    let _ = writeln!(s, "/// The desktop's icons (crates/ui-egui/src/icons.rs), as template images in Icons.xcassets.");
    let _ = writeln!(s, "enum LCIcon: String, CaseIterable {{");
    for (name, _) in ICONS {
        let _ = writeln!(s, "    case {} = \"{name}\"", name.trim_start_matches("lc."));
    }
    let _ = writeln!(s, "}}\n");
    let _ = writeln!(s, "extension Color {{");
    let _ = writeln!(s, "    init(lcHex v: UInt32, alpha: Double = 1) {{");
    let _ = writeln!(
        s,
        "        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255, opacity: alpha)"
    );
    let _ = writeln!(s, "    }}\n}}");
    s
}

fn f(v: f32) -> String {
    let r = (v * 1000.0).round() / 1000.0;
    format!("{r}")
}

fn points(pts: &[Pos2]) -> String {
    pts.iter().map(|p| format!("{},{}", f(p.x), f(p.y))).collect::<Vec<_>>().join(" ")
}

fn fill_attr(c: Color32) -> String {
    if c.a() == 0 { "fill=\"none\"".into() } else { "fill=\"#000\"".into() }
}

fn shape_svg(shape: &Shape, out: &mut String) {
    match shape {
        Shape::Vec(v) => v.iter().for_each(|s| shape_svg(s, out)),
        Shape::Path(p) => {
            let tag = if p.closed { "polygon" } else { "polyline" };
            let stroke = match p.stroke.color {
                ColorMode::Solid(c) if c.a() > 0 && p.stroke.width > 0.0 => format!(" stroke=\"#000\" stroke-width=\"{}\"", f(p.stroke.width)),
                _ => String::new(),
            };
            let _ = writeln!(out, "  <{tag} points=\"{}\" {}{stroke}/>", points(&p.points), fill_attr(p.fill));
        }
        Shape::LineSegment { points: pts, stroke } => {
            let _ = writeln!(out, "  <polyline points=\"{}\" fill=\"none\" stroke=\"#000\" stroke-width=\"{}\"/>", points(pts), f(stroke.width));
        }
        Shape::Circle(c) => {
            let stroke = if c.stroke.width > 0.0 && c.stroke.color.a() > 0 {
                format!(" stroke=\"#000\" stroke-width=\"{}\"", f(c.stroke.width))
            } else {
                String::new()
            };
            let _ =
                writeln!(out, "  <circle cx=\"{}\" cy=\"{}\" r=\"{}\" {}{stroke}/>", f(c.center.x), f(c.center.y), f(c.radius), fill_attr(c.fill));
        }
        Shape::Rect(r) => {
            let stroke = if r.stroke.width > 0.0 && r.stroke.color.a() > 0 {
                format!(" stroke=\"#000\" stroke-width=\"{}\"", f(r.stroke.width))
            } else {
                String::new()
            };
            let rr = r.corner_radius.nw as f32;
            let _ = writeln!(
                out,
                "  <rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" rx=\"{}\" {}{stroke}/>",
                f(r.rect.min.x),
                f(r.rect.min.y),
                f(r.rect.width()),
                f(r.rect.height()),
                f(rr),
                fill_attr(r.fill)
            );
        }
        Shape::Noop => {}
        other => eprintln!("gen-theme: icon shape not exported: {other:?}"),
    }
}

/// `icon` drawn by the desktop code into a 20×20 box, as SVG (black: a template image).
fn icon_svg(icon: Icon) -> String {
    let ctx = egui::Context::default();
    ctx.begin_pass(egui::RawInput::default());
    let p = ctx.layer_painter(egui::LayerId::background());
    icons::paint(&p, Rect::from_min_size(Pos2::ZERO, vec2(20.0, 20.0)), icon, Color32::BLACK);
    let mut out = ctx.end_pass();
    // the font atlas upload egui asks for: nothing renders here
    out.textures_delta.clear();
    let mut body = String::new();
    for c in &out.shapes {
        shape_svg(&c.shape, &mut body);
    }
    format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\" viewBox=\"0 0 20 20\" stroke-linejoin=\"round\" stroke-linecap=\"round\">\n{body}</svg>\n"
    )
}

fn write(path: &Path, contents: &str) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(path, contents).map_err(|e| format!("{}: {e}", path.display()))
}

/// The desktop icon as an opaque square (iOS rejects transparent app icons and rounds them itself).
fn app_icon(repo: &Path) -> Result<Vec<u8>, String> {
    let path = repo.join(APP_ICON);
    let file = std::fs::File::open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut decoder = png::Decoder::new(std::io::BufReader::new(file));
    decoder.set_transformations(png::Transformations::normalize_to_color8() | png::Transformations::ALPHA);
    let mut reader = decoder.read_info().map_err(|e| format!("{APP_ICON}: {e}"))?;
    let mut buf = vec![0; reader.output_buffer_size().ok_or("icon too large")?];
    let info = reader.next_frame(&mut buf).map_err(|e| format!("{APP_ICON}: {e}"))?;
    if info.color_type != png::ColorType::Rgba || info.bit_depth != png::BitDepth::Eight {
        return Err(format!("{APP_ICON}: expected 8-bit RGBA, got {:?} {:?}", info.color_type, info.bit_depth));
    }
    let rgb: Vec<u8> = buf[..info.buffer_size()]
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|p| {
            let a = p[3] as u32;
            (0..3).map(move |c| ((p[c] as u32 * a + APP_ICON_FIELD[c] as u32 * (255 - a) + 127) / 255) as u8)
        })
        .collect();
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, info.width, info.height);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    let mut w = enc.write_header().map_err(|e| e.to_string())?;
    w.write_image_data(&rgb).map_err(|e| e.to_string())?;
    drop(w);
    Ok(out)
}

fn generate(repo: &Path, out: &Path) -> Result<(), String> {
    write(&out.join("Theme.generated.swift"), &theme_swift())?;
    let assets = out.join("Icons.xcassets");
    let _ = std::fs::remove_dir_all(&assets);
    write(&assets.join("Contents.json"), "{\n  \"info\" : { \"author\" : \"gen-theme\", \"version\" : 1 }\n}\n")?;
    for (name, icon) in ICONS {
        let set = assets.join(format!("{name}.imageset"));
        write(&set.join(format!("{name}.svg")), &icon_svg(*icon))?;
        write(
            &set.join("Contents.json"),
            &format!(
                "{{\n  \"images\" : [ {{ \"filename\" : \"{name}.svg\", \"idiom\" : \"universal\" }} ],\n  \"info\" : {{ \"author\" : \"gen-theme\", \"version\" : 1 }},\n  \"properties\" : {{ \"preserves-vector-representation\" : true, \"template-rendering-intent\" : \"template\" }}\n}}\n"
            ),
        )?;
    }
    let icon = assets.join("AppIcon.appiconset");
    std::fs::create_dir_all(&icon).map_err(|e| e.to_string())?;
    std::fs::write(icon.join("AppIcon.png"), app_icon(repo)?).map_err(|e| e.to_string())?;
    write(
        &icon.join("Contents.json"),
        "{\n  \"images\" : [ { \"filename\" : \"AppIcon.png\", \"idiom\" : \"universal\", \"platform\" : \"ios\", \"size\" : \"1024x1024\" } ],\n  \"info\" : { \"author\" : \"gen-theme\", \"version\" : 1 }\n}\n",
    )?;
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [flag, repo] if flag == "--check" => check(Path::new(repo)),
        [repo, out] => check(Path::new(repo)).and_then(|()| generate(Path::new(repo), &PathBuf::from(out))),
        _ => Err("usage: gen-theme <repo root> <output dir> | gen-theme --check <repo root>".into()),
    };
    if let Err(e) = result {
        eprintln!("gen-theme: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mirrors_match_upstream() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        check(&repo).unwrap();
    }

    #[test]
    fn panel_check_sees_the_desktop_panel() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let edit = std::fs::read_to_string(repo.join(EDIT)).unwrap();
        let desktop = desktop_panel_controls(&edit);
        for id in ["light.exposure", "hdr.sdrClarity", "curve.refineSaturation", "grading.midtones.lum", "optics.caBlue", "calibration.blueSat"] {
            assert!(desktop.iter().any(|d| d == id), "{id} not found in {desktop:?}");
        }
        assert!(desktop.len() > 60, "{}", desktop.len());
        // a slider added upstream that iOS doesn't place fails the check
        let added = edit.replace(
            "for c in [\"effects.texture\",",
            "control(app, ui, d, \"light.whites\", true); for c in [\"effects.texture\", \"color.vibrance\", \"detail.nrDetail\",",
        );
        assert_eq!(desktop_panel_controls(&added), desktop, "already placed ids don't change the set");
        // a real develop control the panel doesn't show yet, added upstream: iOS must place it
        let unplaced = lightcraft_develop::controls::CONTROLS.iter().map(|c| c.id).find(|id| !desktop.iter().any(|d| d == id)).unwrap();
        let grown = edit.replace("\"effects.dehaze\"", &format!("\"effects.dehaze\", \"{unplaced}\""));
        let grown_ids = desktop_panel_controls(&grown);
        assert!(grown_ids.iter().any(|d| d == unplaced) && !lightcraft_ffi::placed_controls().iter().any(|p| p == unplaced), "{unplaced}");
    }

    #[test]
    fn icons_export_shapes() {
        for (name, icon) in ICONS {
            let svg = icon_svg(*icon);
            assert!(svg.matches('<').count() > 2, "{name}: {svg}");
        }
    }
}
