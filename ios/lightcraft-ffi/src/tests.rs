use super::*;
use lightcraft_codecs::{ChromaSubsampling, EncodeImage, EncodeMeta, Samples};

/// A fresh, empty folder under the system temp dir.
fn temp_dir(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("lightcraft-ffi-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A JPEG file: a horizontal ramp (or a flat grey).
fn jpeg(dir: &std::path::Path, name: &str, w: u32, h: u32, grey: bool) -> String {
    let rgb: Vec<u8> =
        (0..w * h).flat_map(|i| if grey { [128, 128, 128] } else { [(i % w * 255 / w) as u8, 120, 200 - (i / w * 150 / h) as u8] }).collect();
    let img = EncodeImage::new(w, h, 3, Samples::U8(&rgb));
    let bytes = lightcraft_codecs::encode_jpeg(&img, 92, ChromaSubsampling::S444, &EncodeMeta::default()).unwrap();
    let path = dir.join(name);
    std::fs::write(&path, bytes).unwrap();
    path.to_string_lossy().into_owned()
}

fn open(name: &str) -> (Engine, std::path::PathBuf) {
    let dir = temp_dir(name);
    let e = Engine::open(dir.join("lib").to_string_lossy().into(), dir.join("models").to_string_lossy().into(), 256).unwrap();
    (Arc::into_inner(e).unwrap(), dir)
}

fn call(e: &Engine, cmd: &str, p: Value) -> Value {
    serde_json::from_str(&e.call(cmd.into(), p.to_string()).unwrap()).unwrap()
}

fn import(e: &Engine, path: &str) -> u64 {
    let r = call(e, "library.import", json!({"paths": [path], "mode": "copy"}));
    r["imported"][0].as_u64().unwrap()
}

fn mean(p: &Preview) -> [f64; 3] {
    let n = (p.rgba.len() / 4) as f64;
    let mut s = [0.0; 3];
    for px in p.rgba.as_chunks::<4>().0 {
        for c in 0..3 {
            s[c] += px[c] as f64;
        }
    }
    s.map(|v| v / n)
}

fn value(e: &Engine, id: &str) -> f64 {
    e.controls().unwrap().into_iter().find(|c| c.id == id).unwrap().value
}

#[test]
fn import_edit_undo_render_export() {
    let (e, dir) = open("flow");
    let id = import(&e, &jpeg(&dir, "ramp.jpg", 600, 400, false));
    let st = e.photo_state().unwrap().unwrap();
    assert_eq!(st.id, id);
    assert!(st.relative_wb, "a JPEG uses the relative white balance scale");

    let before = e.render(id, 300, false, false).unwrap();
    assert_eq!((before.width, before.height), (300, 200));
    assert_eq!(before.histogram.luma.len(), 256);

    assert_eq!(e.set_value("light.exposure".into(), 1.004).unwrap(), 1.0, "snapped to the 0.01 step");
    let brighter = e.render(id, 300, true, false).unwrap();
    assert!(mean(&brighter)[1] > mean(&before)[1] + 5.0, "+1 EV brightens");
    let original = e.render(id, 300, false, true).unwrap();
    assert!((mean(&original)[1] - mean(&before)[1]).abs() < 1.0, "the before view ignores the edit");

    // history and undo are the engine's
    assert_eq!(call(&e, "history.list", json!({}))["history"], json!(["Exposure"]));
    call(&e, "edit.undo", json!({}));
    assert_eq!(value(&e, "light.exposure"), 0.0);
    call(&e, "edit.redo", json!({}));
    assert_eq!(value(&e, "light.exposure"), 1.0);

    // the desktop's export
    let out = temp_dir("flow-out");
    let r = call(&e, "app.export", json!({"ids": [id], "dir": out.to_string_lossy(), "format": "jpeg", "longEdge": 0, "quality": 90}));
    let path = r["files"][0]["path"].as_str().unwrap();
    let back = lightcraft_codecs::decode(&std::fs::read(path).unwrap(), Default::default()).unwrap();
    assert_eq!((back.width, back.height), (600, 400));

    let thumb = e.thumbnail(id, 64).unwrap();
    assert!(thumb.width.max(thumb.height) >= 64, "the engine rounds thumbnails up to its size tiers");
    e.save().unwrap();
}

#[test]
fn relative_white_balance_and_presets() {
    let (e, dir) = open("wb");
    let id = import(&e, &jpeg(&dir, "grey.jpg", 64, 64, true));
    assert_eq!(e.set_value(controls::WB_TEMP.into(), 50.0).unwrap(), 50.0, "the relative value reads back");
    let [r, _, b] = mean(&e.render(id, 64, false, false).unwrap());
    assert!(r > b + 5.0, "warm: r {r} b {b}");
    let temp = e.controls().unwrap().into_iter().find(|c| c.id == "wb.temp").unwrap();
    assert_eq!((temp.min, temp.max, temp.track_stops.len()), (-100.0, 100.0, 6));

    let presets = call(&e, "presets.list", json!({}));
    let bw = presets.as_array().unwrap().iter().find(|p| p["group"] == "B&W").unwrap()["id"].as_str().unwrap().to_string();
    call(&e, "preset.apply", json!({"id": bw}));
    assert!(e.photo_state().unwrap().unwrap().black_and_white);
    let [r, g, b] = mean(&e.render(id, 64, false, false).unwrap());
    assert!((r - g).abs() < 1.5 && (g - b).abs() < 1.5, "B&W preset is neutral: {r} {g} {b}");
}

#[test]
fn library_survives_reopening() {
    let dir = temp_dir("reopen");
    let lib = dir.join("lib").to_string_lossy().into_owned();
    let models = dir.join("models").to_string_lossy().into_owned();
    let photo = jpeg(&dir, "a.jpg", 64, 48, false);
    {
        let e = Engine::open(lib.clone(), models.clone(), 0).unwrap();
        let id = import(&e, &photo);
        e.set_value("light.contrast".into(), 40.0).unwrap();
        call(&e, "photo.rate", json!({"rating": 4, "ids": [id]}));
        e.save().unwrap();
    }
    let e = Engine::open(lib, models, 0).unwrap();
    let photos = call(&e, "catalog.query", json!({}));
    assert_eq!(photos["photos"][0]["rating"], 4);
    let id = photos["photos"][0]["id"].as_u64().unwrap();
    call(&e, "library.select", json!({"ids": [id], "active": id}));
    assert_eq!(value(&e, "light.contrast"), 40.0);
}

#[test]
fn hostile_input_is_an_error() {
    let (e, _dir) = open("hostile");
    assert!(e.call("nope.nothing".into(), "{}".into()).is_err());
    assert!(e.call("develop.set".into(), "{not json".into()).is_err());
    assert!(e.set_value("light.exposure".into(), 1.0).is_err(), "no photo yet");
    assert!(e.render(999, 100, false, false).is_err());
    assert!(e.photo_state().unwrap().is_none());
    let r = call(&e, "library.import", json!({"paths": ["/nonexistent/x.jpg"], "mode": "copy"}));
    assert_eq!(r["imported"], json!([]));
}

#[test]
fn slider_text_matches_the_desktop() {
    assert_eq!(controls::format_value("light.exposure".into(), 0.5, false).unwrap(), "+0.50");
    assert_eq!(controls::format_value("light.exposure".into(), 0.0, false).unwrap(), "0.00", "as the desktop shows it");
    assert_eq!(controls::format_value("light.shadows".into(), -12.0, false).unwrap(), "-12");
    assert_eq!(controls::format_value("wb.temp".into(), 5600.0, false).unwrap(), "5600");
    assert_eq!(controls::parse_typed_value("light.exposure".into(), " +1,234 ".into(), false).unwrap(), Some(1.23));
    assert_eq!(controls::parse_typed_value("light.exposure".into(), "abc".into(), false).unwrap(), None);
    assert_eq!(controls::control_value_at("light.contrast".into(), 0.75, false).unwrap(), 50.0);
    assert_eq!(controls::nudge_value("light.exposure".into(), 0.0, 1.0, false).unwrap(), 0.05);
    assert_eq!(controls::nudge_value("wb.temp".into(), 5000.0, 1.0, false).unwrap(), 5050.0);
}

#[test]
fn panel_layout_places_real_controls() {
    let placed = placed_controls();
    assert!(placed.len() > 50, "{placed:?}");
    let all: Vec<String> = controls::all(&DevelopSettings::default(), false).into_iter().map(|c| c.id).collect();
    for id in &placed {
        assert!(all.contains(id), "{id} is not a develop control");
    }
    let mixer = controls::all(&DevelopSettings::default(), false).into_iter().find(|c| c.id == "mixer.red.hue").unwrap();
    assert_eq!(mixer.track_stops.len(), 5, "hue tracks run through the neighbouring bands");
    assert!(mixer.track_stops[0].len() == 9, "translucent stops carry alpha: {:?}", mixer.track_stops);
}

#[test]
fn curve_editor_data() {
    let (e, dir) = open("curve");
    import(&e, &jpeg(&dir, "c.jpg", 64, 64, false));
    let c = e.curve("master".into()).unwrap();
    assert_eq!(c.points, vec![0.0, 0.0, 1.0, 1.0], "the identity shows its end points");
    assert_eq!(c.samples.len(), 97);
    assert!((c.samples[48] - 0.5).abs() < 1e-9);
    assert!(c.presets.len() >= 2 && c.presets.contains(&c.preset), "{:?} / {}", c.presets, c.preset);
    call(&e, "develop.curve", json!({"channel": "master", "points": [[0.0, 0.0], [0.5, 0.7], [1.0, 1.0]]}));
    let c = e.curve("master".into()).unwrap();
    assert_eq!(c.points.len(), 6);
    assert!(c.samples[48] > 0.65, "{}", c.samples[48]);
    assert_eq!(c.preset, "Custom");
    e.set_value("curve.highlights".into(), 60.0).unwrap();
    let p = e.curve("parametric".into()).unwrap();
    assert!(p.points.is_empty() && p.samples[84] > 84.0 / 96.0, "{}", p.samples[84]);
}

#[test]
fn a_moved_library_finds_its_originals() {
    // iOS gives the app a new container path on reinstalls and updates
    let dir = temp_dir("moved");
    let (a, b) = (dir.join("a"), dir.join("b"));
    let photo = jpeg(&dir, "m.jpg", 64, 48, false);
    let id = {
        let e = Engine::open(a.join("lib").to_string_lossy().into(), a.join("models").to_string_lossy().into(), 0).unwrap();
        let id = import(&e, &photo);
        e.set_value("light.exposure".into(), 0.5).unwrap();
        e.save().unwrap();
        id
    };
    std::fs::rename(&a, &b).unwrap();
    let e = Engine::open(b.join("lib").to_string_lossy().into(), b.join("models").to_string_lossy().into(), 0).unwrap();
    assert_eq!(call(&e, "library.missing", json!({})), json!([]), "relinked to the moved Originals folder");
    assert!(e.render(id, 64, false, false).is_ok());
    assert!(serde_json::from_str::<Value>(&e.call("library.state".into(), "{}".into()).unwrap()).unwrap()["undo"].is_null(), "no undo step");
    call(&e, "library.select", json!({"ids": [id], "active": id}));
    assert_eq!(value(&e, "light.exposure"), 0.5, "edits kept");
}
