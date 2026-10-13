//! Slider specs for the Swift UI: label, range, steps, track colours and value text of every
//! develop control, from `lightcraft_develop::controls` (the desktop app's control specs), so a
//! control changed upstream changes here too.
//!
//! A few things live in the desktop UI crate (`ui-egui`), which this bridge doesn't link: the
//! relative white-balance scale for rendered photos, the value text, the typed-value parser, the
//! nudge step and the track colours. They are mirrored below; `ios/tools/gen-theme` fails the build
//! when their upstream source changes.

use lightcraft_develop::controls::{self, ControlSpec, Section, Track};
use lightcraft_develop::{DevelopSettings, WbMode};

use crate::LcError;

/// One slider, with its current value (panel units).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ControlInfo {
    /// Control id (`light.exposure`, `mixer.red.hue`, `pointColor.0.hueShift`).
    pub id: String,
    pub label: String,
    pub min: f64,
    pub max: f64,
    pub default: f64,
    pub step: f64,
    pub decimals: u8,
    /// Track colours left → right (`#rrggbb` or `#rrggbbaa`), evenly spaced; empty: the plain track.
    pub track_stops: Vec<String>,
    pub value: f64,
}

pub(crate) const WB_TEMP: &str = "wb.temp";
pub(crate) const WB_TINT: &str = "wb.tint";

/// Mirrors `ui-egui` `panels/edit.rs` `REL_TEMP`: the desktop's Temp slider for rendered (non-raw) photos.
const REL_TEMP: ControlSpec = ControlSpec {
    id: "wb.tempRel",
    label: "Temp",
    section: Section::Color,
    min: -100.0,
    max: 100.0,
    default: 0.0,
    step: 1.0,
    decimals: 0,
    track: Track::Temp,
};
/// Mirrors `ui-egui` `panels/edit.rs` `REL_TINT`.
const REL_TINT: ControlSpec = ControlSpec {
    id: "wb.tintRel",
    label: "Tint",
    section: Section::Color,
    min: -100.0,
    max: 100.0,
    default: 0.0,
    step: 1.0,
    decimals: 0,
    track: Track::Tint,
};

/// Mirrors `ui-egui` `panels/edit.rs` `k_to_rel`: Kelvin → relative temperature (mired shift).
pub(crate) fn k_to_rel(k: f64) -> f64 {
    ((1e6 / 6500.0 - 1e6 / k) / 0.8).clamp(-100.0, 100.0)
}
/// Mirrors `ui-egui` `panels/edit.rs` `rel_to_k`.
pub(crate) fn rel_to_k(r: f64) -> f64 {
    1e6 / (1e6 / 6500.0 - r * 0.8)
}

/// The spec a slider shows. `relative`: the photo uses the relative white balance scale (rendered
/// files, raws without a colour matrix), as the desktop's Temp / Tint sliders do.
pub(crate) fn spec(id: &str, relative: bool) -> Option<ControlSpec> {
    match id {
        WB_TEMP if relative => Some(REL_TEMP),
        WB_TINT if relative => Some(REL_TINT),
        _ => controls::find(id).copied(),
    }
}

fn spec_or_err(id: &str, relative: bool) -> Result<ControlSpec, LcError> {
    spec(id, relative).ok_or_else(|| LcError::Unsupported { msg: format!("unknown control `{id}`") })
}

// ---- track colours: mirrors `ui-egui` `widgets.rs` (`BAND_COLORS`, `track_stops`, `lerp`)

/// Mirrors `widgets.rs` `BAND_COLORS`.
const BAND_COLORS: [&str; 8] = ["#aa0000", "#bb6600", "#aaaa00", "#009900", "#00aaaa", "#0044cc", "#7722aa", "#aa0077"];

/// Premultiplied RGBA, 0…255 (egui's `Color32`).
type Rgba = [f32; 4];

fn hex(s: &str) -> Rgba {
    let v = u32::from_str_radix(s.trim_start_matches('#'), 16).unwrap_or(0x808080);
    [((v >> 16) & 0xff) as f32, ((v >> 8) & 0xff) as f32, (v & 0xff) as f32, 255.0]
}
/// `widgets.rs` `lerp` (opaque, rounded).
fn lerp(a: Rgba, b: Rgba, t: f32) -> Rgba {
    let t = t.clamp(0.0, 1.0);
    let f = |x: f32, y: f32| (x + (y - x) * t).round();
    [f(a[0], b[0]), f(a[1], b[1]), f(a[2], b[2]), 255.0]
}
/// egui's `Color32::gamma_multiply`: every premultiplied channel, alpha too, times `k`.
fn gamma(c: Rgba, k: f32) -> Rgba {
    c.map(|v| (v * k).round())
}
fn css(c: Rgba) -> String {
    let a = c[3].clamp(0.0, 255.0);
    // premultiplied → straight for Swift
    let un = |v: f32| if a > 0.0 { (v * 255.0 / a).round().clamp(0.0, 255.0) as u8 } else { 0 };
    if a >= 255.0 {
        format!("#{:02x}{:02x}{:02x}", un(c[0]), un(c[1]), un(c[2]))
    } else {
        format!("#{:02x}{:02x}{:02x}{:02x}", un(c[0]), un(c[1]), un(c[2]), a as u8)
    }
}

fn track_stops(track: &Track) -> Vec<String> {
    let band = |b: u8| hex(BAND_COLORS[(b as usize) % 8]);
    let white = [255.0; 4];
    let stops: Vec<Rgba> = match track {
        Track::Plain | Track::Centered => return Vec::new(),
        Track::Temp => ["#193961", "#47566a", "#60666d", "#70705b", "#737339", "#75742a"].iter().map(|h| hex(h)).collect(),
        Track::Tint => ["#246123", "#2c552c", "#394739", "#4a3d4c", "#6b336b", "#872c87"].iter().map(|h| hex(h)).collect(),
        Track::Gradient { from, to } => vec![hex(from), hex(to)],
        Track::Hue { band: b } => {
            let i = *b as usize % 8;
            let prev = hex(BAND_COLORS[(i + 7) % 8]);
            let next = hex(BAND_COLORS[(i + 1) % 8]);
            let me = hex(BAND_COLORS[i]);
            vec![gamma(prev, 0.7), gamma(lerp(prev, me, 0.5), 0.7), gamma(me, 0.7), gamma(lerp(me, next, 0.5), 0.7), gamma(next, 0.7)]
        }
        Track::Sat { band: b } => vec![hex("#454343"), lerp(hex("#454343"), band(*b), 0.6), band(*b)],
        Track::Lum { band: b } => {
            let c = band(*b);
            vec![gamma(c, 0.2), gamma(c, 0.55), lerp(c, white, 0.35), lerp(c, white, 0.6)]
        }
        Track::Rainbow => ["#aa0000", "#aaaa00", "#009900", "#00aaaa", "#0044cc", "#aa0077", "#aa0000"].iter().map(|h| hex(h)).collect(),
    };
    stops.into_iter().map(css).collect()
}

/// A control's value in panel units (the relative Temp / Tint for rendered photos), on its steps.
pub(crate) fn value(d: &DevelopSettings, id: &str, relative: bool) -> f64 {
    let as_shot = d.wb.mode == WbMode::AsShot;
    let v = match id {
        WB_TEMP if relative => {
            if as_shot {
                0.0
            } else {
                k_to_rel(d.wb.temp)
            }
        }
        WB_TINT if relative => {
            if as_shot {
                0.0
            } else {
                d.wb.tint.clamp(-100.0, 100.0)
            }
        }
        _ => controls::get(d, id).unwrap_or(0.0),
    };
    spec(id, relative).map_or(v, |s| snap(&s, v))
}

/// The engine value for a panel value (relative Temp → Kelvin).
pub(crate) fn engine_value(id: &str, v: f64, relative: bool) -> f64 {
    if relative && id == WB_TEMP { rel_to_k(v) } else { v }
}

/// Every develop control (as `develop.controls`: the static specs, then the indexed ones that exist).
pub(crate) fn all(d: &DevelopSettings, relative: bool) -> Vec<ControlInfo> {
    let ids = controls::CONTROLS.iter().map(|c| c.id.to_string()).chain(controls::indexed_instances(d).into_iter().map(|(id, _)| id));
    ids.filter_map(|id| {
        let s = spec(&id, relative)?;
        Some(ControlInfo {
            label: s.label.to_string(),
            min: s.min,
            max: s.max,
            default: s.default,
            step: s.step,
            decimals: s.decimals,
            track_stops: track_stops(&s.track),
            value: value(d, &id, relative),
            id,
        })
    })
    .collect()
}

/// A slider's value as shown next to its label ("+0.50", "-12", "0").
/// Mirrors `ui-egui` `widgets.rs` `shown_value`.
#[uniffi::export]
pub fn format_value(id: String, value: f64, relative_wb: bool) -> Result<String, LcError> {
    let spec = spec_or_err(&id, relative_wb)?;
    let v = spec.clamp(value);
    let shown = if spec.id == "wb.temp" { format!("{v:.0}") } else { spec.format(v).replace("+0.00", "0").replace("-0.00", "0") };
    Ok(if shown == "+0" || shown == "-0" { "0".to_string() } else { shown })
}

/// Track position (0…1) of `value`: linear, except the Kelvin temperature.
#[uniffi::export]
pub fn control_position(id: String, value: f64, relative_wb: bool) -> Result<f64, LcError> {
    Ok(spec_or_err(&id, relative_wb)?.position(value))
}

/// The value at track position `position` (0…1), on the control's steps.
#[uniffi::export]
pub fn control_value_at(id: String, position: f64, relative_wb: bool) -> Result<f64, LcError> {
    let spec = spec_or_err(&id, relative_wb)?;
    Ok(snap(&spec, spec.value_at(position)))
}

/// A value typed for a slider ("0.5", "+12", "-1,5", "5600 K"), on its steps and clamped; `None`
/// when it isn't a number. Mirrors `ui-egui` `widgets.rs` `typed_value`.
#[uniffi::export]
pub fn parse_typed_value(id: String, text: String, relative_wb: bool) -> Result<Option<f64>, LcError> {
    let spec = spec_or_err(&id, relative_wb)?;
    let t = text.trim().replace(',', ".");
    let t = t.trim_end_matches(|c: char| c == '%' || c == 'K' || c == 'k' || c.is_whitespace());
    Ok(t.parse::<f64>().ok().filter(|v| v.is_finite()).map(|v| snap(&spec, v)))
}

/// `value` moved by `steps` nudges (VoiceOver increment / decrement): about 1/200 of the range, a
/// whole number of the control's steps. Mirrors `ui-egui` `widgets.rs` `nudged` (its arrow keys).
#[uniffi::export]
pub fn nudge_value(id: String, value: f64, steps: f64, relative_wb: bool) -> Result<f64, LcError> {
    let spec = spec_or_err(&id, relative_wb)?;
    let step = spec.step.max(1e-9);
    let unit = if spec.id == "wb.temp" { 50.0 } else { (((spec.max - spec.min) / 200.0 / step).round().max(1.0)) * step };
    Ok(snap(&spec, value + unit * if steps.is_finite() { steps } else { 0.0 }))
}

pub(crate) fn snap(spec: &ControlSpec, v: f64) -> f64 {
    let step = spec.step.max(1e-9);
    let v = if v.is_finite() { v } else { spec.default };
    ((v / step).round() * step).clamp(spec.min, spec.max)
}
