///|
/// General MIDI per-channel controller and program state (`0..=15`).
pub struct ChannelState {
  is_percussion : Bool
  mut bank_number : Int32
  mut patch_number : Int32
  mut modulation : Int32
  mut volume : Int32
  mut pan : Int32
  mut expression : Int32
  mut hold_pedal : Bool
  mut reverb_send : Int32
  mut chorus_send : Int32
  mut rpn : Int32
  mut pitch_bend_range : Int32
  mut coarse_tune : Int32
  mut fine_tune : Int32
  mut pitch_bend : Double
}

///|
pub fn ChannelState::new(is_percussion : Bool) -> ChannelState {
  let ch = {
    is_percussion,
    bank_number: if is_percussion {
      128
    } else {
      0
    },
    patch_number: 0,
    modulation: 0,
    volume: 100 << 7,
    pan: 64 << 7,
    expression: 127 << 7,
    hold_pedal: false,
    reverb_send: 40,
    chorus_send: 0,
    rpn: -1,
    pitch_bend_range: 2 << 7,
    coarse_tune: 0,
    fine_tune: 8192,
    pitch_bend: 0.0,
  }
  ch
}

///|
pub fn ChannelState::reset(self : ChannelState) -> Unit {
  self.bank_number = if self.is_percussion { 128 } else { 0 }
  self.patch_number = 0
  self.reset_all_controllers()
}

///|
pub fn ChannelState::reset_all_controllers(self : ChannelState) -> Unit {
  self.modulation = 0
  self.volume = 100 << 7
  self.pan = 64 << 7
  self.expression = 127 << 7
  self.hold_pedal = false
  self.reverb_send = 40
  self.chorus_send = 0
  self.rpn = -1
  self.pitch_bend_range = 2 << 7
  self.coarse_tune = 0
  self.fine_tune = 8192
  self.pitch_bend = 0.0
}

///|
pub fn ChannelState::set_bank(self : ChannelState, value : Int32) -> Unit {
  self.bank_number = value
  if self.is_percussion {
    self.bank_number = self.bank_number + 128
  }
}

///|
pub fn ChannelState::set_patch(self : ChannelState, value : Int32) -> Unit {
  self.patch_number = value
}

///|
pub fn ChannelState::set_modulation_coarse(
  self : ChannelState,
  value : Int32,
) -> Unit {
  self.modulation = (self.modulation & 0x7F) | (value << 7)
}

///|
pub fn ChannelState::set_modulation_fine(
  self : ChannelState,
  value : Int32,
) -> Unit {
  self.modulation = (self.modulation & 0xFF80) | value
}

///|
pub fn ChannelState::set_volume_coarse(
  self : ChannelState,
  value : Int32,
) -> Unit {
  self.volume = (self.volume & 0x7F) | (value << 7)
}

///|
pub fn ChannelState::set_volume_fine(
  self : ChannelState,
  value : Int32,
) -> Unit {
  self.volume = (self.volume & 0xFF80) | value
}

///|
pub fn ChannelState::set_pan_coarse(self : ChannelState, value : Int32) -> Unit {
  self.pan = (self.pan & 0x7F) | (value << 7)
}

///|
pub fn ChannelState::set_pan_fine(self : ChannelState, value : Int32) -> Unit {
  self.pan = (self.pan & 0xFF80) | value
}

///|
pub fn ChannelState::set_expression_coarse(
  self : ChannelState,
  value : Int32,
) -> Unit {
  self.expression = (self.expression & 0x7F) | (value << 7)
}

///|
pub fn ChannelState::set_expression_fine(
  self : ChannelState,
  value : Int32,
) -> Unit {
  self.expression = (self.expression & 0xFF80) | value
}

///|
pub fn ChannelState::set_hold_pedal(self : ChannelState, value : Int32) -> Unit {
  self.hold_pedal = value >= 64
}

///|
pub fn ChannelState::set_reverb_send(
  self : ChannelState,
  value : Int32,
) -> Unit {
  self.reverb_send = value
}

///|
pub fn ChannelState::set_chorus_send(
  self : ChannelState,
  value : Int32,
) -> Unit {
  self.chorus_send = value
}

///|
pub fn ChannelState::set_rpn_coarse(self : ChannelState, value : Int32) -> Unit {
  self.rpn = (self.rpn & 0x7F) | (value << 7)
}

///|
pub fn ChannelState::set_rpn_fine(self : ChannelState, value : Int32) -> Unit {
  self.rpn = (self.rpn & 0xFF80) | value
}

///|
pub fn ChannelState::data_entry_coarse(
  self : ChannelState,
  value : Int32,
) -> Unit {
  match self.rpn {
    0 => self.pitch_bend_range = (self.pitch_bend_range & 0x7F) | (value << 7)
    1 => self.fine_tune = (self.fine_tune & 0x7F) | (value << 7)
    2 => self.coarse_tune = value - 64
    _ => ()
  }
}

///|
pub fn ChannelState::data_entry_fine(
  self : ChannelState,
  value : Int32,
) -> Unit {
  match self.rpn {
    0 => self.pitch_bend_range = (self.pitch_bend_range & 0xFF80) | value
    1 => self.fine_tune = (self.fine_tune & 0xFF80) | value
    _ => ()
  }
}

///|
pub fn ChannelState::set_pitch_bend(
  self : ChannelState,
  lsb : Int32,
  msb : Int32,
) -> Unit {
  let raw = (msb << 7) | lsb
  self.pitch_bend = (raw - 8192).to_double() / 8192.0
}

///|
/// Normalized channel volume `[0.0, 1.0]`.
pub fn ChannelState::volume_gain(self : ChannelState) -> Double {
  self.volume.to_double() / 16383.0
}

///|
/// Normalized channel expression `[0.0, 1.0]`.
pub fn ChannelState::expression_gain(self : ChannelState) -> Double {
  self.expression.to_double() / 16383.0
}

///|
/// Normalized channel pan `[-1.0, 1.0]`.
pub fn ChannelState::pan_position(self : ChannelState) -> Double {
  self.pan.to_double() / 16383.0 * 2.0 - 1.0
}

///|
/// Pitch bend offset in semitones.
pub fn ChannelState::pitch_bend_semitones(self : ChannelState) -> Double {
  let range_semitones = self.pitch_bend_range.to_double() / 128.0
  self.pitch_bend * range_semitones
}

///|
/// Normalized modulation wheel `[0.0, 1.0]`.
pub fn ChannelState::modulation_amount(self : ChannelState) -> Double {
  self.modulation.to_double() / 16383.0
}

///|
pub fn ChannelState::tune_cents(self : ChannelState) -> Double {
  self.coarse_tune.to_double() * 100.0 +
  (self.fine_tune - 8192).to_double() / 8192.0 * 100.0
}
