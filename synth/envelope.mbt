///|
/// DAHDSR envelope phase.
#derive(Debug, Eq)
pub(all) enum EnvelopeStage {
  Delay
  Attack
  Hold
  Decay
  Sustain
  Release
  Finished
}

///|
pub extend EnvelopeStage with Eq::{equal, not_equal}

///|
pub extend EnvelopeStage with @debug.Debug::{to_repr}

///|
/// SF2 DAHDSR volume envelope generator.
pub struct VolumeEnvelope {
  sample_rate : Int32
  mut attack_slope : Double
  mut decay_slope : Double
  mut release_slope : Double
  mut attack_start_time : Double
  mut hold_start_time : Double
  mut decay_start_time : Double
  mut sustain_level : Double
  mut release_start_time : Double
  mut release_level : Double
  mut processed_samples : Int32
  mut stage : EnvelopeStage
  mut value : Double
  mut priority : Double
}

///|
pub fn VolumeEnvelope::new(sample_rate : Int32) -> VolumeEnvelope {
  {
    sample_rate,
    attack_slope: 0.0,
    decay_slope: 0.0,
    release_slope: 0.0,
    attack_start_time: 0.0,
    hold_start_time: 0.0,
    decay_start_time: 0.0,
    sustain_level: 1.0,
    release_start_time: 0.0,
    release_level: 0.0,
    processed_samples: 0,
    stage: Delay,
    value: 0.0,
    priority: 1.0,
  }
}

///|
pub fn VolumeEnvelope::start(
  self : VolumeEnvelope,
  delay : Double,
  attack : Double,
  hold : Double,
  decay : Double,
  sustain_db : Double,
  release : Double,
) -> Unit {
  let min_time = 0.001
  let eff_attack = if attack < min_time { min_time } else { attack }
  let eff_decay = if decay < min_time { min_time } else { decay }
  let eff_release = if release < min_time { min_time } else { release }
  self.attack_slope = 1.0 / eff_attack
  self.decay_slope = 1.0 / eff_decay
  self.release_slope = 1.0 / eff_release
  self.attack_start_time = delay
  self.hold_start_time = self.attack_start_time + eff_attack
  self.decay_start_time = self.hold_start_time + hold
  // SF2 sustainVolEnv is attenuation in dB (0..=144 dB -> linear 1..=0)
  self.sustain_level = clamp(
    @math.pow(10.0, -clamp(sustain_db, 0.0, 144.0) / 20.0),
    0.0,
    1.0,
  )
  self.release_start_time = 0.0
  self.release_level = 0.0
  self.processed_samples = 0
  self.stage = Delay
  self.value = 0.0
  self.priority = 1.0
  ignore(self.process(0))
}

///|
pub fn VolumeEnvelope::release(self : VolumeEnvelope) -> Unit {
  if self.stage != Release && self.stage != Finished {
    self.stage = Release
    self.release_start_time = self.processed_samples.to_double() /
      self.sample_rate.to_double()
    self.release_level = self.value
  }
}

///|
pub fn VolumeEnvelope::stage(self : VolumeEnvelope) -> EnvelopeStage {
  self.stage
}

///|
pub fn VolumeEnvelope::value(self : VolumeEnvelope) -> Double {
  self.value
}

///|
pub fn VolumeEnvelope::priority(self : VolumeEnvelope) -> Double {
  self.priority
}

///|
/// Advance the envelope by `sample_count` samples and return `true` while still active.
pub fn VolumeEnvelope::process(
  self : VolumeEnvelope,
  sample_count : Int32,
) -> Bool {
  self.processed_samples += sample_count
  let current_time = self.processed_samples.to_double() /
    self.sample_rate.to_double()
  while stage_rank(self.stage) <= 2 {
    let end_time = match self.stage {
      Delay => self.attack_start_time
      Attack => self.hold_start_time
      Hold => self.decay_start_time
      _ => break
    }
    if current_time < end_time {
      break
    }
    self.stage = match self.stage {
      Delay => Attack
      Attack => Hold
      Hold => Decay
      other => other
    }
  }
  match self.stage {
    Delay => {
      self.value = 0.0
      self.priority = 4.0 + self.value
      true
    }
    Attack => {
      self.value = clamp(
        self.attack_slope * (current_time - self.attack_start_time),
        0.0,
        1.0,
      )
      self.priority = 3.0 + self.value
      true
    }
    Hold => {
      self.value = 1.0
      self.priority = 2.0 + self.value
      true
    }
    Decay => {
      // SF2 decay descends linearly in dB (~100 dB dynamic range)
      self.value = @math.pow(
        10.0,
        -5.0 * self.decay_slope * (current_time - self.decay_start_time),
      )
      if self.value <= self.sustain_level {
        self.value = self.sustain_level
        self.stage = Sustain
      }
      self.priority = 1.0 + self.value
      true
    }
    Sustain => {
      self.value = self.sustain_level
      self.priority = 1.0 + self.value
      true
    }
    Release => {
      self.value = self.release_level *
        @math.pow(
          10.0,
          -5.0 * self.release_slope * (current_time - self.release_start_time),
        )
      if self.value <= 1.0e-5 {
        self.value = 0.0
        self.stage = Finished
        self.priority = 0.0
        false
      } else {
        self.priority = self.value
        true
      }
    }
    Finished => {
      self.value = 0.0
      self.priority = 0.0
      false
    }
  }
}

///|
fn stage_rank(s : EnvelopeStage) -> Int32 {
  match s {
    Delay => 0
    Attack => 1
    Hold => 2
    Decay => 3
    Sustain => 4
    Release => 5
    Finished => 6
  }
}

///|
/// SF2 DAHDSR modulation envelope generator (`0.0..=1.0`, linear decay/release).
pub struct ModulationEnvelope {
  sample_rate : Int32
  mut attack_slope : Double
  mut decay_slope : Double
  mut release_slope : Double
  mut attack_start_time : Double
  mut hold_start_time : Double
  mut decay_start_time : Double
  mut decay_end_time : Double
  mut sustain_level : Double
  mut release_end_time : Double
  mut release_level : Double
  mut processed_samples : Int32
  mut stage : EnvelopeStage
  mut value : Double
}

///|
pub fn ModulationEnvelope::new(sample_rate : Int32) -> ModulationEnvelope {
  {
    sample_rate,
    attack_slope: 0.0,
    decay_slope: 0.0,
    release_slope: 0.0,
    attack_start_time: 0.0,
    hold_start_time: 0.0,
    decay_start_time: 0.0,
    decay_end_time: 0.0,
    sustain_level: 1.0,
    release_end_time: 0.0,
    release_level: 0.0,
    processed_samples: 0,
    stage: Delay,
    value: 0.0,
  }
}

///|
pub fn ModulationEnvelope::start(
  self : ModulationEnvelope,
  delay : Double,
  attack : Double,
  hold : Double,
  decay : Double,
  sustain : Double,
  release : Double,
) -> Unit {
  self.attack_slope = 1.0 / (if attack < 0.001 { 0.001 } else { attack })
  self.decay_slope = 1.0 / (if decay < 0.001 { 0.001 } else { decay })
  self.release_slope = 1.0 / (if release < 0.001 { 0.001 } else { release })
  self.attack_start_time = delay
  self.hold_start_time = self.attack_start_time +
    (if attack < 0.001 { 0.001 } else { attack })
  self.decay_start_time = self.hold_start_time + hold
  self.decay_end_time = self.decay_start_time +
    (if decay < 0.001 { 0.001 } else { decay })
  self.sustain_level = clamp(sustain, 0.0, 1.0)
  self.release_end_time = 0.0
  self.release_level = 0.0
  self.processed_samples = 0
  self.stage = Delay
  self.value = 0.0
  ignore(self.process(0))
}

///|
pub fn ModulationEnvelope::release(self : ModulationEnvelope) -> Unit {
  if self.stage != Release && self.stage != Finished {
    self.stage = Release
    let current_time = self.processed_samples.to_double() /
      self.sample_rate.to_double()
    self.release_end_time = current_time + self.value / self.release_slope
    self.release_level = self.value
  }
}

///|
pub fn ModulationEnvelope::value(self : ModulationEnvelope) -> Double {
  self.value
}

///|
pub fn ModulationEnvelope::process(
  self : ModulationEnvelope,
  sample_count : Int32,
) -> Bool {
  self.processed_samples += sample_count
  let current_time = self.processed_samples.to_double() /
    self.sample_rate.to_double()
  while stage_rank(self.stage) <= 2 {
    let end_time = match self.stage {
      Delay => self.attack_start_time
      Attack => self.hold_start_time
      Hold => self.decay_start_time
      _ => break
    }
    if current_time < end_time {
      break
    }
    self.stage = match self.stage {
      Delay => Attack
      Attack => Hold
      Hold => Decay
      other => other
    }
  }
  match self.stage {
    Delay => {
      self.value = 0.0
      true
    }
    Attack => {
      self.value = clamp(
        self.attack_slope * (current_time - self.attack_start_time),
        0.0,
        1.0,
      )
      true
    }
    Hold => {
      self.value = 1.0
      true
    }
    Decay => {
      self.value = clamp(
        1.0 - self.decay_slope * (current_time - self.decay_start_time),
        0.0,
        1.0,
      )
      if self.value <= self.sustain_level {
        self.value = self.sustain_level
        self.stage = Sustain
      }
      true
    }
    Sustain => {
      self.value = self.sustain_level
      true
    }
    Release =>
      if self.release_end_time <= current_time {
        self.value = 0.0
        self.stage = Finished
        false
      } else {
        self.value = clamp(
          self.release_slope * (self.release_end_time - current_time),
          0.0,
          self.release_level,
        )
        true
      }
    Finished => {
      self.value = 0.0
      false
    }
  }
}
