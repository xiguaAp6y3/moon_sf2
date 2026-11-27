///|
/// Accumulated real-time modulator offsets computed per-block for an active voice.
pub(all) struct ModulatorOffsets {
  mut initial_filter_fc_cents : Double
  mut initial_filter_q_cb : Double
  mut vib_lfo_to_pitch_cents : Double
  mut mod_lfo_to_pitch_cents : Double
  mut mod_lfo_to_filter_fc_cents : Double
  mut initial_attenuation_cb : Double
  mut pan_tenths : Double
  mut reverb_send_tenths : Double
  mut chorus_send_tenths : Double
}

///|
pub fn ModulatorOffsets::zero() -> ModulatorOffsets {
  {
    initial_filter_fc_cents: 0.0,
    initial_filter_q_cb: 0.0,
    vib_lfo_to_pitch_cents: 0.0,
    mod_lfo_to_pitch_cents: 0.0,
    mod_lfo_to_filter_fc_cents: 0.0,
    initial_attenuation_cb: 0.0,
    pan_tenths: 0.0,
    reverb_send_tenths: 0.0,
    chorus_send_tenths: 0.0,
  }
}

///|
/// SF2 §8.2.4 concave shaping curve for normalized input `x` in `[0.0, 1.0]`.
pub fn sf2_concave(x : Double) -> Double {
  let c = clamp(x, 0.0, 1.0)
  if c >= 1.0 - 1.0e-9 {
    1.0
  } else if c <= 0.0 {
    0.0
  } else {
    clamp(-20.0 / 96.0 * 2.0 * @math.log10(1.0 - c), 0.0, 1.0)
  }
}

///|
/// SF2 §8.2.4 convex shaping curve for normalized input `x` in `[0.0, 1.0]`.
pub fn sf2_convex(x : Double) -> Double {
  1.0 - sf2_concave(1.0 - x)
}

///|
fn raw_source_value(
  src_oper : Int32,
  ch : ChannelState,
  key : Int32,
  velocity : Int32,
) -> Double {
  let index = src_oper & 0x7F
  let is_cc = (src_oper & 0x80) != 0
  if is_cc {
    match index {
      1 => ch.modulation_amount()
      7 => ch.volume_gain()
      10 => (ch.pan_position() + 1.0) * 0.5
      11 => ch.expression_gain()
      64 => if ch.hold_pedal { 1.0 } else { 0.0 }
      91 => ch.reverb_send.to_double() / 127.0
      93 => ch.chorus_send.to_double() / 127.0
      _ => 0.0
    }
  } else {
    match index {
      0 => 1.0 // NoController
      2 => clamp(velocity.to_double() / 127.0, 0.0, 1.0)
      3 => clamp(key.to_double() / 127.0, 0.0, 1.0)
      13 => clamp(ch.channel_pressure.to_double() / 127.0, 0.0, 1.0)
      14 => clamp((ch.pitch_bend + 1.0) * 0.5, 0.0, 1.0)
      16 => clamp(ch.pitch_bend_range.to_double() / 16383.0, 0.0, 1.0)
      _ => 0.0
    }
  }
}

///|
fn shape_modulator_source(
  src_oper : Int32,
  ch : ChannelState,
  key : Int32,
  velocity : Int32,
) -> Double {
  if (src_oper & 0x7F) == 0 && (src_oper & 0x80) == 0 {
    return 1.0
  }
  let mut v = raw_source_value(src_oper, ch, key, velocity)
  let dir_negative = (src_oper & 0x100) != 0
  let bipolar = (src_oper & 0x200) != 0
  let curve_type = (src_oper >> 10) & 0x03
  if dir_negative {
    v = 1.0 - v
  }
  let shaped = match curve_type {
    0 => v // Linear
    1 => sf2_concave(v) // Concave
    2 => sf2_convex(v) // Convex
    _ => if v >= 0.5 { 1.0 } else { 0.0 } // Switch
  }
  if bipolar {
    shaped * 2.0 - 1.0
  } else {
    shaped
  }
}

///|
fn apply_modulator(
  offsets : ModulatorOffsets,
  m : @sf2.Modulator,
  ch : ChannelState,
  key : Int32,
  velocity : Int32,
) -> Unit {
  if m.amount == 0 {
    return
  }
  let s1 = shape_modulator_source(m.src_oper, ch, key, velocity)
  let s2 = shape_modulator_source(m.amt_src_oper, ch, key, velocity)
  let raw_delta = s1 * s2 * m.amount.to_double()
  let delta = if m.trans_oper == 2 { raw_delta.abs() } else { raw_delta }
  match m.dest_oper {
    5 => offsets.mod_lfo_to_pitch_cents += delta
    6 => offsets.vib_lfo_to_pitch_cents += delta
    8 => offsets.initial_filter_fc_cents += delta
    9 => offsets.initial_filter_q_cb += delta
    10 => offsets.mod_lfo_to_filter_fc_cents += delta
    15 => offsets.chorus_send_tenths += delta
    16 => offsets.reverb_send_tenths += delta
    17 => offsets.pan_tenths += delta
    48 => offsets.initial_attenuation_cb += delta
    _ => ()
  }
}

///|
/// Evaluate SF2 §8.4 default modulators + zone-specific modulators.
pub fn evaluate_modulators(
  modulators : Array[@sf2.Modulator],
  ch : ChannelState,
  key : Int32,
  velocity : Int32,
) -> ModulatorOffsets {
  let offsets = ModulatorOffsets::zero()
  // Default modulator: Mod Wheel (CC#1) -> Vib LFO to Pitch (+50 cents)
  offsets.vib_lfo_to_pitch_cents += ch.modulation_amount() * 50.0
  // Default modulator: Channel Pressure -> Vib LFO to Pitch (+50 cents)
  offsets.vib_lfo_to_pitch_cents += ch.channel_pressure.to_double() /
    127.0 *
    50.0
  for m in modulators {
    apply_modulator(offsets, m, ch, key, velocity)
  }
  offsets
}
