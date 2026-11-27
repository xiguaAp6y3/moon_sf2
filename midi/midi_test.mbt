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
  buf.write_bytes(trk_payload)
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
