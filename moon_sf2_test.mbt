///|
test "end-to-end SF2 + MIDI rendering to valid RIFF/WAVE" {
  let sb = @sf2.Sf2Builder::new(bank_name="Integration Bank")
  let pcm : Array[Int32] = []
  for i in 0..<100 {
    let phase = 2.0 * @math.PI * i.to_double() / 100.0
    pcm.push((@math.sin(phase) * 20000.0).to_int())
  }
  let smp = sb.add_sample("Tone", pcm, 44100, 69, loop_start=0, loop_end=100)
  let inst = sb.add_instrument("ToneInst", [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_range(@sf2.GEN_VEL_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 1),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, smp),
      ],
      modulators: [],
    },
  ])
  sb.add_preset("TonePreset", 0, 0, [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_INSTRUMENT, inst),
      ],
      modulators: [],
    },
  ])
  let sf2_bytes = sb.build()

  let mb = @midi.MidiBuilder::new(resolution=480)
  mb.add_tempo(0, 120)
  mb.add_note(0, 240, 0, 69, 100)
  let midi_bytes = mb.build()

  let wav = @moon_sf2.render_midi_to_wav(
    sf2_bytes,
    midi_bytes,
    sample_rate=22050,
    tail_seconds=0.1,
  )
  let riff = @moon_sf2.inspect_riff(wav)
  inspect(riff.id, content="RIFF")
  debug_inspect(riff.form_type, content="Some(\"WAVE\")")
  inspect(riff.find_child("fmt ") is Some(_), content="true")
  inspect(riff.find_child("data") is Some(_), content="true")
}
