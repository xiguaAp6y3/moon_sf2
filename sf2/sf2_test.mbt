///|
test "Sf2Builder roundtrip and generator inheritance" {
  let builder = @sf2.Sf2Builder::new(bank_name="Test Piano Bank")
  let pcm = [0, 16384, 32767, 16384, 0, -16384, -32768, -16384]
  let smp = builder.add_sample(
    "SineC4",
    pcm,
    44100,
    60,
    loop_start=0,
    loop_end=8,
  )
  let inst_global : @sf2.Zone = {
    generators: [
      @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 1),
      @sf2.gen_val(@sf2.GEN_RELEASE_VOL_ENV, -1200),
    ],
    modulators: [],
  }
  let inst_zone : @sf2.Zone = {
    generators: [
      @sf2.gen_range(@sf2.GEN_KEY_RANGE, 36, 84),
      @sf2.gen_range(@sf2.GEN_VEL_RANGE, 1, 127),
      @sf2.gen_val(@sf2.GEN_INITIAL_ATTENUATION, 100),
      @sf2.gen_val(@sf2.GEN_SAMPLE_ID, smp),
    ],
    modulators: [],
  }
  let inst_idx = builder.add_instrument(
    "PianoInst",
    [inst_zone],
    global_zone=Some(inst_global),
  )
  let preset_global : @sf2.Zone = {
    generators: [@sf2.gen_val(@sf2.GEN_INITIAL_ATTENUATION, 50)],
    modulators: [],
  }
  let preset_zone : @sf2.Zone = {
    generators: [
      @sf2.gen_range(@sf2.GEN_KEY_RANGE, 48, 96),
      @sf2.gen_val(@sf2.GEN_INSTRUMENT, inst_idx),
    ],
    modulators: [],
  }
  builder.add_preset(
    "Grand Piano",
    0,
    0,
    [preset_zone],
    global_zone=Some(preset_global),
  )

  let bytes = builder.build()
  let sf = @sf2.parse_sf2(bytes)
  inspect(sf.info.bank_name, content="Test Piano Bank")
  inspect(sf.info.version.major, content="2")
  inspect(sf.sample_headers.length(), content="1")
  inspect(sf.sample_headers[0].name, content="SineC4")
  inspect(sf.presets.length(), content="1")

  let p = sf.find_preset(0, 0).unwrap()
  let regions = sf.resolve_preset_regions(p)
  inspect(regions.length(), content="1")
  let r = regions[0]
  // KeyRange intersects [48, 96] and [36, 84] -> [48, 84]
  inspect(r.key_low, content="48")
  inspect(r.key_high, content="84")
  // Attenuation sums instrument 100 + preset global 50 = 150
  inspect(r.initial_attenuation, content="150")
  inspect(r.release_vol_env, content="-1200")
  debug_inspect(r.sample_modes, content="LoopContinuous")
  inspect(r.matches(60, 100), content="true")
  inspect(r.matches(40, 100), content="false")
}

///|
test "parse_sf2 rejects non-sfbk RIFF" {
  let buf = @buffer.Buffer()
  buf.write_string_utf8("RIFF")
  buf.write_uint_le(4U)
  buf.write_string_utf8("WAVE")
  try @sf2.parse_sf2(buf.to_bytes()) catch {
    err =>
      inspect(err, content="Invalid SF2 form type: expected 'sfbk', got 'WAVE'")
  } noraise {
    _ => fail("expected InvalidFormType")
  }
}

///|
test "24-bit sm24 sample precision roundtrip and stereo link metadata" {
  let builder = @sf2.Sf2Builder::new(bank_name="HiRes 24-bit Bank")
  let pcm24 = [0, 4194304, 8388607, -8388608, 1234567, -7654321]
  let idx_l = builder.add_sample_24bit(
    "PianoL",
    pcm24,
    48000,
    60,
    sample_link=1,
    sample_type=Left,
  )
  let idx_r = builder.add_sample_24bit(
    "PianoR",
    pcm24,
    48000,
    60,
    sample_link=0,
    sample_type=Right,
  )
  let inst = builder.add_instrument("StereoPiano", [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_PAN, -500),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, idx_l),
      ],
      modulators: [],
    },
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_PAN, 500),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, idx_r),
      ],
      modulators: [],
    },
  ])
  builder.add_preset("Stereo Grand", 0, 0, [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_INSTRUMENT, inst),
      ],
      modulators: [],
    },
  ])
  let sf = @sf2.parse_sf2(builder.build())
  inspect(sf.sample_headers.length(), content="2")
  debug_inspect(sf.sample_headers[0].sample_type, content="Left")
  debug_inspect(sf.sample_headers[1].sample_type, content="Right")
  let expected4 = 1234567.0 / 8388608.0
  inspect((sf.samples[4] - expected4).abs() < 1.0e-12, content="true")
  let expected5 = -7654321.0 / 8388608.0
  inspect((sf.samples[5] - expected5).abs() < 1.0e-12, content="true")
}

///|
test "parse_sf2 reports missing INFO or sdta chunks" {
  let inner = @buffer.Buffer()
  inner.write_string_utf8("sfbk")
  let inner_b = inner.to_bytes()
  let root = @buffer.Buffer()
  root.write_string_utf8("RIFF")
  root.write_uint_le(inner_b.length().reinterpret_as_uint())
  root.write_bytes(inner_b)
  try @sf2.parse_sf2(root.to_bytes()) catch {
    err => inspect(err, content="Missing required chunk 'LIST/INFO'")
  } noraise {
    _ => fail("expected MissingChunk")
  }
}
