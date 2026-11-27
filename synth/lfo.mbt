///|
/// SF2 triangle Low-Frequency Oscillator with programmable start delay.
pub struct Lfo {
  sample_rate : Int32
  mut active : Bool
  mut delay : Double
  mut period : Double
  mut processed_samples : Int32
  mut value : Double
}

///|
pub fn Lfo::new(sample_rate : Int32) -> Lfo {
  {
    sample_rate,
    active: false,
    delay: 0.0,
    period: 1.0,
    processed_samples: 0,
    value: 0.0,
  }
}

///|
pub fn Lfo::start(self : Lfo, delay : Double, frequency : Double) -> Unit {
  if frequency > 1.0e-3 {
    self.active = true
    self.delay = delay
    self.period = 1.0 / frequency
    self.processed_samples = 0
    self.value = 0.0
  } else {
    self.active = false
    self.value = 0.0
  }
}

///|
pub fn Lfo::value(self : Lfo) -> Double {
  self.value
}

///|
pub fn Lfo::process(self : Lfo, sample_count : Int32) -> Unit {
  if !self.active {
    return
  }
  self.processed_samples += sample_count
  let current_time = self.processed_samples.to_double() /
    self.sample_rate.to_double()
  if current_time < self.delay {
    self.value = 0.0
    return
  }
  let elapsed = current_time - self.delay
  let phase = (elapsed - @math.floor(elapsed / self.period) * self.period) /
    self.period
  // Triangle wave in [-1.0, +1.0]: 0 -> +1 at 0.25 -> 0 at 0.5 -> -1 at 0.75 -> 0 at 1.0
  if phase < 0.25 {
    self.value = 4.0 * phase
  } else if phase < 0.75 {
    self.value = 2.0 - 4.0 * phase
  } else {
    self.value = 4.0 * phase - 4.0
  }
}
