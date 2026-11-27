///|
test "MidiBuilder roundtrip, VLQ, tempo duration, and sequencer rendering" {
  let mb = @midi.MidiBuilder::new(resolution=480)
  mb.add_tempo(0, 120)
  mb.add_program_change(0, 0, 0)
  mb.add_note(0, 240, 0, 60, 100)
  mb.add_note(240, 240, 0, 64, 100)
  mb.add_note(480, 480, 0, 67, 110)
  let midi_bytes = mb.build()
  let mf = @midi.parse_midi(midi_bytes)
  inspect(mf.format, content="0")
  inspect(mf.track_count, content="1")
  inspect(mf.resolution, content="480")
  // 960 ticks at 120 BPM (480 PPQN) = 1.0 second
  inspect((mf.duration_seconds - 1.0).abs() < 1.0e-6, content="true")

  // Build simple SF2 and render MIDI through MidiSequencer
  let sb = @sf2.Sf2Builder::new(bank_name="Seq Bank")
  let pcm : Array[Int32] = []
  for i in 0..<100 {
    let angle = 2.0 * 3.141592653589793 * i.to_double() / 100.0
    pcm.push((@math.sin(angle) * 24000.0).to_int())
  }
  let smp = sb.add_sample("Wave", pcm, 44100, 69, loop_start=0, loop_end=100)
  let inst = sb.add_instrument("Lead", [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_range(@sf2.GEN_VEL_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 1),
        @sf2.gen_val(@sf2.GEN_RELEASE_VOL_ENV, -2400),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, smp),
      ],
      modulators: [],
    },
  ])
  sb.add_preset("Lead", 0, 0, [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_INSTRUMENT, inst),
      ],
      modulators: [],
    },
  ])
  let sf = @sf2.parse_sf2(sb.build())
  let syn = @synth.Synthesizer::new(
    sf,
    settings=@synth.SynthSettings::default(sample_rate=22050),
  )
  let seq = @midi.MidiSequencer::new(syn, mf)
  let n = 22050
  let left = FixedArray::make(n, 0.0)
  let right = FixedArray::make(n, 0.0)
  seq.render(left, right, n)
  let mut energy = 0.0
  for i in 0..<n {
    energy += left[i] * left[i] + right[i] * right[i]
  }
  inspect(energy > 1.0, content="true")
}

///|
test "parse_midi handles running status" {
  // Hand-crafted MThd + MTrk with running status NoteOn C4 -> E4
  let buf = @buffer.Buffer()
  buf.write_string_utf8("MThd")
  buf.write_uint_be(6U)
  buf.write_uint16_be(0U.to_uint16())
  buf.write_uint16_be(1U.to_uint16())
  buf.write_uint16_be(480U.to_uint16())
  buf.write_string_utf8("MTrk")
  // Track: delta 0, 0x90 60 100 | delta 10, 64 100 (running status) | delta 0, FF 2F 00
  let trk_payload = b"\x00\x90\x3c\x64\x0a\x40\x64\x00\xff\x2f\x00"
  buf.write_uint_be(trk_payload.length().reinterpret_as_uint())
  buf.write_bytesview(trk_payload)
  let mf = @midi.parse_midi(buf.to_bytes())
  inspect(mf.events.length(), content="3")
  debug_inspect(
    mf.events[1],
    content=(
      #|{
      #|  tick: 10,
      #|  kind: ChannelEvent(channel=0, command=144, data1=64, data2=100),
      #|}
    ),
  )
}

///|
test "MidiBuilder CC/PitchBend and mid-song tempo change duration" {
  let mb = @midi.MidiBuilder::new(resolution=480)
  mb.add_tempo(0, 120) // 0..480 ticks = 0.5 s
  mb.add_control_change(0, 0, 10, 0) // hard left pan
  mb.add_pitch_bend(0, 0, 8192)
  mb.add_note(0, 480, 0, 60, 100)
  mb.add_tempo(480, 60) // 480..960 ticks = 1.0 s
  mb.add_note(480, 480, 0, 64, 100)
  let mf = @midi.parse_midi(mb.build())
  // Total = 0.5 + 1.0 = 1.5 s
  inspect((mf.duration_seconds - 1.5).abs() < 1.0e-6, content="true")
}

///|
fn make_mtrk(payload : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_string_utf8("MTrk")
  buf.write_uint_be(payload.length().reinterpret_as_uint())
  buf.write_bytesview(payload)
  buf.to_bytes()
}

///|
test "parse_midi handles multi-track SMF Type-1, SysEx, Meta, and sequencer loop/is_finished" {
  let out = @buffer.Buffer()
  out.write_string_utf8("MThd")
  out.write_uint_be(6U)
  out.write_uint16_be(1U.to_uint16()) // Format 1 (multi-track)
  out.write_uint16_be(3U.to_uint16()) // 3 tracks
  out.write_uint16_be(480U.to_uint16())
  // Track 0: tempo 120 BPM (07 A1 20) at tick 0, Meta Text at tick 0, tempo 60 BPM (0F 42 40) at tick 480, EOT
  out.write_bytesview(
    make_mtrk(
      b"\x00\xff\x51\x03\x07\xa1\x20\x00\xff\x01\x02hi\x83\x60\xff\x51\x03\x0f\x42\x40\x00\xff\x2f\x00",
    ),
  )
  // Track 1: SysEx at tick 0, NoteOn ch0 C4 at tick 240, NoteOff ch0 C4 at tick 720, EOT
  out.write_bytesview(
    make_mtrk(
      b"\x00\xf0\x02\x7e\x7f\x81\x70\x90\x3c\x64\x83\x60\x80\x3c\x00\x00\xff\x2f\x00",
    ),
  )
  // Track 2: ProgramChange ch1 at tick 0, NoteOn ch1 E4 at tick 120, NoteOff at tick 960, EOT
  out.write_bytesview(
    make_mtrk(
      b"\x00\xc1\x05\x78\x91\x40\x6e\x86\x48\x81\x40\x00\x00\xff\x2f\x00",
    ),
  )
  let mf = @midi.parse_midi(out.to_bytes())
  inspect(mf.format, content="1")
  inspect(mf.track_count, content="3")
  // Verify merged events are monotonically sorted by tick
  let mut prev_tick = 0
  let mut has_sysex = false
  let mut has_meta = false
  for ev in mf.events {
    inspect(ev.tick >= prev_tick, content="true")
    prev_tick = ev.tick
    match ev.kind {
      SysEx => has_sysex = true
      Meta(meta_type=1) => has_meta = true
      _ => ()
    }
  }
  inspect(has_sysex, content="true")
  inspect(has_meta, content="true")
  // 0..480 at 120 BPM (0.5 s) + 480..960 at 60 BPM (1.0 s) = 1.5 s
  inspect((mf.duration_seconds - 1.5).abs() < 1.0e-6, content="true")

  // Test MidiSequencer::is_finished and set_loop
  let mb = @midi.MidiBuilder::new(resolution=480)
  mb.add_tempo(0, 120)
  mb.add_note(0, 120, 0, 69, 100) // 0.125 s note
  let short_mf = @midi.parse_midi(mb.build())
  let sb = @sf2.Sf2Builder::new(bank_name="LoopSeq")
  let pcm : Array[Int32] = []
  for i in 0..<100 {
    let phase = 2.0 * @math.PI * i.to_double() / 100.0
    pcm.push((@math.sin(phase) * 20000.0).to_int())
  }
  let smp = sb.add_sample("S", pcm, 44100, 69, loop_start=0, loop_end=100)
  let inst = sb.add_instrument("I", [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 1),
        @sf2.gen_val(@sf2.GEN_ATTACK_VOL_ENV, -12000),
        @sf2.gen_val(@sf2.GEN_RELEASE_VOL_ENV, -6000),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, smp),
      ],
      modulators: [],
    },
  ])
  sb.add_preset("P", 0, 0, [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_INSTRUMENT, inst),
      ],
      modulators: [],
    },
  ])
  let sf = @sf2.parse_sf2(sb.build())
  let syn = @synth.Synthesizer::new(
    sf,
    settings=@synth.SynthSettings::default(sample_rate=22050),
  )
  let seq = @midi.MidiSequencer::new(syn, short_mf)
  seq.set_loop(true)
  let l = FixedArray::make(4096, 0.0)
  let r = FixedArray::make(4096, 0.0)
  // Render 0.37s (> 0.125s note) while looping -> must not finish
  seq.render(l, r, 4096)
  seq.render(l, r, 4096)
  inspect(seq.is_finished(), content="false")
  // Disable looping and render until finished
  seq.set_loop(false)
  for _ in 0..<4 {
    seq.render(l, r, 4096)
  }
  inspect(seq.is_finished(), content="true")
}

///|
test "parse_midi error paths" {
  // Invalid MThd header
  try @midi.parse_midi(b"RIFF\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0") catch {
    err =>
      inspect(err.to_string().contains("Invalid MIDI header"), content="true")
  } noraise {
    _ => fail("expected InvalidHeader MThd")
  }
  // Unsupported SMPTE division (0x8000 bit set)
  try @midi.parse_midi(b"MThd\x00\x00\x00\x06\x00\x00\x00\x01\x80\x18") catch {
    err =>
      inspect(
        err.to_string().contains("Unsupported SMPTE MIDI time division"),
        content="true",
      )
  } noraise {
    _ => fail("expected UnsupportedDivision")
  }
  // Invalid MTrk header
  try
    @midi.parse_midi(
      b"MThd\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0BAD!\x00\x00\x00\x00",
    )
  catch {
    err => inspect(err.to_string().contains("expected 'MTrk'"), content="true")
  } noraise {
    _ => fail("expected InvalidHeader MTrk")
  }
  // Invalid running status (data byte before any status byte)
  try
    @midi.parse_midi(
      b"MThd\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0MTrk\x00\x00\x00\x03\x00\x40\x64",
    )
  catch {
    err =>
      inspect(
        err.to_string().contains("Invalid MIDI running status"),
        content="true",
      )
  } noraise {
    _ => fail("expected InvalidRunningStatus")
  }
  // Invalid VLQ (4 consecutive bytes with 0x80 set)
  try
    @midi.parse_midi(
      b"MThd\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0MTrk\x00\x00\x00\x04\x80\x80\x80\x80",
    )
  catch {
    err =>
      inspect(
        err.to_string().contains("Invalid variable-length quantity"),
        content="true",
      )
  } noraise {
    _ => fail("expected InvalidVlq")
  }
}
