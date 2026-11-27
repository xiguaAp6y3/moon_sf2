///|
/// Self-contained demonstration of building an in-memory SoundFont2 wavetable bank,
/// sequencing a C-major MIDI arpeggio, and rendering stereo PCM + WAV output.
fn main {
  let sr = 44100
  let sb = @sf2.Sf2Builder::new(bank_name="MoonSF2 Demo Bank")
  let cycle = 100 // 441 Hz base wave at 44.1 kHz
  let pcm : Array[Int32] = []
  for i in 0..<cycle {
    let phase = 2.0 * @math.PI * i.to_double() / cycle.to_double()
    // Fundamental + 2nd & 3rd harmonics for a warm organ/brass-like timbre
    let s = @math.sin(phase) * 0.65 +
      @math.sin(phase * 2.0) * 0.25 +
      @math.sin(phase * 3.0) * 0.10
    pcm.push((s * 26000.0).to_int())
  }
  let smp = sb.add_sample("WarmWave", pcm, sr, 69, loop_start=0, loop_end=cycle)
  let inst = sb.add_instrument("WarmLead", [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_range(@sf2.GEN_VEL_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 1),
        @sf2.gen_val(@sf2.GEN_ATTACK_VOL_ENV, -6000),
        @sf2.gen_val(@sf2.GEN_RELEASE_VOL_ENV, -1800),
        @sf2.gen_val(@sf2.GEN_REVERB_EFFECTS_SEND, 250),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, smp),
      ],
      modulators: [],
    },
  ])
  sb.add_preset("Warm Lead", 0, 0, [
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
  mb.add_program_change(0, 0, 0)
  mb.add_note(0, 240, 0, 60, 100)
  mb.add_note(240, 240, 0, 64, 105)
  mb.add_note(480, 240, 0, 67, 110)
  mb.add_note(720, 480, 0, 72, 115)
  let midi_bytes = mb.build()

  try {
    let wav_bytes = @lib.render_midi_to_wav(
      sf2_bytes,
      midi_bytes,
      sample_rate=sr,
      tail_seconds=0.3,
    )
    let riff = @lib.inspect_riff(wav_bytes)
    println("moon_sf2 demo rendered successfully!")
    println("SF2 bytes: \{sf2_bytes.length()}")
    println("MIDI bytes: \{midi_bytes.length()}")
    println("WAV bytes: \{wav_bytes.length()} (container=\{riff.id})")
  } catch {
    err => println("Render failed: \{err}")
  }
}
