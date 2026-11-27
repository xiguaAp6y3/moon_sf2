///|
/// Configuration for creating a `Synthesizer`.
#derive(Debug, Eq)
pub(all) struct SynthSettings {
  sample_rate : Int32
  block_size : Int32
  maximum_polyphony : Int32
  enable_reverb_and_chorus : Bool
  master_volume : Double
  interpolation : InterpolationMode
}

///|
pub extend SynthSettings with Eq::{equal, not_equal}

///|
pub extend SynthSettings with @debug.Debug::{to_repr}

///|
pub fn SynthSettings::default(
  sample_rate~ : Int32 = 44100,
  interpolation~ : InterpolationMode = Cubic,
) -> SynthSettings {
  {
    sample_rate: clamp_int(sample_rate, 8000, 192000),
    block_size: 64,
    maximum_polyphony: 64,
    enable_reverb_and_chorus: true,
    master_volume: 0.5,
    interpolation,
  }
}

///|
/// Pure MoonBit General MIDI & SoundFont2 polyphonic synthesizer.
pub struct Synthesizer {
  sound_font : @sf2.SoundFont
  settings : SynthSettings
  channels : Array[ChannelState]
  voices : Array[Voice]
  preset_cache : Map[Int32, Array[@sf2.ZoneRegion]]
  block_left : FixedArray[Double]
  block_right : FixedArray[Double]
  rev_in_l : FixedArray[Double]
  rev_in_r : FixedArray[Double]
  rev_out_l : FixedArray[Double]
  rev_out_r : FixedArray[Double]
  cho_in_l : FixedArray[Double]
  cho_in_r : FixedArray[Double]
  cho_out_l : FixedArray[Double]
  cho_out_r : FixedArray[Double]
  reverb : Reverb
  chorus : Chorus
  mut block_read_index : Int32
}

///|
pub fn Synthesizer::new(
  sound_font : @sf2.SoundFont,
  settings~ : SynthSettings = SynthSettings::default(),
) -> Synthesizer {
  let channels : Array[ChannelState] = []
  for i in 0..<16 {
    channels.push(ChannelState::new(i == 9))
  }
  let voices : Array[Voice] = []
  for _ in 0..<settings.maximum_polyphony {
    voices.push(Voice::new(settings.sample_rate, settings.block_size))
  }
  let bs = settings.block_size
  {
    sound_font,
    settings,
    channels,
    voices,
    preset_cache: Map([]),
    block_left: FixedArray::make(bs, 0.0),
    block_right: FixedArray::make(bs, 0.0),
    rev_in_l: FixedArray::make(bs, 0.0),
    rev_in_r: FixedArray::make(bs, 0.0),
    rev_out_l: FixedArray::make(bs, 0.0),
    rev_out_r: FixedArray::make(bs, 0.0),
    cho_in_l: FixedArray::make(bs, 0.0),
    cho_in_r: FixedArray::make(bs, 0.0),
    cho_out_l: FixedArray::make(bs, 0.0),
    cho_out_r: FixedArray::make(bs, 0.0),
    reverb: Reverb::new(settings.sample_rate, bs),
    chorus: Chorus::new(settings.sample_rate),
    block_read_index: bs,
  }
}

///|
pub fn Synthesizer::sample_rate(self : Synthesizer) -> Int32 {
  self.settings.sample_rate
}

///|
/// Return the number of currently active voices.
pub fn Synthesizer::active_voice_count(self : Synthesizer) -> Int32 {
  let mut count = 0
  for v in self.voices {
    if v.state != Finished {
      count += 1
    }
  }
  count
}

///|
fn Synthesizer::get_regions(
  self : Synthesizer,
  bank : Int32,
  patch : Int32,
) -> Array[@sf2.ZoneRegion] {
  let key = (bank << 8) | patch
  match self.preset_cache.get(key) {
    Some(r) => r
    None => {
      let regions = match
        self.sound_font.find_preset(bank, patch, fallback_bank0=true) {
        Some(p) => self.sound_font.resolve_preset_regions(p)
        None =>
          match self.sound_font.find_preset(0, 0) {
            Some(p0) => self.sound_font.resolve_preset_regions(p0)
            None =>
              if self.sound_font.presets.length() > 0 {
                self.sound_font.resolve_preset_regions(
                  self.sound_font.presets[0],
                )
              } else {
                []
              }
          }
      }
      self.preset_cache[key] = regions
      regions
    }
  }
}

///|
fn Synthesizer::allocate_voice(self : Synthesizer) -> Voice {
  let mut best_idx = 0
  let mut lowest_prio = 1.0e9
  for i in 0..<self.voices.length() {
    let v = self.voices[i]
    if v.state == Finished {
      return v
    }
    let p = v.priority()
    if p < lowest_prio {
      lowest_prio = p
      best_idx = i
    }
  }
  self.voices[best_idx]
}

///|
/// Trigger a MIDI Note On (`channel` 0..15, `key` 0..127, `velocity` 0..127).
pub fn Synthesizer::note_on(
  self : Synthesizer,
  channel : Int32,
  key : Int32,
  velocity : Int32,
) -> Unit {
  if channel < 0 || channel >= 16 {
    return
  }
  if velocity <= 0 {
    self.note_off(channel, key)
    return
  }
  let ch = self.channels[channel]
  let regions = self.get_regions(ch.bank_number, ch.patch_number)
  for region in regions {
    if region.matches(key, velocity) {
      if region.exclusive_class > 0 {
        for v in self.voices {
          if v.state != Finished &&
            v.channel == channel &&
            v.exclusive_class == region.exclusive_class {
            v.kill()
          }
        }
      }
      let voice = self.allocate_voice()
      voice.start(
        self.sound_font.samples,
        self.sound_font.sample_headers,
        region,
        channel,
        key,
        velocity,
      )
    }
  }
}

///|
/// Trigger a MIDI Note Off on `channel` for `key`.
pub fn Synthesizer::note_off(
  self : Synthesizer,
  channel : Int32,
  key : Int32,
) -> Unit {
  if channel < 0 || channel >= 16 {
    return
  }
  let hold = self.channels[channel].hold_pedal
  for v in self.voices {
    if v.state == Playing && v.channel == channel && v.key == key {
      v.end_note(hold)
    }
  }
}

///|
/// Release all active notes (or only those on `channel` if `Some(ch)`).
pub fn Synthesizer::note_off_all(
  self : Synthesizer,
  immediate~ : Bool = false,
) -> Unit {
  for v in self.voices {
    if v.state != Finished {
      if immediate {
        v.kill()
      } else {
        v.end_note(false)
      }
    }
  }
}

///|
/// Reset all MIDI channels, voices, and DSP effect buffers.
pub fn Synthesizer::reset(self : Synthesizer) -> Unit {
  for ch in self.channels {
    ch.reset()
  }
  self.note_off_all(immediate=true)
  self.reverb.mute()
  self.chorus.mute()
  self.block_read_index = self.settings.block_size
}

///|
/// Dispatch a raw MIDI channel voice message (`command`: 0x80, 0x90, 0xB0, 0xC0, 0xE0).
pub fn Synthesizer::process_midi_message(
  self : Synthesizer,
  channel : Int32,
  command : Int32,
  data1 : Int32,
  data2 : Int32,
) -> Unit {
  if channel < 0 || channel >= 16 {
    return
  }
  let ch = self.channels[channel]
  match command & 0xF0 {
    0x80 => self.note_off(channel, data1)
    0x90 => self.note_on(channel, data1, data2)
    0xB0 =>
      match data1 {
        0 => ch.set_bank(data2)
        1 => ch.set_modulation_coarse(data2)
        6 => ch.data_entry_coarse(data2)
        7 => ch.set_volume_coarse(data2)
        10 => ch.set_pan_coarse(data2)
        11 => ch.set_expression_coarse(data2)
        33 => ch.set_modulation_fine(data2)
        38 => ch.data_entry_fine(data2)
        39 => ch.set_volume_fine(data2)
        42 => ch.set_pan_fine(data2)
        43 => ch.set_expression_fine(data2)
        64 => {
          ch.set_hold_pedal(data2)
          if !ch.hold_pedal {
            for v in self.voices {
              if v.channel == channel {
                v.release_hold()
              }
            }
          }
        }
        91 => ch.set_reverb_send(data2)
        93 => ch.set_chorus_send(data2)
        100 => ch.set_rpn_fine(data2)
        101 => ch.set_rpn_coarse(data2)
        120 =>
          for v in self.voices {
            if v.channel == channel {
              v.kill()
            }
          }
        121 => ch.reset_all_controllers()
        123 =>
          for v in self.voices {
            if v.channel == channel {
              v.end_note(false)
            }
          }
        _ => ()
      }
    0xC0 => ch.set_patch(data1)
    0xE0 => ch.set_pitch_bend(data1, data2)
    _ => ()
  }
}

///|
fn Synthesizer::render_block(self : Synthesizer) -> Unit {
  let bs = self.settings.block_size
  for t in 0..<bs {
    self.block_left[t] = 0.0
    self.block_right[t] = 0.0
    self.rev_in_l[t] = 0.0
    self.rev_in_r[t] = 0.0
    self.cho_in_l[t] = 0.0
    self.cho_in_r[t] = 0.0
  }
  for v in self.voices {
    if v.state != Finished {
      let ch = self.channels[v.channel]
      ignore(
        v.process(
          self.sound_font.samples,
          ch,
          self.block_left,
          self.block_right,
          self.rev_in_l,
          self.rev_in_r,
          self.cho_in_l,
          self.cho_in_r,
          bs,
          self.settings.enable_reverb_and_chorus,
          interpolation=self.settings.interpolation,
        ),
      )
    }
  }
  if self.settings.enable_reverb_and_chorus {
    self.chorus.process(
      self.cho_in_l,
      self.cho_in_r,
      self.cho_out_l,
      self.cho_out_r,
      bs,
    )
    self.reverb.process(
      self.rev_in_l,
      self.rev_in_r,
      self.rev_out_l,
      self.rev_out_r,
      bs,
    )
    for t in 0..<bs {
      self.block_left[t] = self.block_left[t] +
        self.cho_out_l[t] +
        self.rev_out_l[t]
      self.block_right[t] = self.block_right[t] +
        self.cho_out_r[t] +
        self.rev_out_r[t]
    }
  }
  let mv = self.settings.master_volume
  for t in 0..<bs {
    self.block_left[t] = clamp(self.block_left[t] * mv, -1.0, 1.0)
    self.block_right[t] = clamp(self.block_right[t] * mv, -1.0, 1.0)
  }
  self.block_read_index = 0
}

///|
/// Render `frame_count` stereo samples into `left` and `right` buffers.
pub fn Synthesizer::render(
  self : Synthesizer,
  left : FixedArray[Double],
  right : FixedArray[Double],
  frame_count : Int32,
) -> Unit {
  let bs = self.settings.block_size
  let mut wrote = 0
  while wrote < frame_count {
    if self.block_read_index >= bs {
      self.render_block()
    }
    let avail = bs - self.block_read_index
    let remain = frame_count - wrote
    let chunk = if avail < remain { avail } else { remain }
    for i in 0..<chunk {
      left[wrote + i] = self.block_left[self.block_read_index + i]
      right[wrote + i] = self.block_right[self.block_read_index + i]
    }
    self.block_read_index += chunk
    wrote += chunk
  }
}

///|
/// Encode stereo `Double` (`-1.0..=1.0`) buffers into a standard 16-bit PCM RIFF/WAV byte stream.
pub fn encode_wav_pcm16(
  left : FixedArray[Double],
  right : FixedArray[Double],
  frame_count : Int32,
  sample_rate : Int32,
) -> Bytes {
  let data_bytes = frame_count * 4
  let buf = @buffer.Buffer(size_hint=44 + data_bytes)
  buf.write_string_utf8("RIFF")
  buf.write_uint_le((36 + data_bytes).reinterpret_as_uint())
  buf.write_string_utf8("WAVE")
  buf.write_string_utf8("fmt ")
  buf.write_uint_le(16U)
  buf.write_uint16_le(1U.to_uint16()) // PCM
  buf.write_uint16_le(2U.to_uint16()) // Stereo
  buf.write_uint_le(sample_rate.reinterpret_as_uint())
  buf.write_uint_le((sample_rate * 4).reinterpret_as_uint())
  buf.write_uint16_le(4U.to_uint16()) // Block align
  buf.write_uint16_le(16U.to_uint16()) // Bits per sample
  buf.write_string_utf8("data")
  buf.write_uint_le(data_bytes.reinterpret_as_uint())
  for i in 0..<frame_count {
    let l = clamp(left[i], -1.0, 1.0)
    let r = clamp(right[i], -1.0, 1.0)
    let il = clamp_int((l * 32767.0).to_int(), -32768, 32767)
    let ir = clamp_int((r * 32767.0).to_int(), -32768, 32767)
    buf.write_int16_le(Int16::from_int(il))
    buf.write_int16_le(Int16::from_int(ir))
  }
  buf.to_bytes()
}
