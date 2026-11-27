///|
/// Errors raised while parsing Standard MIDI Files (`.mid`).
#derive(Debug, Eq)
pub(all) suberror MidiError {
  Riff(err~ : @riff.RiffError)
  InvalidHeader(expected~ : String, actual~ : String)
  UnsupportedDivision(raw~ : Int32)
  InvalidRunningStatus(offset~ : Int32)
  InvalidVlq(offset~ : Int32)
}

///|
pub impl Show for MidiError with fn output(self, logger) {
  match self {
    Riff(err~) => logger.write_string("MIDI read error: \{err}")
    InvalidHeader(expected~, actual~) =>
      logger.write_string(
        "Invalid MIDI header: expected '\{expected}', got '\{actual}'",
      )
    UnsupportedDivision(raw~) =>
      logger.write_string("Unsupported SMPTE MIDI time division: \{raw}")
    InvalidRunningStatus(offset~) =>
      logger.write_string("Invalid MIDI running status at offset \{offset}")
    InvalidVlq(offset~) =>
      logger.write_string(
        "Invalid variable-length quantity at offset \{offset}",
      )
  }
}

///|
pub extend MidiError with Show::{output, to_string}

///|
pub extend MidiError with Eq::{equal, not_equal}

///|
pub extend MidiError with @debug.Debug::{to_repr}

///|
/// Decoded MIDI event positioned at an absolute tick.
#derive(Debug, Eq)
pub(all) enum MidiMessageKind {
  ChannelEvent(
    channel~ : Int32,
    command~ : Int32,
    data1~ : Int32,
    data2~ : Int32
  )
  Tempo(microseconds_per_quarter~ : Int32)
  EndOfTrack
  Meta(meta_type~ : Int32)
  SysEx
}

///|
pub extend MidiMessageKind with Eq::{equal, not_equal}

///|
pub extend MidiMessageKind with @debug.Debug::{to_repr}

///|
/// Timed MIDI event (`tick` in PPQN units).
#derive(Debug, Eq)
pub(all) struct TimedMidiEvent {
  tick : Int32
  kind : MidiMessageKind
}

///|
pub extend TimedMidiEvent with Eq::{equal, not_equal}

///|
pub extend TimedMidiEvent with @debug.Debug::{to_repr}

///|
/// Parsed Standard MIDI File with merged timeline sorted by tick.
pub struct MidiFile {
  format : Int32
  track_count : Int32
  resolution : Int32
  events : Array[TimedMidiEvent]
  duration_seconds : Double
}

///|
fn read_vlq(r : @riff.ByteReader) -> Int32 raise MidiError {
  let mut val = 0
  for i in 0..<4 {
    let b = r.read_u8() catch { err => raise Riff(err~) }
    val = (val << 7) | (b & 0x7F)
    if (b & 0x80) == 0 {
      return val
    }
    if i == 3 {
      raise InvalidVlq(offset=r.position())
    }
  }
  val
}

///|
fn parse_track(
  data : Bytes,
  offset : Int32,
  length : Int32,
) -> Array[TimedMidiEvent] raise MidiError {
  let r = @riff.ByteReader::at(data, offset)
  let end_pos = offset + length
  let out : Array[TimedMidiEvent] = []
  let mut tick = 0
  let mut running_status = -1
  while r.position() < end_pos {
    let delta = read_vlq(r)
    tick += delta
    let first = r.read_u8() catch { err => raise Riff(err~) }
    let status = if (first & 0x80) != 0 {
      if first < 0xF0 {
        running_status = first
      }
      first
    } else {
      if running_status < 0 {
        raise InvalidRunningStatus(offset=r.position() - 1)
      }
      // Put back data1 by stepping cursor back 1 byte.
      r.seek(r.position() - 1) catch {
        err => raise Riff(err~)
      }
      running_status
    }
    if status == 0xFF {
      let meta_type = r.read_u8() catch { err => raise Riff(err~) }
      let len = read_vlq(r)
      if meta_type == 0x51 && len == 3 {
        let b0 = r.read_u8() catch { err => raise Riff(err~) }
        let b1 = r.read_u8() catch { err => raise Riff(err~) }
        let b2 = r.read_u8() catch { err => raise Riff(err~) }
        let us = (b0 << 16) | (b1 << 8) | b2
        out.push({ tick, kind: Tempo(microseconds_per_quarter=us), })
      } else {
        r.skip(len) catch {
          err => raise Riff(err~)
        }
        if meta_type == 0x2F {
          out.push({ tick, kind: EndOfTrack, })
          break
        } else {
          out.push({ tick, kind: Meta(meta_type~), })
        }
      }
    } else if status == 0xF0 || status == 0xF7 {
      let len = read_vlq(r)
      r.skip(len) catch {
        err => raise Riff(err~)
      }
      out.push({ tick, kind: SysEx, })
    } else {
      let cmd = status & 0xF0
      let ch = status & 0x0F
      let d1 = r.read_u8() catch { err => raise Riff(err~) }
      let d2 = if cmd == 0xC0 || cmd == 0xD0 {
        0
      } else {
        r.read_u8() catch {
          err => raise Riff(err~)
        }
      }
      out.push({
        tick,
        kind: ChannelEvent(channel=ch, command=cmd, data1=d1, data2=d2),
      })
    }
  }
  out
}

///|
fn compute_duration_seconds(
  events : Array[TimedMidiEvent],
  resolution : Int32,
) -> Double {
  let mut us_per_quarter = 500000 // default 120 BPM
  let mut last_tick = 0
  let mut elapsed = 0.0
  for ev in events {
    let dt = ev.tick - last_tick
    if dt > 0 {
      elapsed += dt.to_double() *
        (us_per_quarter.to_double() / 1_000_000.0) /
        resolution.to_double()
      last_tick = ev.tick
    }
    match ev.kind {
      Tempo(microseconds_per_quarter~) =>
        if microseconds_per_quarter > 0 {
          us_per_quarter = microseconds_per_quarter
        }
      _ => ()
    }
  }
  elapsed
}

///|
/// Parse a Standard MIDI File (`MThd` + `MTrk` chunks) from bytes.
pub fn parse_midi(data : Bytes) -> MidiFile raise MidiError {
  let r = @riff.ByteReader::new(data)
  let magic = r.read_fourcc() catch { err => raise Riff(err~) }
  if magic != "MThd" {
    raise InvalidHeader(expected="MThd", actual=magic)
  }
  let hdr_len = r.read_u32_be() catch { err => raise Riff(err~) }
  let format = r.read_u16_be() catch { err => raise Riff(err~) }
  let track_count = r.read_u16_be() catch { err => raise Riff(err~) }
  let division = r.read_u16_be() catch { err => raise Riff(err~) }
  if (division & 0x8000) != 0 || division <= 0 {
    raise UnsupportedDivision(raw=division)
  }
  let extra = hdr_len.reinterpret_as_int() - 6
  if extra > 0 {
    r.skip(extra) catch {
      err => raise Riff(err~)
    }
  }
  let merged : Array[TimedMidiEvent] = []
  for _ in 0..<track_count {
    let trk_magic = r.read_fourcc() catch { err => raise Riff(err~) }
    if trk_magic != "MTrk" {
      raise InvalidHeader(expected="MTrk", actual=trk_magic)
    }
    let trk_len = (r.read_u32_be() catch { err => raise Riff(err~) }).reinterpret_as_int()
    let trk_start = r.position()
    let trk_events = parse_track(data, trk_start, trk_len)
    for ev in trk_events {
      merged.push(ev)
    }
    r.seek(trk_start + trk_len) catch {
      err => raise Riff(err~)
    }
  }
  merged.sort_by((a, b) => a.tick.compare(b.tick))
  let duration_seconds = compute_duration_seconds(merged, division)
  {
    format,
    track_count,
    resolution: division,
    events: merged,
    duration_seconds,
  }
}

///|
/// Sample-accurate MIDI sequencer driving a `@synth.Synthesizer`.
pub struct MidiSequencer {
  synthesizer : @synth.Synthesizer
  midi : MidiFile
  mut loop_playback : Bool
  mut event_index : Int32
  mut current_time_sec : Double
  mut next_event_time_sec : Double
  mut us_per_quarter : Int32
  mut last_event_tick : Int32
}

///|
pub fn MidiSequencer::new(
  synthesizer : @synth.Synthesizer,
  midi : MidiFile,
  loop_playback~ : Bool = false,
) -> MidiSequencer {
  let seq = {
    synthesizer,
    midi,
    loop_playback,
    event_index: 0,
    current_time_sec: 0.0,
    next_event_time_sec: 0.0,
    us_per_quarter: 500000,
    last_event_tick: 0,
  }
  seq.schedule_next_event()
  seq
}

///|
pub fn MidiSequencer::set_loop(
  self : MidiSequencer,
  loop_playback : Bool,
) -> Unit {
  self.loop_playback = loop_playback
}

///|
pub fn MidiSequencer::is_finished(self : MidiSequencer) -> Bool {
  !self.loop_playback &&
  self.event_index >= self.midi.events.length() &&
  self.synthesizer.active_voice_count() == 0
}

///|
fn MidiSequencer::schedule_next_event(self : MidiSequencer) -> Unit {
  if self.event_index >= self.midi.events.length() {
    self.next_event_time_sec = 1.0e18
    return
  }
  let ev = self.midi.events[self.event_index]
  let dt_ticks = ev.tick - self.last_event_tick
  let dt_sec = if dt_ticks > 0 {
    dt_ticks.to_double() *
    (self.us_per_quarter.to_double() / 1_000_000.0) /
    self.midi.resolution.to_double()
  } else {
    0.0
  }
  self.next_event_time_sec = self.current_time_sec + dt_sec
}

///|
fn MidiSequencer::dispatch_due_events(self : MidiSequencer) -> Unit {
  while self.event_index < self.midi.events.length() &&
        self.next_event_time_sec <= self.current_time_sec + 1.0e-9 {
    let ev = self.midi.events[self.event_index]
    self.last_event_tick = ev.tick
    match ev.kind {
      ChannelEvent(channel~, command~, data1~, data2~) =>
        self.synthesizer.process_midi_message(channel, command, data1, data2)
      Tempo(microseconds_per_quarter~) =>
        if microseconds_per_quarter > 0 {
          self.us_per_quarter = microseconds_per_quarter
        }
      _ => ()
    }
    self.event_index += 1
    self.schedule_next_event()
  }
  if self.event_index >= self.midi.events.length() && self.loop_playback {
    self.synthesizer.note_off_all(immediate=false)
    self.event_index = 0
    self.last_event_tick = 0
    self.us_per_quarter = 500000
    self.schedule_next_event()
  }
}

///|
/// Render `frame_count` stereo samples, advancing MIDI events at sub-block boundaries.
pub fn MidiSequencer::render(
  self : MidiSequencer,
  left : FixedArray[Double],
  right : FixedArray[Double],
  frame_count : Int32,
) -> Unit {
  let sr = self.synthesizer.sample_rate().to_double()
  let step = 64
  let tmp_l = FixedArray::make(step, 0.0)
  let tmp_r = FixedArray::make(step, 0.0)
  let mut wrote = 0
  while wrote < frame_count {
    self.dispatch_due_events()
    let remain = frame_count - wrote
    let chunk = if remain < step { remain } else { step }
    self.synthesizer.render(tmp_l, tmp_r, chunk)
    for i in 0..<chunk {
      left[wrote + i] = tmp_l[i]
      right[wrote + i] = tmp_r[i]
    }
    wrote += chunk
    self.current_time_sec += chunk.to_double() / sr
  }
}

///|
/// Programmatic builder for generating Format-0/1 Standard MIDI File bytes.
pub struct MidiBuilder {
  resolution : Int32
  events : Array[TimedMidiEvent]
}

///|
pub fn MidiBuilder::new(resolution~ : Int32 = 480) -> MidiBuilder {
  { resolution, events: [], }
}

///|
pub fn MidiBuilder::add_tempo(
  self : MidiBuilder,
  tick : Int32,
  bpm : Int32,
) -> Unit {
  let us = 60_000_000 / (if bpm > 0 { bpm } else { 120 })
  self.events.push({ tick, kind: Tempo(microseconds_per_quarter=us), })
}

///|
pub fn MidiBuilder::add_program_change(
  self : MidiBuilder,
  tick : Int32,
  channel : Int32,
  program : Int32,
) -> Unit {
  self.events.push({
    tick,
    kind: ChannelEvent(channel~, command=0xC0, data1=program, data2=0),
  })
}

///|
pub fn MidiBuilder::add_control_change(
  self : MidiBuilder,
  tick : Int32,
  channel : Int32,
  controller : Int32,
  value : Int32,
) -> Unit {
  self.events.push({
    tick,
    kind: ChannelEvent(channel~, command=0xB0, data1=controller, data2=value),
  })
}

///|
pub fn MidiBuilder::add_pitch_bend(
  self : MidiBuilder,
  tick : Int32,
  channel : Int32,
  value_14bit : Int32,
) -> Unit {
  let clamped = if value_14bit < 0 {
    0
  } else if value_14bit > 16383 {
    16383
  } else {
    value_14bit
  }
  self.events.push({
    tick,
    kind: ChannelEvent(
      channel~,
      command=0xE0,
      data1=clamped & 0x7F,
      data2=(clamped >> 7) & 0x7F,
    ),
  })
}

///|
pub fn MidiBuilder::add_note(
  self : MidiBuilder,
  tick : Int32,
  duration_ticks : Int32,
  channel : Int32,
  key : Int32,
  velocity : Int32,
) -> Unit {
  self.events.push({
    tick,
    kind: ChannelEvent(channel~, command=0x90, data1=key, data2=velocity),
  })
  self.events.push({
    tick: tick + duration_ticks,
    kind: ChannelEvent(channel~, command=0x80, data1=key, data2=0),
  })
}

///|
fn write_vlq(buf : @buffer.Buffer, value : Int32) -> Unit {
  let v = if value < 0 { 0 } else { value }
  if v < 0x80 {
    buf.write_byte(v.to_byte())
  } else if v < 0x4000 {
    buf.write_byte((((v >> 7) & 0x7F) | 0x80).to_byte())
    buf.write_byte((v & 0x7F).to_byte())
  } else if v < 0x20_0000 {
    buf.write_byte((((v >> 14) & 0x7F) | 0x80).to_byte())
    buf.write_byte((((v >> 7) & 0x7F) | 0x80).to_byte())
    buf.write_byte((v & 0x7F).to_byte())
  } else {
    buf.write_byte((((v >> 21) & 0x7F) | 0x80).to_byte())
    buf.write_byte((((v >> 14) & 0x7F) | 0x80).to_byte())
    buf.write_byte((((v >> 7) & 0x7F) | 0x80).to_byte())
    buf.write_byte((v & 0x7F).to_byte())
  }
}

///|
/// Serialize recorded MIDI events into a single-track Format-0 SMF binary `Bytes`.
pub fn MidiBuilder::build(self : MidiBuilder) -> Bytes {
  let sorted = self.events.copy()
  sorted.sort_by((a, b) => a.tick.compare(b.tick))
  let trk = @buffer.Buffer()
  let mut last_tick = 0
  for ev in sorted {
    let dt = ev.tick - last_tick
    last_tick = ev.tick
    write_vlq(trk, dt)
    match ev.kind {
      ChannelEvent(channel~, command~, data1~, data2~) => {
        let status = (command & 0xF0) | (channel & 0x0F)
        trk.write_byte(status.to_byte())
        trk.write_byte((data1 & 0x7F).to_byte())
        if (command & 0xF0) != 0xC0 && (command & 0xF0) != 0xD0 {
          trk.write_byte((data2 & 0x7F).to_byte())
        }
      }
      Tempo(microseconds_per_quarter~) => {
        trk.write_byte(b'\xFF')
        trk.write_byte(b'\x51')
        trk.write_byte(b'\x03')
        trk.write_byte(((microseconds_per_quarter >> 16) & 0xFF).to_byte())
        trk.write_byte(((microseconds_per_quarter >> 8) & 0xFF).to_byte())
        trk.write_byte((microseconds_per_quarter & 0xFF).to_byte())
      }
      _ => ()
    }
  }
  write_vlq(trk, 0)
  trk.write_byte(b'\xFF')
  trk.write_byte(b'\x2F')
  trk.write_byte(b'\x00')
  let trk_bytes = trk.to_bytes()
  let out = @buffer.Buffer(size_hint=22 + trk_bytes.length())
  out.write_string_utf8("MThd")
  out.write_uint_be(6U)
  out.write_uint16_be(0U.to_uint16())
  out.write_uint16_be(1U.to_uint16())
  out.write_uint16_be(self.resolution.reinterpret_as_uint().to_uint16())
  out.write_string_utf8("MTrk")
  out.write_uint_be(trk_bytes.length().reinterpret_as_uint())
  out.write_bytes(trk_bytes)
  out.to_bytes()
}
