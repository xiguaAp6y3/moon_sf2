///|
fn build_sine_sf2() -> @sf2.SoundFont raise @sf2.Sf2Error {
  let builder = @sf2.Sf2Builder::new(bank_name="Sine Test Bank")
  let sr = 44100
  let cycle_len = 100 // 441 Hz at 44100 Hz -> close to A4
  let pcm : Array[Int32] = []
  for i in 0..<cycle_len {
    let angle = 2.0 * @math.PI * i.to_double() / cycle_len.to_double()
    pcm.push((@math.sin(angle) * 28000.0).to_int())
  }
  let smp = builder.add_sample(
    "Sine441",
    pcm,
    sr,
    69,
    loop_start=0,
    loop_end=cycle_len,
  )
  let inst_idx = builder.add_instrument("SineLead", [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_range(@sf2.GEN_VEL_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 1),
        @sf2.gen_val(@sf2.GEN_ATTACK_VOL_ENV, -12000),
        @sf2.gen_val(@sf2.GEN_RELEASE_VOL_ENV, -2400),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, smp),
      ],
      modulators: [],
    },
  ])
  builder.add_preset("Sine Preset", 0, 0, [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_INSTRUMENT, inst_idx),
      ],
      modulators: [],
    },
  ])
  @sf2.parse_sf2(builder.build())
}

///|
test "SF2 math unit conversions match spec" {
  let a4 = @synth.midi_note_to_hertz(69.0)
  inspect((a4 - 440.0).abs() < 1.0e-9, content="true")
  let fc = @synth.cents_to_hertz(6900.0)
  // 8.176 * 2^(6900/1200) = 440.005...
  inspect((fc - 440.0).abs() < 0.05, content="true")
  let t0 = @synth.timecents_to_seconds(0.0)
  inspect((t0 - 1.0).abs() < 1.0e-9, content="true")
  let half_db = @synth.centibels_to_linear(200.0) // -20 dB = 0.1
  inspect((half_db - 0.1).abs() < 1.0e-9, content="true")
}

///|
test "VolumeEnvelope DAHDSR progression and release" {
  let env = @synth.VolumeEnvelope::new(1000)
  env.start(0.01, 0.02, 0.01, 0.05, 12.0, 0.05)
  debug_inspect(env.stage(), content="Delay")
  ignore(env.process(15))
  debug_inspect(env.stage(), content="Attack")
  ignore(env.process(20))
  debug_inspect(env.stage(), content="Hold")
  ignore(env.process(5))
  debug_inspect(env.stage(), content="Decay")
  ignore(env.process(10))
  debug_inspect(env.stage(), content="Sustain")
  env.release()
  debug_inspect(env.stage(), content="Release")
  let mut alive = true
  for _ in 0..<20 {
    alive = env.process(50)
  }
  inspect(alive, content="false")
  debug_inspect(env.stage(), content="Finished")
}

///|
test "Synthesizer polyphonic note rendering, sustain pedal, and WAV export" {
  let sf = build_sine_sf2()
  let settings = @synth.SynthSettings::default(sample_rate=44100)
  let synth = @synth.Synthesizer::new(sf, settings~)
  synth.note_on(0, 69, 100)
  synth.note_on(0, 73, 90)
  inspect(synth.active_voice_count(), content="2")

  let n = 4096
  let left = FixedArray::make(n, 0.0)
  let right = FixedArray::make(n, 0.0)
  synth.render(left, right, n)
  let mut peak = 0.0
  for i in 0..<n {
    let a = left[i].abs()
    if a > peak {
      peak = a
    }
  }
  inspect(peak > 0.01 && peak <= 1.0, content="true")

  // Hold pedal keeps released note 69 alive alongside note 73
  synth.process_midi_message(0, 0xB0, 64, 127)
  synth.note_off(0, 69)
  inspect(synth.active_voice_count(), content="2")
  // Release hold pedal allows note 69 release tail to finish while note 73 stays playing
  synth.process_midi_message(0, 0xB0, 64, 0)
  for _ in 0..<20 {
    synth.render(left, right, n)
  }
  inspect(synth.active_voice_count(), content="1")
  // Release note 73 and verify all voices finish cleanly
  synth.note_off(0, 73)
  for _ in 0..<20 {
    synth.render(left, right, n)
  }
  inspect(synth.active_voice_count(), content="0")

  let wav = @synth.encode_wav_pcm16(left, right, 256, 44100)
  inspect(wav.length(), content="1068")
}

///|
test "exclusive class chokes prior note and polyphony cap steals voices" {
  let sb = @sf2.Sf2Builder::new(bank_name="Drum Choke Bank")
  let pcm : Array[Int32] = []
  for i in 0..<100 {
    let angle = 2.0 * @math.PI * i.to_double() / 100.0
    pcm.push((@math.sin(angle) * 20000.0).to_int())
  }
  let smp = sb.add_sample("Hat", pcm, 44100, 60, loop_start=0, loop_end=100)
  let inst = sb.add_instrument("HatKit", [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 42, 46),
        @sf2.gen_range(@sf2.GEN_VEL_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 1),
        @sf2.gen_val(@sf2.GEN_EXCLUSIVE_CLASS, 1),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, smp),
      ],
      modulators: [],
    },
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 60, 72),
        @sf2.gen_range(@sf2.GEN_VEL_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 1),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, smp),
      ],
      modulators: [],
    },
  ])
  sb.add_preset("Kit", 0, 0, [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_INSTRUMENT, inst),
      ],
      modulators: [],
    },
  ])
  let sf = @sf2.parse_sf2(sb.build())
  let settings : @synth.SynthSettings = {
    sample_rate: 44100,
    block_size: 64,
    maximum_polyphony: 2,
    enable_reverb_and_chorus: false,
    master_volume: 0.5,
    interpolation: Linear,
  }
  let syn = @synth.Synthesizer::new(sf, settings~)
  // Exclusive class 1: key 42 chokes key 46 immediately, keeping active voices = 1
  syn.note_on(0, 46, 100)
  inspect(syn.active_voice_count(), content="1")
  syn.note_on(0, 42, 100)
  inspect(syn.active_voice_count(), content="1")
  // Polyphony cap of 2 steals oldest/lowest-priority voice when triggering 3rd voice
  syn.note_on(0, 60, 100)
  syn.note_on(0, 64, 100)
  inspect(syn.active_voice_count(), content="2")
}
