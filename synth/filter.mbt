///|
/// Second-order resonant low-pass Biquad filter matching SoundFont2 §8.1.3.
pub struct BiQuadFilter {
  sample_rate : Int32
  mut active : Bool
  mut a0 : Double
  mut a1 : Double
  mut a2 : Double
  mut a3 : Double
  mut a4 : Double
  mut x1 : Double
  mut x2 : Double
  mut y1 : Double
  mut y2 : Double
}

///|
pub fn BiQuadFilter::new(sample_rate : Int32) -> BiQuadFilter {
  {
    sample_rate,
    active: false,
    a0: 0.0,
    a1: 0.0,
    a2: 0.0,
    a3: 0.0,
    a4: 0.0,
    x1: 0.0,
    x2: 0.0,
    y1: 0.0,
    y2: 0.0,
  }
}

///|
pub fn BiQuadFilter::clear_buffer(self : BiQuadFilter) -> Unit {
  self.x1 = 0.0
  self.x2 = 0.0
  self.y1 = 0.0
  self.y2 = 0.0
}

///|
/// Update filter coefficients for cutoff frequency `cutoff_hz` and `resonance` (linear Q).
/// Bypassed automatically when cutoff approaches Nyquist (`>= 0.45 * sample_rate`).
pub fn BiQuadFilter::set_low_pass_filter(
  self : BiQuadFilter,
  cutoff_hz : Double,
  resonance : Double,
) -> Unit {
  if cutoff_hz < 0.45 * self.sample_rate.to_double() {
    self.active = true
    let q = if resonance > 0.001 { resonance } else { 0.001 }
    let w = 2.0 * @math.PI * cutoff_hz / self.sample_rate.to_double()
    let cosw = @math.cos(w)
    let alpha = @math.sin(w) / (2.0 * q)
    let b0 = (1.0 - cosw) * 0.5
    let b1 = 1.0 - cosw
    let b2 = b0
    let norm = 1.0 + alpha
    self.a0 = b0 / norm
    self.a1 = b1 / norm
    self.a2 = b2 / norm
    self.a3 = -2.0 * cosw / norm
    self.a4 = (1.0 - alpha) / norm
  } else {
    self.active = false
  }
}

///|
/// Process a sample block in place.
pub fn BiQuadFilter::process(
  self : BiQuadFilter,
  block : FixedArray[Double],
  count : Int32,
) -> Unit {
  if !self.active {
    return
  }
  for t in 0..<count {
    let input = block[t]
    let output = self.a0 * input +
      self.a1 * self.x1 +
      self.a2 * self.x2 -
      self.a3 * self.y1 -
      self.a4 * self.y2
    self.x2 = self.x1
    self.x1 = input
    self.y2 = self.y1
    self.y1 = output
    block[t] = output
  }
}
