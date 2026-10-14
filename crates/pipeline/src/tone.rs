//! The global tone map: scene luminance → display-linear luminance.
//!
//! Built in the log domain around middle grey (0.18): contrast scales log-exposure about grey,
//! whites move the shoulder (white point), blacks move the toe. The shoulder is an extended
//! Reinhard curve so highlights roll off smoothly instead of clipping.
//!
//! Rendered (display-referred) sources such as JPEGs use [`ToneMap::display`] instead: identity at
//! neutral settings (an unedited JPEG renders exactly as the file), with contrast/whites/blacks as
//! S-curve adjustments in a gamma-2.2 perceptual domain and a short shoulder above 0.95.

pub const GREY: f32 = 0.18;
/// The tone LUT spans `LUT_MIN_EV..LUT_MAX_EV` around grey in `LUT_N` steps.
pub const LUT_MIN_EV: f32 = -14.0;
pub const LUT_MAX_EV: f32 = 10.0;
pub const LUT_N: usize = 4096;
/// Nodes of a camera chroma curve, evenly spaced over display luminance 0..=1.
pub const CHROMA_N: usize = 8;
const NO_CHROMA: [f32; CHROMA_N] = [1.0; CHROMA_N];

/// A file-local camera look, fitted independently of the scene-linear colour transform.
/// Knots are scene/display-linear luminance pairs. Keeping this in the finish stage preserves
/// RAW exposure and highlight headroom; it is never baked into the decoded sensor pixels.
/// `chroma` scales colourfulness by display luminance after the curve (a camera's per-channel
/// curve saturates shadows and bleaches highlights toward white, which a luminance curve can't).
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize)]
pub struct CameraTone {
    knots: [[f32; 2]; 32],
    chroma: [f32; CHROMA_N],
}

impl<'de> serde::Deserialize<'de> for CameraTone {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(serde::Deserialize)]
        struct Wire {
            knots: [[f32; 2]; 32],
            // absent in smart previews written before the chroma curve existed
            #[serde(default)]
            chroma: Option<[f32; CHROMA_N]>,
        }
        let w = Wire::deserialize(d)?;
        let tone = Self::new(w.knots).ok_or_else(|| serde::de::Error::custom("invalid camera tone curve"))?;
        match w.chroma {
            Some(c) => tone.with_chroma(c).ok_or_else(|| serde::de::Error::custom("invalid camera chroma curve")),
            None => Ok(tone),
        }
    }
}

impl CameraTone {
    pub fn new(knots: [[f32; 2]; 32]) -> Option<Self> {
        let mut previous = [0.0, 0.0];
        for p in knots {
            if !p.iter().all(|v| v.is_finite()) || p[0] <= previous[0] || p[1] < previous[1] || p[1] >= 1.0 {
                return None;
            }
            previous = p;
        }
        Some(Self { knots, chroma: NO_CHROMA })
    }

    /// The curve with chroma scales at display luminance 0, 1/7 … 1 (each finite, 0..=4).
    pub fn with_chroma(self, chroma: [f32; CHROMA_N]) -> Option<Self> {
        chroma.iter().all(|k| k.is_finite() && (0.0..=4.0).contains(k)).then_some(Self { chroma, ..self })
    }

    pub fn chroma(&self) -> &[f32; CHROMA_N] {
        &self.chroma
    }

    /// The (scene, display) luminance knots, in increasing order.
    pub fn knots(&self) -> &[[f32; 2]; 32] {
        &self.knots
    }

    pub fn apply(&self, y: f32) -> f32 {
        if !y.is_finite() || y <= 0.0 {
            return 0.0;
        }
        let mut previous = [0.0, 0.0];
        for p in self.knots {
            if y <= p[0] {
                let t = (y - previous[0]) / (p[0] - previous[0]);
                return previous[1] + t * (p[1] - previous[1]);
            }
            previous = p;
        }
        let a = self.knots[30];
        let b = self.knots[31];
        // Extend beyond observed (unclipped) highlights with a continuous, bounded shoulder.
        let slope = ((b[1] - a[1]) / (b[0] - a[0])).clamp(0.1, 16.0);
        1.0 - (1.0 - b[1]) * (-(y - b[0]) * slope / (1.0 - b[1]).max(0.01)).exp()
    }
}

/// Scene EV over grey where [`ToneMap::hdr`] starts lifting highlights above the SDR curve.
const HDR_FROM_EV: f32 = 1.5;

#[derive(Clone, Debug)]
pub struct ToneMap {
    lut: Vec<f32>,
    chroma: [f32; CHROMA_N],
    /// Colourfulness scale by scene EV, on the same grid as `lut` ([`ToneMap::sat_scale`]); empty
    /// (every scale 1) unless [`ToneMap::with_rgb_contrast`] set it.
    sat: Vec<f32>,
}

impl ToneMap {
    pub fn camera(curve: &CameraTone, contrast: f64, whites: f64, blacks: f64) -> ToneMap {
        ToneMap::camera_hdr(curve, contrast, whites, blacks, 1.0)
    }

    /// [`ToneMap::camera`] for an HDR render reaching `peak` (linear, SDR white = 1; 1 = SDR
    /// exactly): the camera's look up to 1.5 EV over grey, so midtones match the SDR render (and a
    /// gain map only lifts highlights), then the highlights gain up to `peak − 1` more as in
    /// [`ToneMap::hdr`].
    pub fn camera_hdr(curve: &CameraTone, contrast: f64, whites: f64, blacks: f64, peak: f32) -> ToneMap {
        let peak = if peak.is_finite() { peak.max(1.0) } else { 1.0 };
        let adjustment = Self::display(contrast, whites, blacks);
        let neutral = contrast == 0.0 && whites == 0.0 && blacks == 0.0;
        let top = (2.9 - 1.6 * (whites as f32 / 100.0) + peak.log2() + 1.0).max(HDR_FROM_EV + 0.5);
        let lut = (0..LUT_N)
            .map(|i| {
                let ev = LUT_MIN_EV + (LUT_MAX_EV - LUT_MIN_EV) * i as f32 / (LUT_N - 1) as f32;
                let y = curve.apply(GREY * 2f32.powf(ev));
                let o = if neutral { y } else { adjustment.apply(y) };
                if peak > 1.0 { (o + (peak - 1.0) * smooth(HDR_FROM_EV, top, ev)).clamp(0.0, peak) } else { o }
            })
            .collect();
        ToneMap { lut, chroma: curve.chroma, sat: Vec::new() }
    }
    /// `contrast`, `whites`, `blacks` in −100..100 (Lightroom slider units).
    pub fn new(contrast: f64, whites: f64, blacks: f64) -> ToneMap {
        ToneMap::hdr(contrast, whites, blacks, 1.0)
    }

    /// [`ToneMap::new`] for an HDR render reaching `peak` (linear, SDR white = 1; 1 = SDR exactly).
    /// Below about half of SDR white the curve is the SDR one; above, the highlights gain up to
    /// `peak − 1` more along a smoothstep in scene EV, from 1.5 EV over grey to one stop past the
    /// white point moved up by the headroom, so the result stays monotone, never exceeds `peak`,
    /// and reaches it there (within the table's range).
    pub fn hdr(contrast: f64, whites: f64, blacks: f64, peak: f32) -> ToneMap {
        let peak = if peak.is_finite() { peak.max(1.0) } else { 1.0 };
        let c = (contrast / 100.0) as f32;
        let slope = if c >= 0.0 { 1.0 + 0.55 * c } else { 1.0 + 0.4 * c };
        // White point: scene luminance (after contrast) that maps to display 1.0.
        let white_ev = 2.9 - 1.6 * (whites as f32 / 100.0);
        let wl = GREY * 2f32.powf(white_ev);
        let pre = 1.0 + GREY / wl; // keep grey near grey
        let b = (blacks / 100.0) as f32;
        let lut = (0..LUT_N)
            .map(|i| {
                let ev = LUT_MIN_EV + (LUT_MAX_EV - LUT_MIN_EV) * i as f32 / (LUT_N - 1) as f32;
                let y = GREY * 2f32.powf(ev * slope) * pre;
                // extended Reinhard with white point wl: y(1 + y/wl²)/(1 + y)
                let mut o = y * (1.0 + y / (wl * wl)) / (1.0 + y);
                o = o.min(1.0);
                // Toe: blacks < 0 crushes, > 0 lifts.
                if b < 0.0 {
                    // Smooth max(0, o − k) (a soft knee), renormalized so 1 stays 1.
                    let k = -b * 0.035;
                    let e = 0.004;
                    let soft = |v: f32| ((v - k) + ((v - k) * (v - k) + e * e).sqrt()) * 0.5;
                    o = (soft(o) - soft(0.0)) / (soft(1.0) - soft(0.0));
                } else if b > 0.0 {
                    let k = b * 0.03;
                    o = k + (1.0 - k) * o;
                }
                if peak > 1.0 {
                    let top = (white_ev + peak.log2() + 1.0).max(HDR_FROM_EV + 0.5);
                    o += (peak - 1.0) * smooth(HDR_FROM_EV, top, ev * slope);
                }
                o.clamp(0.0, peak)
            })
            .collect();
        ToneMap { lut, chroma: NO_CHROMA, sat: Vec::new() }
    }

    /// Tone map for display-referred sources: identity at neutral settings.
    pub fn display(contrast: f64, whites: f64, blacks: f64) -> ToneMap {
        ToneMap::display_hdr(contrast, whites, blacks, 1.0)
    }

    /// [`ToneMap::display`] for an HDR render reaching `peak`: values above SDR white (an HDR
    /// source, e.g. a decoded gain-map image) pass through and roll off softly towards `peak`
    /// instead of clipping at 1; SDR sources (≤ 1) render as with [`ToneMap::display`].
    pub fn display_hdr(contrast: f64, whites: f64, blacks: f64, peak: f32) -> ToneMap {
        let peak = if peak.is_finite() { peak.max(1.0) } else { 1.0 };
        let c = (contrast / 100.0) as f32;
        let w = (whites / 100.0) as f32;
        let b = (blacks / 100.0) as f32;
        let m = GREY.powf(1.0 / 2.2);
        let lut = (0..LUT_N)
            .map(|i| {
                let ev = LUT_MIN_EV + (LUT_MAX_EV - LUT_MIN_EV) * i as f32 / (LUT_N - 1) as f32;
                let y = GREY * 2f32.powf(ev);
                let mut p = y.powf(1.0 / 2.2);
                if p <= 1.0 {
                    // S-curve anchored at 0, grey and 1
                    p += c * 0.35 * (p - m) * (1.0 - (2.0 * p - 1.0).powi(2));
                    // whites: lift/lower the upper tones; blacks: the lower tones
                    let up = smooth(0.45, 1.0, p);
                    p += w * 0.12 * up * (1.0 - p * 0.5);
                    let lo = 1.0 - smooth(0.0, 0.45, p);
                    p += b * 0.07 * lo * (p * 2.0).min(1.0);
                } else {
                    p += w * 0.12 * 0.5;
                }
                let mut o = p.max(0.0).powf(2.2);
                // short shoulder: slope 1 at 0.95, reaching 1.0 at 1.05
                if peak > 1.0 && o > 0.95 {
                    // exponential shoulder: slope 1 at 0.95, asymptote at `peak`
                    let r = peak - 0.95;
                    o = 0.95 + r * (1.0 - (-(o - 0.95) / r).exp());
                } else if o > 0.95 {
                    let d = (o - 0.95).min(0.1);
                    o = 0.95 + d - d * d / 0.2;
                }
                o.clamp(0.0, peak)
            })
            .collect();
        ToneMap { lut, chroma: NO_CHROMA, sat: Vec::new() }
    }

    /// Fork-only (MaxiG0D/lightcraft, [`lightcraft_develop::Process::Fork1`]): this map followed by a
    /// Lightroom-like Contrast, `contrast` in −100..100. One S-curve for every source (camera look,
    /// default raw curve or rendered file), in a gamma-2.2 domain about a light midtone (so +100 darkens
    /// walls and skin rather than lifting them), with black and white fixed; about 1.6× the slope there at
    /// +100, and −100 its exact inverse. HDR values above SDR white pass. Like a curve applied to the R, G
    /// and B channels (the DNG SDK's hue-preserving RGB tone curve), it scales colourfulness with its
    /// log-log slope ([`ToneMap::sat_scale`], damped by [`SAT_GAIN`]): more contrast gives more colour,
    /// less gives less. At 0 the map is unchanged.
    pub fn with_rgb_contrast(self, contrast: f64) -> ToneMap {
        self.with_fork_tone(contrast, 0.0, 0.0)
    }

    /// Fork-only ([`lightcraft_develop::Process::Fork1`]): [`ToneMap::with_rgb_contrast`] with
    /// Lightroom-like Whites and Blacks (each −100..100) applied before the Contrast curve, in the same
    /// gamma-2.2 domain and with the same colour coupling. Whites brightens (or dims) everything from
    /// the midtones up and takes the highlights to white (or below it); Blacks lifts (or crushes) the
    /// shadows and fades out toward white. Their curves at ±100 are measured from Lightroom on a drone
    /// photo ([`WHITES_UP`] and friends), and smaller amounts blend toward the identity.
    pub fn with_fork_tone(mut self, contrast: f64, whites: f64, blacks: f64) -> ToneMap {
        let amount = |v: f64| {
            let t = (v / 100.0) as f32;
            if t.is_finite() { t.clamp(-1.0, 1.0) } else { 0.0 }
        };
        let (c, w, b) = (amount(contrast), amount(whites), amount(blacks));
        if c == 0.0 && w == 0.0 && b == 0.0 {
            return self;
        }
        let base = self.lut.clone();
        for o in &mut self.lut {
            if *o > 0.0 && *o < 1.0 {
                let p = o.powf(1.0 / 2.2);
                let p = table_curve(p, w, &WHITES_UP, &WHITES_DOWN);
                let p = table_curve(p, b, &BLACKS_UP, &BLACKS_DOWN);
                let p = if c == 0.0 { p } else { contrast_curve(p, c) };
                *o = p.max(0.0).powf(2.2);
            }
        }
        // the curve's log-log slope at each entry, over the base map's (central differences in EV)
        let log_slope = |t: &[f32], i: usize| -> Option<f32> {
            let (a, b) = (t.get(i.saturating_sub(1))?, t.get((i + 1).min(LUT_N - 1))?);
            (*a > 1e-12 && *b > 1e-12).then(|| (b / a).ln())
        };
        self.sat = (0..LUT_N)
            .map(|i| match (log_slope(&self.lut, i), log_slope(&base, i)) {
                (Some(new), Some(old)) if old > 1e-5 => (new / old).powf(SAT_GAIN).clamp(0.5, 1.8),
                _ => 1.0,
            })
            .collect();
        self
    }

    /// Colourfulness scale for scene luminance `y` (1 unless [`ToneMap::with_rgb_contrast`] set one).
    #[inline]
    pub fn sat_scale(&self, y: f32) -> f32 {
        if self.sat.is_empty() || y <= 0.0 || !y.is_finite() {
            return 1.0;
        }
        let ev = (y / GREY).log2();
        let f = ((ev - LUT_MIN_EV) / (LUT_MAX_EV - LUT_MIN_EV)).clamp(0.0, 1.0) * (LUT_N - 1) as f32;
        let i = (f as usize).min(LUT_N - 2);
        let t = f - i as f32;
        let (a, b) = (self.sat.get(i).copied().unwrap_or(1.0), self.sat.get(i + 1).copied().unwrap_or(1.0));
        a + (b - a) * t
    }

    /// The colourfulness table ([`ToneMap::sat_scale`]): `LUT_N` entries, or empty when every scale is 1.
    pub fn sat_lut(&self) -> &[f32] {
        &self.sat
    }

    /// The table (`LUT_N` entries, see [`ToneMap::apply`]).
    pub fn lut(&self) -> &[f32] {
        &self.lut
    }

    /// The chroma curve (`CHROMA_N` entries, see [`ToneMap::chroma_scale`]).
    pub fn chroma_lut(&self) -> &[f32] {
        &self.chroma
    }

    /// Chroma scale at display luminance `o` (exactly 1 everywhere unless a camera look sets it).
    #[inline]
    pub fn chroma_scale(&self, o: f32) -> f32 {
        if !o.is_finite() {
            return 1.0;
        }
        let f = o.clamp(0.0, 1.0) * (CHROMA_N - 1) as f32;
        let i = (f as usize).min(CHROMA_N - 2);
        let t = f - i as f32;
        let (a, b) = (self.chroma.get(i).copied().unwrap_or(1.0), self.chroma.get(i + 1).copied().unwrap_or(1.0));
        if a == b { a } else { a + (b - a) * t }
    }

    /// Scene luminance → display-linear luminance.
    #[inline]
    pub fn apply(&self, y: f32) -> f32 {
        if y <= 0.0 {
            return 0.0;
        }
        let ev = (y / GREY).log2();
        let f = ((ev - LUT_MIN_EV) / (LUT_MAX_EV - LUT_MIN_EV)).clamp(0.0, 1.0) * (LUT_N - 1) as f32;
        let i = (f as usize).min(LUT_N - 2);
        let t = f - i as f32;
        let v = self.lut[i] + (self.lut[i + 1] - self.lut[i]) * t;
        if ev < LUT_MIN_EV { v * (y / (GREY * 2f32.powf(LUT_MIN_EV))) } else { v }
    }
}

/// The pivot of [`contrast_curve`] in the gamma-2.2 domain, a light midtone (display-linear 0.39), and
/// its shape below, fitted to Lightroom's Contrast +100 on a phone photo (display values 0.40 → 0.30,
/// 0.51 → 0.45, 0.67 → 0.68, 0.81 → 0.88): it darkens the midtones and keeps the light tones.
const PIVOT: f32 = 0.65;
const POWER: f32 = 0.65;
const BLEND: f32 = 0.9;
/// How much of the curve's log-log slope becomes colourfulness: a full RGB curve's coupling gives more
/// colour than Lightroom at +100 (orange wood and skin), so it's damped.
const SAT_GAIN: f32 = 0.8;

/// Lightroom's Whites and Blacks at ±100 as display-value curves (gamma 2.2) on 17 even knots from 0
/// to 1, measured per tone from Lightroom exports of one drone photo (median output per input band).
const WHITES_UP: [f32; 17] = [0.0, 0.082, 0.139, 0.197, 0.266, 0.340, 0.424, 0.508, 0.598, 0.694, 0.774, 0.850, 0.911, 0.960, 0.994, 1.0, 1.0];
const WHITES_DOWN: [f32; 17] = [0.0, 0.080, 0.131, 0.184, 0.244, 0.301, 0.357, 0.408, 0.451, 0.496, 0.537, 0.584, 0.631, 0.679, 0.747, 0.840, 0.942];
const BLACKS_UP: [f32; 17] = [0.105, 0.160, 0.209, 0.262, 0.321, 0.379, 0.440, 0.494, 0.549, 0.608, 0.662, 0.723, 0.778, 0.828, 0.887, 0.944, 1.0];
const BLACKS_DOWN: [f32; 17] = [0.0, 0.0, 0.0, 0.008, 0.072, 0.172, 0.261, 0.336, 0.406, 0.482, 0.552, 0.634, 0.711, 0.783, 0.863, 0.933, 1.0];

/// `p` (0..=1) through `up` at `t = 1` or `down` at `t = −1`, blended toward the identity for smaller `|t|`.
fn table_curve(p: f32, t: f32, up: &[f32; 17], down: &[f32; 17]) -> f32 {
    if t == 0.0 {
        return p;
    }
    let table = if t > 0.0 { up } else { down };
    let f = p.clamp(0.0, 1.0) * 16.0;
    let i = (f as usize).min(15);
    let (a, b) = (table.get(i).copied().unwrap_or(p), table.get(i + 1).copied().unwrap_or(p));
    let v = a + (b - a) * (f - i as f32);
    p + t.abs() * (v - p)
}

/// The Fork1 contrast S-curve on `p` in 0..=1 (gamma 2.2), `c` in −1..=1: for `c > 0` a blend of the
/// identity with power curves meeting at [`PIVOT`] with exponent `1 + POWER·c` (monotone for any `c`,
/// black, pivot and white fixed); for `c < 0` the inverse of the curve for `|c|`, so −x undoes +x.
fn contrast_curve(p: f32, c: f32) -> f32 {
    let up = |p: f32, c: f32| {
        let g = 1.0 + POWER * c;
        let s = if p <= PIVOT { PIVOT * (p / PIVOT).powf(g) } else { 1.0 - (1.0 - PIVOT) * ((1.0 - p) / (1.0 - PIVOT)).powf(g) };
        p + BLEND * (s - p)
    };
    let p = if p.is_finite() { p.clamp(0.0, 1.0) } else { 0.0 };
    if c >= 0.0 {
        return up(p, c);
    }
    // the inverse by bisection: `up` is increasing, so 30 halvings pin it far below f32 resolution
    let (mut lo, mut hi) = (0.0f32, 1.0f32);
    for _ in 0..30 {
        let mid = 0.5 * (lo + hi);
        if up(mid, -c) < p { lo = mid } else { hi = mid }
    }
    0.5 * (lo + hi)
}

fn smooth(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn knots() -> [[f32; 2]; 32] {
        std::array::from_fn(|i| {
            let x = 0.004 * 1.18f32.powi(i as i32);
            [x, 1.0 - (-2.0 * x).exp()]
        })
    }

    #[test]
    fn chroma_curve_is_identity_unless_set_and_survives_serde() {
        let plain = CameraTone::new(knots()).unwrap();
        let map = ToneMap::camera(&plain, 0.0, 0.0, 0.0);
        assert!([0.0, 0.3, 0.77, 1.0, 2.0].iter().all(|o| map.chroma_scale(*o) == 1.0));
        assert!([0.0, 0.5, 1.0].iter().all(|o| ToneMap::new(0.0, 0.0, 0.0).chroma_scale(*o) == 1.0));
        // smart previews written before the chroma curve existed still load (identity)
        let old = serde_json::json!({ "knots": knots() });
        assert_eq!(serde_json::from_value::<CameraTone>(old).unwrap(), plain);
        let tone = plain.with_chroma([1.4, 1.3, 1.1, 1.0, 0.7, 0.4, 0.25, 0.2]).unwrap();
        let back: CameraTone = serde_json::from_value(serde_json::to_value(tone).unwrap()).unwrap();
        assert_eq!(back, tone);
        let map = ToneMap::camera(&tone, 0.0, 0.0, 0.0);
        assert!((map.chroma_scale(0.0) - 1.4).abs() < 1e-6 && (map.chroma_scale(1.0) - 0.2).abs() < 1e-6);
        assert!((map.chroma_scale(0.5 / 7.0) - 1.35).abs() < 1e-5, "interpolates between nodes");
        assert_eq!(map.chroma_scale(f32::NAN), 1.0);
        // hostile values are rejected, also when deserialized
        assert!(plain.with_chroma([f32::NAN; CHROMA_N]).is_none());
        assert!(plain.with_chroma([-1.0; CHROMA_N]).is_none());
        let bad = serde_json::json!({ "knots": knots(), "chroma": [9.0, 1, 1, 1, 1, 1, 1, 1] });
        assert!(serde_json::from_value::<CameraTone>(bad).is_err());
    }

    #[test]
    fn camera_curve_preserves_black_and_extends_headroom() {
        let knots = std::array::from_fn(|i| {
            let x = 0.005 * 1.15f32.powi(i as i32);
            [x, 1.0 - (-3.0 * x).exp()]
        });
        let curve = CameraTone::new(knots).unwrap();
        let base = ToneMap::camera(&curve, 0.0, 0.0, 0.0);
        assert_eq!(base.apply(0.0), 0.0);
        assert!(base.apply(0.1) < base.apply(0.2));
        let mut previous = 0.0;
        for i in 0..2000 {
            let y = 1e-6 * 1.01f32.powi(i);
            let v = base.apply(y);
            assert!((0.0..=1.0).contains(&v));
            assert!(v >= previous - 1e-6);
            previous = v;
        }
        assert!((base.apply(0.1) - curve.apply(0.1)).abs() < 0.001);
        assert!(ToneMap::camera(&curve, 50.0, 0.0, 0.0).apply(0.3) > base.apply(0.3));
        let mut invalid = knots;
        invalid[1][0] = invalid[0][0];
        assert!(CameraTone::new(invalid).is_none());
        assert!(serde_json::from_value::<CameraTone>(serde_json::json!({"knots": invalid})).is_err());
    }

    #[test]
    fn monotone_and_bounded() {
        for (c, w, b) in [(0.0, 0.0, 0.0), (100.0, 100.0, -100.0), (-100.0, -100.0, 100.0), (50.0, -30.0, -40.0)] {
            let t = ToneMap::new(c, w, b);
            let mut prev = -1.0;
            for i in 0..2000 {
                let y = 1e-5 * 1.012f32.powi(i);
                let o = t.apply(y);
                assert!((0.0..=1.0).contains(&o));
                assert!(o >= prev - 1e-6, "{c} {w} {b} at {y}: {o} < {prev}");
                prev = o;
            }
        }
    }

    #[test]
    fn hdr_is_sdr_at_peak_one_and_reaches_peak() {
        for (c, w, b) in [(0.0, 0.0, 0.0), (100.0, 100.0, -100.0), (-100.0, -100.0, 100.0), (50.0, -30.0, -40.0)] {
            assert_eq!(ToneMap::hdr(c, w, b, 1.0).lut(), ToneMap::new(c, w, b).lut());
            for peak in [2.0f32, 8.0, 32.0] {
                let sdr = ToneMap::new(c, w, b);
                let t = ToneMap::hdr(c, w, b, peak);
                let mut prev = -1.0;
                for i in 0..2400 {
                    let y = 1e-5 * 1.01f32.powi(i);
                    let o = t.apply(y);
                    assert!((0.0..=peak).contains(&o), "{c} {w} {b} {peak} at {y}: {o}");
                    assert!(o >= prev - 1e-6, "{c} {w} {b} {peak} at {y}: {o} < {prev}");
                    prev = o;
                    if y <= GREY * 2f32.powf(0.9) {
                        assert!((o - sdr.apply(y)).abs() < 1e-6, "midtones differ at {y}");
                    }
                }
                assert!(t.apply(4.0) > sdr.apply(4.0));
                if (c, w, b) == (0.0, 0.0, 0.0) {
                    assert!(t.apply(GREY * 2f32.powf(LUT_MAX_EV)) > peak * 0.99, "{peak}");
                }
            }
        }
        // a broken peak falls back to SDR
        assert_eq!(ToneMap::hdr(0.0, 0.0, 0.0, f32::NAN).lut(), ToneMap::new(0.0, 0.0, 0.0).lut());
    }

    #[test]
    fn camera_hdr_keeps_the_camera_look_and_lifts_highlights() {
        let curve = CameraTone::new(knots()).unwrap().with_chroma([1.2, 1.1, 1.0, 1.0, 0.9, 0.8, 0.7, 0.6]).unwrap();
        for (c, w, b) in [(0.0, 0.0, 0.0), (40.0, -30.0, -20.0)] {
            let sdr = ToneMap::camera(&curve, c, w, b);
            assert_eq!(ToneMap::camera_hdr(&curve, c, w, b, 1.0).lut(), sdr.lut());
            assert_eq!(ToneMap::camera_hdr(&curve, c, w, b, f32::NAN).lut(), sdr.lut());
            for peak in [2.0f32, 8.0] {
                let t = ToneMap::camera_hdr(&curve, c, w, b, peak);
                assert_eq!(t.chroma_lut(), sdr.chroma_lut());
                let mut prev = -1.0;
                for i in 0..2400 {
                    let y = 1e-5 * 1.01f32.powi(i);
                    let o = t.apply(y);
                    assert!((0.0..=peak).contains(&o), "{peak} at {y}: {o}");
                    assert!(o >= prev - 1e-6, "{peak} at {y}: {o} < {prev}");
                    prev = o;
                    // the camera's midtones, not the generic HDR curve's (issue: dark HDR exports)
                    if y <= GREY * 2f32.powf(HDR_FROM_EV - 0.01) {
                        assert!((o - sdr.apply(y)).abs() < 1e-6, "midtones differ at {y}: {o} vs {}", sdr.apply(y));
                    }
                }
                assert!(t.apply(4.0) > 1.0 && t.apply(4.0) > sdr.apply(4.0) + 0.5, "{peak}: highlights lifted");
            }
        }
    }

    #[test]
    fn display_hdr_passes_hdr_sources_and_keeps_sdr() {
        assert_eq!(ToneMap::display_hdr(20.0, 10.0, -5.0, 1.0).lut(), ToneMap::display(20.0, 10.0, -5.0).lut());
        let t = ToneMap::display_hdr(0.0, 0.0, 0.0, 8.0);
        for i in 1..=90 {
            let y = i as f32 / 100.0;
            assert!((t.apply(y) - y).abs() < 2e-3, "{y} -> {}", t.apply(y));
        }
        let mut prev = 0.0;
        for i in 1..2000 {
            let o = t.apply(i as f32 / 100.0);
            assert!(o >= prev - 1e-6 && o <= 8.0);
            prev = o;
        }
        assert!(t.apply(3.0) > 2.0 && t.apply(3.0) < 3.0);
    }

    #[test]
    fn display_identity_and_monotone() {
        let t = ToneMap::display(0.0, 0.0, 0.0);
        for i in 1..=95 {
            let y = i as f32 / 100.0;
            assert!((t.apply(y) - y).abs() < 2e-3, "{y} -> {}", t.apply(y));
        }
        for (c, w, b) in [(100.0, 100.0, -100.0), (-100.0, -100.0, 100.0), (60.0, -40.0, 30.0)] {
            let t = ToneMap::display(c, w, b);
            let mut prev = -1.0;
            for i in 0..1000 {
                let o = t.apply(i as f32 / 500.0);
                assert!(o >= prev - 1e-5, "{c} {w} {b}");
                prev = o;
            }
        }
        let c = ToneMap::display(60.0, 0.0, 0.0);
        assert!(c.apply(0.05) < 0.05 && c.apply(0.7) > 0.7);
    }

    #[test]
    fn grey_stays_near_grey_and_highlights_roll_off() {
        let t = ToneMap::new(0.0, 0.0, 0.0);
        let g = t.apply(0.18);
        assert!((0.15..0.24).contains(&g), "{g}");
        assert!(t.apply(1.0) < 0.95 && t.apply(1.0) > 0.6);
        assert!(t.apply(8.0) > 0.97);
    }

    #[test]
    fn sliders_move_the_right_way() {
        let base = ToneMap::new(0.0, 0.0, 0.0);
        let contrast = ToneMap::new(60.0, 0.0, 0.0);
        assert!(contrast.apply(0.05) < base.apply(0.05));
        assert!(contrast.apply(0.8) > base.apply(0.8));
        assert!(ToneMap::new(0.0, 60.0, 0.0).apply(0.8) > base.apply(0.8));
        assert!(ToneMap::new(0.0, 0.0, -60.0).apply(0.01) < base.apply(0.01));
        assert!(ToneMap::new(0.0, 0.0, 60.0).apply(0.01) > base.apply(0.01));
    }

    #[test]
    fn fork_contrast_curve_is_monotone_fixes_black_grey_white_and_inverts() {
        for c in [-1.0f32, -0.6, -0.2, 0.2, 0.6, 1.0] {
            assert!(contrast_curve(0.0, c).abs() < 1e-5 && (contrast_curve(1.0, c) - 1.0).abs() < 1e-5, "{c}");
            assert!((contrast_curve(PIVOT, c) - PIVOT).abs() < 1e-5, "{c}: the pivot stays");
            let mut prev = -1.0;
            for i in 0..=1000 {
                let v = contrast_curve(i as f32 / 1000.0, c);
                assert!(v >= prev, "{c} at {i}");
                prev = v;
            }
            // −x undoes +x
            for p in [0.05f32, 0.3, 0.6, 0.9] {
                assert!((contrast_curve(contrast_curve(p, c), -c) - p).abs() < 1e-4, "{c} at {p}");
            }
        }
        // +100: about 1.6× the slope at the pivot, steeper than V1's display S-curve (≈ 1.35×)
        let h = 1e-3;
        let slope = (contrast_curve(PIVOT + h, 1.0) - contrast_curve(PIVOT - h, 1.0)) / (2.0 * h);
        assert!((slope - 1.58).abs() < 0.02, "{slope}");
        // Lightroom's +100 on the reference photo, within 0.015
        for (p, lr) in [(0.40f32, 0.296f32), (0.466, 0.382), (0.51, 0.453), (0.674, 0.684), (0.815, 0.877)] {
            assert!((contrast_curve(p, 1.0) - lr).abs() < 0.015, "{p}: {}", contrast_curve(p, 1.0));
        }
        assert!(contrast_curve(f32::NAN, 0.5).is_finite());
    }

    #[test]
    fn fork_whites_and_blacks_follow_lightroom() {
        let base = ToneMap::display_hdr(0.0, 0.0, 0.0, 1.0);
        let same = base.clone().with_fork_tone(0.0, 0.0, 0.0);
        assert_eq!((same.lut(), same.sat_lut().len()), (base.lut(), 0));
        // in display values: Whites +100 lifts a light grey a lot, −100 dims white; Blacks ±100 move the shadows
        let at = |m: &ToneMap, p: f32| m.apply(base_inverse(&base, p)).powf(1.0 / 2.2);
        let (wu, wd) = (base.clone().with_fork_tone(0.0, 100.0, 0.0), base.clone().with_fork_tone(0.0, -100.0, 0.0));
        let (bu, bd) = (base.clone().with_fork_tone(0.0, 0.0, 100.0), base.clone().with_fork_tone(0.0, 0.0, -100.0));
        assert!(at(&wu, 0.66) > 0.78 && at(&wd, 0.66) < 0.58, "{} {}", at(&wu, 0.66), at(&wd, 0.66));
        assert!(at(&bu, 0.1) > 0.18 && at(&bd, 0.2) < 0.03, "{} {}", at(&bu, 0.1), at(&bd, 0.2));
        // half strength sits between, and every map stays monotone
        let half = base.clone().with_fork_tone(0.0, 50.0, 0.0);
        assert!(at(&half, 0.66) > 0.68 && at(&half, 0.66) < at(&wu, 0.66));
        for m in [&wu, &wd, &bu, &bd, &half] {
            assert!(m.lut().windows(2).all(|w| w[1] >= w[0]));
        }
        assert!(bd.sat_scale(0.18) > 1.0 && wu.sat_scale(0.3) > 1.0);
    }

    /// The scene luminance `base` maps to display value `p` (gamma 2.2), by bisection.
    fn base_inverse(base: &ToneMap, p: f32) -> f32 {
        let target = p.powf(2.2);
        let (mut lo, mut hi) = (1e-6f32, 64.0f32);
        for _ in 0..60 {
            let mid = (lo * hi).sqrt();
            if base.apply(mid) < target { lo = mid } else { hi = mid }
        }
        (lo * hi).sqrt()
    }

    #[test]
    fn fork_contrast_is_identity_at_zero_and_couples_colour() {
        let base = ToneMap::hdr(0.0, 0.0, 0.0, 1.0);
        let same = base.clone().with_rgb_contrast(0.0);
        assert_eq!((same.lut(), same.sat_lut().len()), (base.lut(), 0));
        assert_eq!(same.sat_scale(0.18), 1.0);
        assert_eq!(base.clone().with_rgb_contrast(f64::NAN).sat_lut().len(), 0);
        let up = base.clone().with_rgb_contrast(100.0);
        let down = base.clone().with_rgb_contrast(-100.0);
        // darker shadows and midtones, brighter highlights
        assert!(up.apply(0.03) < base.apply(0.03) && up.apply(0.8) > base.apply(0.8));
        assert!(down.apply(0.03) > base.apply(0.03) && down.apply(0.8) < base.apply(0.8));
        // more contrast, more colour in the midtones; less, less
        assert!(up.sat_scale(0.18) > 1.4 && down.sat_scale(0.18) < 0.75, "{} {}", up.sat_scale(0.18), down.sat_scale(0.18));
        assert!([0.0, -1.0, f32::NAN, f32::INFINITY].iter().all(|y| up.sat_scale(*y) == 1.0));
        // monotone, bounded, and HDR above SDR white untouched
        let hdr = ToneMap::hdr(0.0, 0.0, 0.0, 4.0);
        let hup = hdr.clone().with_rgb_contrast(100.0);
        assert!(hup.lut().windows(2).all(|w| w[1] >= w[0]) && up.lut().windows(2).all(|w| w[1] >= w[0]));
        assert!(hup.lut().iter().zip(hdr.lut()).all(|(a, b)| *b < 1.0 || a == b));
        assert!(up.sat_lut().iter().all(|k| (0.5..=1.8).contains(k)));
    }
}
