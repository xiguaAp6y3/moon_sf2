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

///|
test "SF2 modulator curves and real-time CC modulation" {
  inspect(@synth.sf2_concave(0.0), content="0")
  inspect(@synth.sf2_concave(1.0), content="1")
  inspect(@synth.sf2_convex(0.0), content="0")
  inspect(@synth.sf2_convex(1.0), content="1")
  inspect(@synth.sf2_concave(0.5) < 0.5, content="true")
  inspect(@synth.sf2_convex(0.5) > 0.5, content="true")

  let ch = @synth.ChannelState::new(false)
  ch.set_modulation_coarse(127)
  // Custom modulator: NoteOnVelocity (src=2) -> InitialFilterFc (dest=8), amount=-2400
  let custom_mod : @sf2.Modulator = {
    src_oper: 0x0102, // NoteOnVelocity, negative direction, linear unipolar
    dest_oper: 8,
    amount: -2400,
    amt_src_oper: 0,
    trans_oper: 0,
  }
  let offsets = @synth.evaluate_modulators([custom_mod], ch, 60, 0)
  inspect(
    (offsets.initial_filter_fc_cents - -2400.0).abs() < 1.0e-6,
    content="true",
  )
  inspect(offsets.vib_lfo_to_pitch_cents > 49.0, content="true")
}

///|
test "channel preset lookup, stereo pan energy, and interleaved PCM export" {
  let sf = build_sine_sf2()
  let settings : @synth.SynthSettings = {
    sample_rate: 44100,
    block_size: 64,
    maximum_polyphony: 16,
    enable_reverb_and_chorus: false,
    master_volume: 0.5,
    interpolation: Cubic,
  }
  let syn = @synth.Synthesizer::new(sf, settings~)
  debug_inspect(syn.channel_preset_name(0), content="Some(\"Sine Preset\")")
  // Hard-left pan via CC#10 = 0
  syn.process_midi_message(0, 0xB0, 10, 0)
  syn.note_on(0, 69, 127)
  let pcm_f32 = syn.render_interleaved_f32(512)
  inspect(pcm_f32.length(), content="1024")
  let mut left_energy = 0.0
  let mut right_energy = 0.0
  for i in 0..<512 {
    let l = pcm_f32[i * 2].to_double()
    let r = pcm_f32[i * 2 + 1].to_double()
    left_energy += l * l
    right_energy += r * r
  }
  inspect(left_energy > 0.1, content="true")
  inspect(right_energy < 1.0e-6, content="true")
  let pcm_i16 = syn.render_interleaved_i16(128)
  inspect(pcm_i16.length(), content="256")
}

///|
test "LoopUntilRelease loops while held and exits cleanly after note_off" {
  let sb = @sf2.Sf2Builder::new(bank_name="LoopRelease Bank")
  let sr = 44100
  let pcm : Array[Int32] = []
  // 0..10: attack, 10..50: loop, 50..200: post-loop release tail
  for i in 0..<200 {
    let phase = 2.0 * @math.PI * (i % 40).to_double() / 40.0
    pcm.push((@math.sin(phase) * 24000.0).to_int())
  }
  let smp = sb.add_sample(
    "LoopRelWave",
    pcm,
    sr,
    69,
    loop_start=10,
    loop_end=50,
  )
  let inst = sb.add_instrument("LoopRelInst", [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_range(@sf2.GEN_VEL_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 3), // LoopUntilRelease
        @sf2.gen_val(@sf2.GEN_ATTACK_VOL_ENV, -12000),
        @sf2.gen_val(@sf2.GEN_RELEASE_VOL_ENV, 0), // 1.0 s release envelope so sample end finishes voice
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, smp),
      ],
      modulators: [],
    },
  ])
  sb.add_preset("LoopRel", 0, 0, [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_INSTRUMENT, inst),
      ],
      modulators: [],
    },
  ])
  let sf = @sf2.parse_sf2(sb.build())
  for
    mode in [@synth.InterpolationMode::Linear, @synth.InterpolationMode::Cubic] {
    let settings : @synth.SynthSettings = {
      sample_rate: sr,
      block_size: 64,
      maximum_polyphony: 8,
      enable_reverb_and_chorus: false,
      master_volume: 0.5,
      interpolation: mode,
    }
    let syn = @synth.Synthesizer::new(sf, settings~)
    syn.note_on(0, 69, 100)
    // Render 1024 frames (> 200 sample length): must stay active while looping
    let l = FixedArray::make(256, 0.0)
    let r = FixedArray::make(256, 0.0)
    for _ in 0..<4 {
      syn.render(l, r, 256)
    }
    inspect(syn.active_voice_count(), content="1")
    // Trigger note_off -> voice exits loop and finishes cleanly after post-loop tail
    syn.note_off(0, 69)
    syn.render(l, r, 256)
    inspect(syn.active_voice_count(), content="0")
  }
}

///|
test "RPN pitch bend sensitivity, AllSoundOff (CC#120), AllNotesOff (CC#123), and controllers" {
  let sf = build_sine_sf2()
  let settings : @synth.SynthSettings = {
    sample_rate: 44100,
    block_size: 64,
    maximum_polyphony: 8,
    enable_reverb_and_chorus: false,
    master_volume: 0.5,
    interpolation: Linear,
  }
  let syn = @synth.Synthesizer::new(sf, settings~)
  // RPN 0 (Pitch Bend Sensitivity) = 12 semitones: CC#101=0, CC#100=0, CC#6=12
  syn.process_midi_message(0, 0xB0, 101, 0)
  syn.process_midi_message(0, 0xB0, 100, 0)
  syn.process_midi_message(0, 0xB0, 6, 12)
  syn.process_midi_message(0, 0xE0, 127, 127)
  inspect(
    (syn.channels[0].pitch_bend_semitones() - 12.0).abs() < 0.01,
    content="true",
  )

  // Measure pitch-bent zero-crossing frequency (~2x base 441 Hz)
  syn.note_on(0, 69, 100)
  let n = 4096
  let l_up = FixedArray::make(n, 0.0)
  let r_up = FixedArray::make(n, 0.0)
  syn.render(l_up, r_up, n)
  let mut crossings_up = 0
  for i in 1..<n {
    if l_up[i - 1] <= 0.0 && l_up[i] > 0.0 {
      crossings_up += 1
    }
  }
  // 441 Hz * 2 = 882 Hz over 4096/44100 s ≈ 81.9 cycles
  inspect(crossings_up >= 78 && crossings_up <= 86, content="true")

  // Channel 1 note stays isolated from channel 0 CC#123 / CC#120
  syn.note_on(1, 69, 100)
  inspect(syn.active_voice_count(), content="2")
  // AllNotesOff (CC#123) on ch 0 releases ch 0 smoothly while ch 1 stays playing
  syn.process_midi_message(0, 0xB0, 123, 0)
  let tmp_l = FixedArray::make(1024, 0.0)
  let tmp_r = FixedArray::make(1024, 0.0)
  for _ in 0..<40 {
    syn.render(tmp_l, tmp_r, 1024)
  }
  inspect(syn.active_voice_count(), content="1")

  // AllSoundOff (CC#120) on ch 0 kills ch 0 immediately while ch 1 stays alive
  syn.note_on(0, 60, 100)
  inspect(syn.active_voice_count(), content="2")
  syn.process_midi_message(0, 0xB0, 120, 0)
  inspect(syn.active_voice_count(), content="1")

  // Exercise remaining CCs, channel pressure, note_off_all, and reset
  syn.process_midi_message(0, 0xB0, 0, 0)
  syn.process_midi_message(0, 0xB0, 11, 100)
  syn.process_midi_message(0, 0xB0, 91, 64)
  syn.process_midi_message(0, 0xB0, 93, 64)
  syn.process_midi_message(0, 0xB0, 121, 0)
  syn.process_midi_message(0, 0xD0, 64, 0)
  syn.note_on(0, 69, 0) // velocity 0 acts as note_off
  syn.note_off_all(immediate=false)
  syn.reset()
  inspect(syn.active_voice_count(), content="0")
}

///|
test "Reverb and Chorus wet energy tail check" {
  let sf = build_sine_sf2()
  let settings_wet : @synth.SynthSettings = {
    sample_rate: 44100,
    block_size: 64,
    maximum_polyphony: 8,
    enable_reverb_and_chorus: true,
    master_volume: 0.5,
    interpolation: Linear,
  }
  let syn_wet = @synth.Synthesizer::new(sf, settings=settings_wet)
  syn_wet.process_midi_message(0, 0xB0, 91, 127) // max reverb send
  syn_wet.process_midi_message(0, 0xB0, 93, 127) // max chorus send
  syn_wet.note_on(0, 69, 127)
  let l = FixedArray::make(2048, 0.0)
  let r = FixedArray::make(2048, 0.0)
  syn_wet.render(l, r, 2048)
  syn_wet.note_off(0, 69)
  // Wait for dry voice envelope to finish completely
  for _ in 0..<25 {
    syn_wet.render(l, r, 2048)
  }
  inspect(syn_wet.active_voice_count(), content="0")
  // Render additional frames with 0 active voices -> reverb tail must carry wet energy
  syn_wet.render(l, r, 2048)
  let mut tail_energy = 0.0
  for i in 0..<2048 {
    tail_energy += l[i] * l[i] + r[i] * r[i]
  }
  inspect(tail_energy > 1.0e-5, content="true")

  // Compare Chorus stereo spread when reverb=0 and chorus=127 on a centered mono source
  let syn_cho = @synth.Synthesizer::new(sf, settings=settings_wet)
  syn_cho.process_midi_message(0, 0xB0, 91, 0)
  syn_cho.process_midi_message(0, 0xB0, 93, 127)
  syn_cho.note_on(0, 69, 127)
  syn_cho.render(l, r, 2048)
  let mut diff_energy = 0.0
  for i in 0..<2048 {
    let d = l[i] - r[i]
    diff_energy += d * d
  }
  inspect(diff_energy > 1.0e-5, content="true")
}

///|
test "Synthesizer stereo Left/Right sample-pair rendering isolation" {
  let sb = @sf2.Sf2Builder::new(bank_name="Stereo Pair Synth Bank")
  let sr = 44100
  let pcm_l : Array[Int32] = []
  let pcm_r : Array[Int32] = []
  for i in 0..<100 {
    let phase = 2.0 * @math.PI * i.to_double() / 100.0
    pcm_l.push((@math.sin(phase) * 24000.0).to_int())
    pcm_r.push(0)
  }
  let idx_l = sb.add_sample(
    "PairL",
    pcm_l,
    sr,
    69,
    loop_start=0,
    loop_end=100,
    sample_link=1,
    sample_type=Left,
  )
  let idx_r = sb.add_sample(
    "PairR",
    pcm_r,
    sr,
    69,
    loop_start=0,
    loop_end=100,
    sample_link=0,
    sample_type=Right,
  )
  let inst = sb.add_instrument("PairInst", [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_PAN, -500),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 1),
        @sf2.gen_val(@sf2.GEN_ATTACK_VOL_ENV, -12000),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, idx_l),
      ],
      modulators: [],
    },
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_PAN, 500),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 1),
        @sf2.gen_val(@sf2.GEN_ATTACK_VOL_ENV, -12000),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, idx_r),
      ],
      modulators: [],
    },
  ])
  sb.add_preset("PairPreset", 0, 0, [
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
    sample_rate: sr,
    block_size: 64,
    maximum_polyphony: 8,
    enable_reverb_and_chorus: false,
    master_volume: 0.5,
    interpolation: Linear,
  }
  let syn = @synth.Synthesizer::new(sf, settings~)
  syn.note_on(0, 69, 127)
  inspect(syn.active_voice_count(), content="2")
  let l = FixedArray::make(512, 0.0)
  let r = FixedArray::make(512, 0.0)
  syn.render(l, r, 512)
  let mut el = 0.0
  let mut er = 0.0
  for i in 0..<512 {
    el += l[i] * l[i]
    er += r[i] * r[i]
  }
  inspect(el > 0.1, content="true")
  inspect(er < 1.0e-6, content="true")
}
