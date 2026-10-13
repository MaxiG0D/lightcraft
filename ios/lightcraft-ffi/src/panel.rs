//! The desktop's Edit panel (`ui-egui` `panels/edit.rs` `show`), as data for the Swift UI: its
//! sections, the sliders in each (by develop control id), sub-titles, flyouts and the special
//! editors (profile, white balance, curve, mixer, grading, point color…).
//!
//! Slider labels, ranges and values come from the engine (`develop.controls`); this file only says
//! where each control sits, as the desktop panel lays it out. `ios/tools/gen-theme` checks it
//! against `edit.rs` on every build: every control id the desktop panel shows must be placed here
//! (and nothing else), and the id patterns of the special editors must still be in use upstream.

use serde_json::{Value, json};

/// `{"control": id}`, enabled only while `when` (another control) is not zero.
fn control(id: &str) -> Value {
    json!({"kind": "control", "id": id})
}
fn control_when(id: &str, when: &str) -> Value {
    json!({"kind": "control", "id": id, "enabledWhenNonZero": when})
}
fn subtitle(title: &str) -> Value {
    json!({"kind": "subtitle", "title": title})
}
fn special(kind: &str) -> Value {
    json!({"kind": kind})
}
fn space() -> Value {
    json!({"kind": "space"})
}
/// A flyout row (the desktop's inset box with an icon tile) and what opens under it.
fn flyout(id: &str, title: &str, icon: &str, items: Vec<Value>) -> Value {
    json!({"kind": "flyout", "id": id, "title": title, "icon": icon, "items": items})
}
fn section(id: &str, title: &str, items: Vec<Value>) -> Value {
    json!({"id": id, "title": title, "items": items})
}

/// The panel below the Edit header: the Profile row, then the sections in the desktop's order.
pub fn layout() -> Value {
    let light = ["light.exposure", "light.contrast", "light.highlights", "light.shadows", "light.whites", "light.blacks"];
    let sdr = ["hdr.sdrBrightness", "hdr.sdrContrast", "hdr.sdrHighlights", "hdr.sdrShadows", "hdr.sdrWhites", "hdr.sdrClarity"];
    let curve = ["curve.highlights", "curve.lights", "curve.darks", "curve.shadows", "curve.refineSaturation"];
    let mut light_items = vec![json!({"kind": "hdrRow", "control": "hdr.maxEv"})];
    light_items.extend(light.iter().map(|c| control(c)));
    light_items.push(space());
    light_items.push(json!({"kind": "flyout", "id": "sdrRendition", "title": "SDR Rendition", "icon": "sliders", "onlyWhenHdr": true,
        "items": sdr.iter().map(|c| control(c)).collect::<Vec<_>>()}));
    light_items.push(flyout("curve", "Curve", "curve", vec![json!({"kind": "curve", "parametric": curve})]));

    let color = vec![
        special("whiteBalance"),
        control("wb.temp"),
        control("wb.tint"),
        control("color.vibrance"),
        control("color.saturation"),
        space(),
        flyout("mixer", "Color Mixer", "radial", vec![special("mixer")]),
        flyout("pointColor", "Point Color", "picker", vec![special("pointColor")]),
        flyout("grading", "Color Grading", "presets", vec![special("grading")]),
    ];

    let mut effects =
        vec![control("effects.texture"), control("effects.clarity"), control("effects.dehaze"), subtitle("Vignette"), special("vignetteStyle")];
    effects.push(control("vignette.amount"));
    effects.extend(
        ["vignette.midpoint", "vignette.feather", "vignette.roundness", "vignette.highlights"].iter().map(|c| control_when(c, "vignette.amount")),
    );
    effects.push(subtitle("Grain"));
    effects.push(control("grain.amount"));
    effects.extend(["grain.size", "grain.roughness"].iter().map(|c| control_when(c, "grain.amount")));

    let mut detail = vec![control("detail.sharpenAmount")];
    detail.extend(["detail.sharpenRadius", "detail.sharpenDetail", "detail.sharpenMasking"].iter().map(|c| control_when(c, "detail.sharpenAmount")));
    detail.push(subtitle("AI Denoise"));
    detail.push(json!({"kind": "denoise", "control": "enhance.denoise"}));
    detail.push(subtitle("Noise Reduction"));
    detail.extend(
        ["detail.nrLuminance", "detail.nrDetail", "detail.nrContrast", "detail.nrColor", "detail.nrColorDetail", "detail.nrColorSmoothness"]
            .iter()
            .map(|c| control(c)),
    );

    let optics = vec![
        json!({"kind": "toggle", "title": "Remove Chromatic Aberration", "settings": "optics.remove_ca", "label": "Remove CA"}),
        json!({"kind": "toggle", "title": "Enable Lens Corrections", "settings": "optics.lens_profile", "label": "Lens Corrections"}),
        json!({"kind": "lensProfile", "controls": ["optics.profileDistortion", "optics.profileVignetting"]}),
        subtitle("Manual"),
        control("optics.distortion"),
        control("optics.vignetting"),
        control_when("optics.vignettingMidpoint", "optics.vignetting"),
        space(),
        flyout(
            "defringe",
            "Defringe",
            "picker",
            vec![
                control("optics.defringePurple"),
                control_when("optics.defringePurpleHueLo", "optics.defringePurple"),
                control_when("optics.defringePurpleHueHi", "optics.defringePurple"),
                control("optics.defringeGreen"),
                control_when("optics.defringeGreenHueLo", "optics.defringeGreen"),
                control_when("optics.defringeGreenHueHi", "optics.defringeGreen"),
                subtitle("Lateral Chromatic Aberration"),
                control("optics.caRed"),
                control("optics.caBlue"),
            ],
        ),
    ];

    let mut calibration = vec![subtitle("Shadows"), control("calibration.shadowsTint")];
    for (title, k) in [("Red Primary", "red"), ("Green Primary", "green"), ("Blue Primary", "blue")] {
        calibration.push(subtitle(title));
        calibration.push(control(&format!("calibration.{k}Hue")));
        calibration.push(control(&format!("calibration.{k}Sat")));
    }

    json!({
        "profile": {"amount": "profile.amount"},
        "sections": [
            section("light", "Light", light_items),
            section("color", "Color", color),
            section("effects", "Effects", effects),
            section("detail", "Detail", detail),
            section("optics", "Optics", optics),
            section("calibration", "Calibration", calibration),
        ],
        // mirrors `edit.rs`: the vignette styles (label, `vignette.style` value) and the grading tabs
        "vignetteStyles": [["Highlight", "highlightPriority"], ["Color", "colorPriority"], ["Paint", "paintOverlay"]],
        "gradingTabs": [["3way", "3-Way", "gradeAll"], ["shadows", "Shadows", "gradeShadows"], ["midtones", "Midtones", "gradeMidtones"], ["highlights", "Highlights", "gradeHighlights"]],
        // the special editors' control families (`mixer.{band}.{hue|sat|lum}`, …)
        "mixer": {"bands": lightcraft_develop::MIXER_BANDS, "parts": ["hue", "sat", "lum"], "bwPrefix": "bw"},
        "grading": {"zones": ["shadows", "midtones", "highlights"], "parts": ["hue", "sat", "lum"],
            "threeWay": ["grading.shadows.lum", "grading.midtones.lum", "grading.highlights.lum"], "shared": ["grading.blending", "grading.balance"]},
        "pointColor": {"parts": ["hueShift", "satShift", "lumShift", "variance"], "range": ["range", "hueRange", "satRange", "lumRange"]},
    })
}

/// Every control id the layout places directly (not the special editors' families).
pub fn placed_controls() -> Vec<String> {
    fn walk(v: &Value, out: &mut Vec<String>) {
        match v {
            Value::Object(m) => {
                for key in ["id", "control"] {
                    if let Some(id) = m.get(key).and_then(Value::as_str).filter(|id| lightcraft_develop::controls::find(id).is_some()) {
                        out.push(id.to_string());
                    }
                }
                for key in ["items", "parametric", "controls", "sections", "threeWay", "shared"] {
                    if let Some(Value::Array(a)) = m.get(key) {
                        for x in a {
                            match x {
                                Value::String(id) if lightcraft_develop::controls::find(id).is_some() => out.push(id.clone()),
                                other => walk(other, out),
                            }
                        }
                    }
                }
                for key in ["profile", "grading"] {
                    if let Some(p) = m.get(key) {
                        walk(p, out);
                    }
                }
                if let Some(Value::String(id)) = m.get("amount") {
                    out.push(id.clone());
                }
            }
            Value::Array(a) => a.iter().for_each(|x| walk(x, out)),
            _ => {}
        }
    }
    let mut out = Vec::new();
    walk(&layout(), &mut out);
    out.sort();
    out.dedup();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_placed_control_exists() {
        let placed = placed_controls();
        assert!(placed.len() > 50, "{placed:?}");
        assert!(placed.contains(&"light.exposure".to_string()) && placed.contains(&"calibration.blueSat".to_string()));
        assert!(placed.contains(&"profile.amount".to_string()) && placed.contains(&"curve.refineSaturation".to_string()));
    }
}
