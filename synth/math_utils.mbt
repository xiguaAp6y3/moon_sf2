///|
/// Clamp a `Double` to `[lo, hi]`.
pub fn clamp(x : Double, lo : Double, hi : Double) -> Double {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
/// Clamp an `Int` to `[lo, hi]`.
pub fn clamp_int(x : Int32, lo : Int32, hi : Int32) -> Int32 {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
/// Convert SF2 timecents (`-12000..=8000+`) to seconds: `2^(tc / 1200)`.
pub fn timecents_to_seconds(tc : Double) -> Double {
  @math.pow(2.0, tc / 1200.0)
}

///|
/// Convert SF2 absolute cents to frequency in Hz: `8.176 * 2^(cents / 1200)`.
pub fn cents_to_hertz(cents : Double) -> Double {
  8.176 * @math.pow(2.0, cents / 1200.0)
}

///|
/// Convert relative cents (`1200` = 1 octave) to a frequency multiplying factor.
pub fn cents_to_multiplying_factor(cents : Double) -> Double {
  @math.pow(2.0, cents / 1200.0)
}

///|
/// Convert positive attenuation in centibels (`10` cB = `1` dB) to linear amplitude gain.
pub fn centibels_to_linear(cb : Double) -> Double {
  @math.pow(10.0, -cb / 200.0)
}

///|
/// Convert signed gain in centibels to linear amplitude factor: `10^(cb / 200)`.
pub fn centibels_to_gain(cb : Double) -> Double {
  @math.pow(10.0, cb / 200.0)
}

///|
/// Convert a MIDI key number (`69` = A4 = `440` Hz) to frequency in Hz.
pub fn midi_note_to_hertz(key : Double) -> Double {
  440.0 * @math.pow(2.0, (key - 69.0) / 12.0)
}

///|
/// Equal-power stereo pan law (`pan` in `[-1.0, 1.0]`) returning `(left_gain, right_gain)`.
pub fn stereo_pan_gains(pan : Double) -> (Double, Double) {
  let clamped = clamp(pan, -1.0, 1.0)
  let angle = (clamped + 1.0) * 0.25 * @math.PI
  (@math.cos(angle), @math.sin(angle))
}
