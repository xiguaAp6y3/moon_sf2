///|
/// Sample resampling interpolation algorithm.
#derive(Debug, Eq)
pub(all) enum InterpolationMode {
  Linear
  Cubic
}

///|
pub extend InterpolationMode with Eq::{equal, not_equal}

///|
pub extend InterpolationMode with @debug.Debug::{to_repr}

///|
/// Lifecycle state of an active polyphonic voice.
#derive(Debug, Eq)
pub(all) enum VoiceState {
  Playing
  HoldRequested
  Released
  Finished
}

///|
pub extend VoiceState with Eq::{equal, not_equal}

///|
pub extend VoiceState with @debug.Debug::{to_repr}

///|
/// Single polyphonic SoundFont voice executing sample playback, DAHDSR envelopes,
/// dual LFOs, resonant low-pass Biquad filtering, and stereo/effect gain routing.
pub struct Voice {
  sample_rate : Int32
  block_size : Int32
  vol_env : VolumeEnvelope
  mod_env : ModulationEnvelope
  mod_lfo : Lfo
  vib_lfo : Lfo
  filter : BiQuadFilter
  block : FixedArray[Double]
  mut channel : Int32
  mut key : Int32
  mut velocity : Int32
  mut exclusive_class : Int32
  mut state : VoiceState
  mut note_gain : Double
  mut region_pan : Double
  mut region_reverb : Double
  mut region_chorus : Double
  mut initial_filter_fc_cents : Double
  mut filter_q_linear : Double
  mut mod_lfo_to_pitch : Double
  mut vib_lfo_to_pitch : Double
  mut mod_env_to_pitch : Double
  mut mod_lfo_to_filter_fc : Double
  mut mod_env_to_filter_fc : Double
  mut mod_lfo_to_volume : Double
  mut scale_tuning : Double
  mut root_key : Int32
  mut coarse_tune : Int32
  mut fine_tune : Int32
  mut pitch_correction : Int32
  mut sample_rate_src : Int32
  mut sample_start : Int32
  mut sample_end : Int32
  mut loop_start : Int32
  mut loop_end : Int32
  mut loop_mode : @sf2.LoopMode
  mut sample_pos : Double
  mut voice_length : Int32
  minimum_voice_length : Int32
  mut modulators : Array[@sf2.Modulator]
}

///|
pub fn Voice::new(sample_rate : Int32, block_size : Int32) -> Voice {
  {
    sample_rate,
    block_size,
    vol_env: VolumeEnvelope::new(sample_rate),
    mod_env: ModulationEnvelope::new(sample_rate),
    mod_lfo: Lfo::new(sample_rate),
    vib_lfo: Lfo::new(sample_rate),
    filter: BiQuadFilter::new(sample_rate),
    block: FixedArray::make(block_size, 0.0),
    channel: 0,
    key: 0,
    velocity: 0,
    exclusive_class: 0,
    state: Finished,
    note_gain: 0.0,
    region_pan: 0.0,
    region_reverb: 0.0,
    region_chorus: 0.0,
    initial_filter_fc_cents: 13500.0,
    filter_q_linear: 1.0,
    mod_lfo_to_pitch: 0.0,
    vib_lfo_to_pitch: 0.0,
    mod_env_to_pitch: 0.0,
    mod_lfo_to_filter_fc: 0.0,
    mod_env_to_filter_fc: 0.0,
    mod_lfo_to_volume: 0.0,
    scale_tuning: 100.0,
    root_key: 60,
    coarse_tune: 0,
    fine_tune: 0,
    pitch_correction: 0,
    sample_rate_src: 44100,
    sample_start: 0,
    sample_end: 0,
    loop_start: 0,
    loop_end: 0,
    loop_mode: NoLoop,
    sample_pos: 0.0,
    voice_length: 0,
    minimum_voice_length: sample_rate / 500,
    modulators: [],
  }
}

///|
pub fn Voice::start(
  self : Voice,
  samples : FixedArray[Double],
  sample_headers : Array[@sf2.SampleHeader],
  region : @sf2.ZoneRegion,
  channel : Int32,
  key : Int32,
  velocity : Int32,
) -> Unit {
  let hdr = sample_headers[region.sample_index]
  let eff_key = if region.keynum_override >= 0 {
    region.keynum_override
  } else {
    key
  }
  let eff_vel = if region.velocity_override >= 0 {
    region.velocity_override
  } else {
    velocity
  }
  self.channel = channel
  self.key = key
  self.velocity = eff_vel
  self.exclusive_class = region.exclusive_class
  self.state = Playing
  // Note gain: velocity^2 curve * initialAttenuation (with 0.4 * cB adjustment per FluidSynth/RustySynth convention)
  let vel_norm = eff_vel.to_double() / 127.0
  let vel_gain = vel_norm * vel_norm
  let atten_cb = clamp(region.initial_attenuation.to_double(), 0.0, 1440.0) *
    0.4
  self.note_gain = vel_gain * centibels_to_linear(atten_cb)
  self.region_pan = clamp(region.pan.to_double() / 500.0, -1.0, 1.0)
  self.region_reverb = clamp(region.reverb_send.to_double() / 1000.0, 0.0, 1.0)
  self.region_chorus = clamp(region.chorus_send.to_double() / 1000.0, 0.0, 1.0)
  self.initial_filter_fc_cents = clamp(
    region.initial_filter_fc.to_double(),
    1500.0,
    13500.0,
  )
  let q_db = clamp(region.initial_filter_q.to_double(), 0.0, 960.0) / 10.0
  self.filter_q_linear = @math.pow(10.0, (q_db - 3.01) / 20.0)
  self.mod_lfo_to_pitch = region.mod_lfo_to_pitch.to_double()
  self.vib_lfo_to_pitch = region.vib_lfo_to_pitch.to_double()
  self.mod_env_to_pitch = region.mod_env_to_pitch.to_double()
  self.mod_lfo_to_filter_fc = region.mod_lfo_to_filter_fc.to_double()
  self.mod_env_to_filter_fc = region.mod_env_to_filter_fc.to_double()
  self.mod_lfo_to_volume = region.mod_lfo_to_volume.to_double()
  self.scale_tuning = region.scale_tuning.to_double()
  self.root_key = if region.overriding_root_key >= 0 {
    region.overriding_root_key
  } else {
    hdr.original_pitch
  }
  self.coarse_tune = region.coarse_tune
  self.fine_tune = region.fine_tune
  self.pitch_correction = hdr.pitch_correction
  self.sample_rate_src = hdr.sample_rate
  let max_len = samples.length()
  self.sample_start = clamp_int(hdr.start + region.start_offset, 0, max_len)
  self.sample_end = clamp_int(
    hdr.end + region.end_offset,
    self.sample_start,
    max_len,
  )
  self.loop_start = clamp_int(
    hdr.start_loop + region.start_loop_offset,
    self.sample_start,
    self.sample_end,
  )
  self.loop_end = clamp_int(
    hdr.end_loop + region.end_loop_offset,
    self.loop_start,
    self.sample_end,
  )
  self.loop_mode = region.sample_modes
  self.sample_pos = self.sample_start.to_double()
  self.voice_length = 0
  self.modulators = region.modulators

  let key_offset = 60 - eff_key
  let vol_hold = timecents_to_seconds(
    (region.delay_vol_env +
    region.hold_vol_env +
    region.keynum_to_vol_env_hold * key_offset).to_double() -
    region.delay_vol_env.to_double(),
  )
  let vol_decay = timecents_to_seconds(
    (region.decay_vol_env + region.keynum_to_vol_env_decay * key_offset).to_double(),
  )
  self.vol_env.start(
    timecents_to_seconds(region.delay_vol_env.to_double()),
    timecents_to_seconds(region.attack_vol_env.to_double()),
    vol_hold,
    vol_decay,
    clamp(region.sustain_vol_env.to_double(), 0.0, 1440.0) / 10.0,
    timecents_to_seconds(region.release_vol_env.to_double()),
  )
  let mod_hold = timecents_to_seconds(
    (region.hold_mod_env + region.keynum_to_mod_env_hold * key_offset).to_double(),
  )
  let mod_decay = timecents_to_seconds(
    (region.decay_mod_env + region.keynum_to_mod_env_decay * key_offset).to_double(),
  )
  self.mod_env.start(
    timecents_to_seconds(region.delay_mod_env.to_double()),
    timecents_to_seconds(region.attack_mod_env.to_double()),
    mod_hold,
    mod_decay,
    1.0 - clamp(region.sustain_mod_env.to_double(), 0.0, 1000.0) / 1000.0,
    timecents_to_seconds(region.release_mod_env.to_double()),
  )
  self.mod_lfo.start(
    timecents_to_seconds(region.delay_mod_lfo.to_double()),
    cents_to_hertz(region.freq_mod_lfo.to_double()),
  )
  self.vib_lfo.start(
    timecents_to_seconds(region.delay_vib_lfo.to_double()),
    cents_to_hertz(region.freq_vib_lfo.to_double()),
  )
  self.filter.clear_buffer()
  let init_fc = cents_to_hertz(self.initial_filter_fc_cents)
  self.filter.set_low_pass_filter(init_fc, self.filter_q_linear)
}

///|
pub fn Voice::end_note(self : Voice, hold_pedal : Bool) -> Unit {
  if self.state == Playing {
    if hold_pedal {
      self.state = HoldRequested
    } else {
      self.state = Released
      self.vol_env.release()
      self.mod_env.release()
    }
  }
}

///|
pub fn Voice::release_hold(self : Voice) -> Unit {
  if self.state == HoldRequested {
    self.state = Released
    self.vol_env.release()
    self.mod_env.release()
  }
}

///|
pub fn Voice::kill(self : Voice) -> Unit {
  self.state = Finished
}

///|
pub fn Voice::priority(self : Voice) -> Double {
  if self.state == Finished {
    0.0
  } else if self.voice_length < self.minimum_voice_length {
    1000.0
  } else {
    self.vol_env.priority()
  }
}

///|
fn catmull_rom(
  p0 : Double,
  p1 : Double,
  p2 : Double,
  p3 : Double,
  t : Double,
) -> Double {
  let t2 = t * t
  let t3 = t2 * t
  0.5 *
  (
    2.0 * p1 +
    (-p0 + p2) * t +
    (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
    (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
  )
}

///|
fn Voice::fill_samples(
  self : Voice,
  samples : FixedArray[Double],
  pitch_ratio : Double,
  count : Int32,
  interpolation : InterpolationMode,
) -> Bool {
  let is_looping = match self.loop_mode {
    LoopContinuous => self.loop_end > self.loop_start
    LoopUntilRelease =>
      self.state != Released && self.loop_end > self.loop_start
    NoLoop => false
  }
  let loop_len_int = self.loop_end - self.loop_start
  let loop_len = loop_len_int.to_double()
  let mut t = 0
  while t < count {
    if is_looping {
      while self.sample_pos >= self.loop_end.to_double() {
        self.sample_pos = self.sample_pos - loop_len
      }
      let idx1 = self.sample_pos.to_int()
      let frac = self.sample_pos - idx1.to_double()
      match interpolation {
        Linear => {
          let idx2 = if idx1 + 1 >= self.loop_end {
            self.loop_start
          } else {
            idx1 + 1
          }
          let s1 = samples[idx1]
          let s2 = samples[idx2]
          self.block[t] = s1 + frac * (s2 - s1)
        }
        Cubic => {
          let rel = idx1 - self.loop_start
          let idx0 = self.loop_start + (rel - 1 + loop_len_int) % loop_len_int
          let idx2 = self.loop_start + (rel + 1) % loop_len_int
          let idx3 = self.loop_start + (rel + 2) % loop_len_int
          self.block[t] = catmull_rom(
            samples[idx0],
            samples[idx1],
            samples[idx2],
            samples[idx3],
            frac,
          )
        }
      }
      self.sample_pos = self.sample_pos + pitch_ratio
    } else {
      if self.sample_pos >= (self.sample_end - 1).to_double() {
        for z in t..<count {
          self.block[z] = 0.0
        }
        return false
      }
      let idx1 = self.sample_pos.to_int()
      let frac = self.sample_pos - idx1.to_double()
      match interpolation {
        Linear => {
          let s1 = samples[idx1]
          let s2 = samples[idx1 + 1]
          self.block[t] = s1 + frac * (s2 - s1)
        }
        Cubic => {
          let idx0 = if idx1 > self.sample_start { idx1 - 1 } else { idx1 }
          let idx2 = idx1 + 1
          let idx3 = if idx1 + 2 < self.sample_end { idx1 + 2 } else { idx2 }
          self.block[t] = catmull_rom(
            samples[idx0],
            samples[idx1],
            samples[idx2],
            samples[idx3],
            frac,
          )
        }
      }
      self.sample_pos = self.sample_pos + pitch_ratio
    }
    t += 1
  }
  true
}

///|
/// Render up to `count` (`<= block_size`) samples into dry & effect buses.
/// Returns `true` if voice stays alive, `false` if finished.
pub fn Voice::process(
  self : Voice,
  samples : FixedArray[Double],
  ch : ChannelState,
  dry_l : FixedArray[Double],
  dry_r : FixedArray[Double],
  rev_l : FixedArray[Double],
  rev_r : FixedArray[Double],
  cho_l : FixedArray[Double],
  cho_r : FixedArray[Double],
  count : Int32,
  enable_effects : Bool,
  interpolation~ : InterpolationMode = Linear,
) -> Bool {
  if self.state == Finished {
    return false
  }
  if !self.vol_env.process(count) {
    self.state = Finished
    return false
  }
  ignore(self.mod_env.process(count))
  self.mod_lfo.process(count)
  self.vib_lfo.process(count)
  let mods = evaluate_modulators(self.modulators, ch, self.key, self.velocity)

  // Pitch calculation in semitones -> ratio
  let eff_key = self.key
  let pitch_cents = (eff_key - self.root_key).to_double() * self.scale_tuning +
    self.coarse_tune.to_double() * 100.0 +
    self.fine_tune.to_double() +
    self.pitch_correction.to_double() +
    ch.pitch_bend_semitones() * 100.0 +
    ch.tune_cents() +
    self.mod_env.value() * self.mod_env_to_pitch +
    self.mod_lfo.value() * (self.mod_lfo_to_pitch + mods.mod_lfo_to_pitch_cents) +
    self.vib_lfo.value() * (self.vib_lfo_to_pitch + mods.vib_lfo_to_pitch_cents)
  let pitch_ratio = cents_to_multiplying_factor(pitch_cents) *
    (self.sample_rate_src.to_double() / self.sample_rate.to_double())

  let has_more_audio = self.fill_samples(
    samples, pitch_ratio, count, interpolation,
  )

  // Dynamic resonant low-pass filter update
  let fc_cents = clamp(
    self.initial_filter_fc_cents +
    mods.initial_filter_fc_cents +
    self.mod_env.value() * self.mod_env_to_filter_fc +
    self.mod_lfo.value() *
    (self.mod_lfo_to_filter_fc + mods.mod_lfo_to_filter_fc_cents),
    1500.0,
    13500.0,
  )
  self.filter.set_low_pass_filter(
    cents_to_hertz(fc_cents),
    self.filter_q_linear,
  )
  self.filter.process(self.block, count)

  let mod_lfo_gain = centibels_to_gain(
    self.mod_lfo.value() * self.mod_lfo_to_volume,
  )
  let mod_atten_gain = centibels_to_linear(
    clamp(mods.initial_attenuation_cb, 0.0, 1440.0) * 0.4,
  )
  let master_gain = self.note_gain *
    mod_atten_gain *
    self.vol_env.value() *
    mod_lfo_gain *
    ch.volume_gain() *
    ch.expression_gain()

  let total_pan = clamp(
    self.region_pan + mods.pan_tenths / 500.0 + ch.pan_position(),
    -1.0,
    1.0,
  )
  let (pan_l, pan_r) = stereo_pan_gains(total_pan)
  let gain_l = master_gain * pan_l
  let gain_r = master_gain * pan_r

  for t in 0..<count {
    let s = self.block[t]
    dry_l[t] = dry_l[t] + s * gain_l
    dry_r[t] = dry_r[t] + s * gain_r
  }
  if enable_effects {
    let rev_send = clamp(
      self.region_reverb + ch.reverb_send.to_double() / 127.0,
      0.0,
      1.0,
    )
    let cho_send = clamp(
      self.region_chorus + ch.chorus_send.to_double() / 127.0,
      0.0,
      1.0,
    )
    if rev_send > 0.001 {
      let rl = gain_l * rev_send
      let rr = gain_r * rev_send
      for t in 0..<count {
        let s = self.block[t]
        rev_l[t] = rev_l[t] + s * rl
        rev_r[t] = rev_r[t] + s * rr
      }
    }
    if cho_send > 0.001 {
      let cl = gain_l * cho_send
      let cr = gain_r * cho_send
      for t in 0..<count {
        let s = self.block[t]
        cho_l[t] = cho_l[t] + s * cl
        cho_r[t] = cho_r[t] + s * cr
      }
    }
  }
  self.voice_length += count
  if !has_more_audio {
    self.state = Finished
    false
  } else {
    true
  }
}
