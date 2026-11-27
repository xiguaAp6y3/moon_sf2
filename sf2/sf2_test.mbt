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
  root.write_bytesview(inner_b)
  try @sf2.parse_sf2(root.to_bytes()) catch {
    err => inspect(err, content="Missing required chunk 'LIST/INFO'")
  } noraise {
    _ => fail("expected MissingChunk")
  }
}

///|
fn riff_chunk(id : String, payload : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_string_utf8(id)
  buf.write_uint_le(payload.length().reinterpret_as_uint())
  buf.write_bytesview(payload)
  if payload.length() % 2 == 1 {
    buf.write_byte(b'\x00')
  }
  buf.to_bytes()
}

///|
fn riff_list(id : String, form : String, children : Array[Bytes]) -> Bytes {
  let inner = @buffer.Buffer()
  inner.write_string_utf8(form)
  for c in children {
    inner.write_bytesview(c)
  }
  let b = inner.to_bytes()
  let out = @buffer.Buffer()
  out.write_string_utf8(id)
  out.write_uint_le(b.length().reinterpret_as_uint())
  out.write_bytesview(b)
  out.to_bytes()
}

///|
fn minimal_info_list() -> Bytes {
  let ifil = b"\x02\x00\x01\x00"
  let iver = b"\x01\x00\x00\x00"
  riff_list("LIST", "INFO", [
    riff_chunk("ifil", ifil),
    riff_chunk("iver", iver),
    riff_chunk("isng", b"EMU8000\x00"),
    riff_chunk("INAM", b"Bank\x00"),
    riff_chunk("irom", b"ROM\x00"),
    riff_chunk("ICRD", b"2026\x00"),
    riff_chunk("IENG", b"Dev\x00"),
    riff_chunk("IPRD", b"Prod\x00"),
    riff_chunk("ICOP", b"Apache\x00"),
    riff_chunk("ICMT", b"Note\x00"),
    riff_chunk("ISFT", b"moon_sf2\x00"),
  ])
}

///|
fn zero_bytes(n : Int32) -> Bytes {
  let b = @buffer.Buffer(capacity=n)
  for _ in 0..<n {
    b.write_byte(b'\x00')
  }
  b.to_bytes()
}

///|
fn minimal_sdta_list() -> Bytes {
  riff_list("LIST", "sdta", [riff_chunk("smpl", b"\x00\x00\x00\x00")])
}

///|
fn make_sf2_with_pdta(pdta_children : Array[Bytes]) -> Bytes {
  riff_list("RIFF", "sfbk", [
    minimal_info_list(),
    minimal_sdta_list(),
    riff_list("LIST", "pdta", pdta_children),
  ])
}

///|
fn valid_pdta_map(
  phdr~ : Bytes = zero_bytes(38),
  pbag~ : Bytes = zero_bytes(4),
  pmod~ : Bytes = zero_bytes(10),
  pgen~ : Bytes = zero_bytes(4),
  inst~ : Bytes = zero_bytes(22),
  ibag~ : Bytes = zero_bytes(4),
  imod~ : Bytes = zero_bytes(10),
  igen~ : Bytes = zero_bytes(4),
  shdr~ : Bytes = zero_bytes(46),
) -> Array[Bytes] {
  [
    riff_chunk("phdr", phdr),
    riff_chunk("pbag", pbag),
    riff_chunk("pmod", pmod),
    riff_chunk("pgen", pgen),
    riff_chunk("inst", inst),
    riff_chunk("ibag", ibag),
    riff_chunk("imod", imod),
    riff_chunk("igen", igen),
    riff_chunk("shdr", shdr),
  ]
}

///|
test "parse_sf2 error paths: MissingChunk, InvalidChunkLength, MissingSentinel, OutOfRangeIndex" {
  // Missing LIST/sdta
  let no_sdta = riff_list("RIFF", "sfbk", [minimal_info_list()])
  try @sf2.parse_sf2(no_sdta) catch {
    err => inspect(err, content="Missing required chunk 'LIST/sdta'")
  } noraise {
    _ => fail("expected MissingChunk LIST/sdta")
  }

  // Missing LIST/pdta
  let no_pdta = riff_list("RIFF", "sfbk", [
    minimal_info_list(),
    minimal_sdta_list(),
  ])
  try @sf2.parse_sf2(no_pdta) catch {
    err => inspect(err, content="Missing required chunk 'LIST/pdta'")
  } noraise {
    _ => fail("expected MissingChunk LIST/pdta")
  }

  // Missing smpl inside LIST/sdta
  let no_smpl = riff_list("RIFF", "sfbk", [
    minimal_info_list(),
    riff_list("LIST", "sdta", [riff_chunk("sm24", b"\x00\x00")]),
    riff_list("LIST", "pdta", valid_pdta_map()),
  ])
  try @sf2.parse_sf2(no_smpl) catch {
    err => inspect(err, content="Missing required chunk 'smpl'")
  } noraise {
    _ => fail("expected MissingChunk smpl")
  }

  // Odd smpl length -> InvalidChunkLength
  let bad_smpl = riff_list("RIFF", "sfbk", [
    minimal_info_list(),
    riff_list("LIST", "sdta", [riff_chunk("smpl", b"\x00\x01\x02")]),
    riff_list("LIST", "pdta", valid_pdta_map()),
  ])
  try @sf2.parse_sf2(bad_smpl) catch {
    err =>
      inspect(
        err,
        content="Invalid chunk length for 'smpl': length 3 not compatible with record size 2",
      )
  } noraise {
    _ => fail("expected InvalidChunkLength smpl")
  }

  // Missing pdta subchunk (e.g. missing shdr)
  let missing_shdr = make_sf2_with_pdta([
    riff_chunk("phdr", zero_bytes(38)),
    riff_chunk("pbag", zero_bytes(4)),
    riff_chunk("pmod", zero_bytes(10)),
    riff_chunk("pgen", zero_bytes(4)),
    riff_chunk("inst", zero_bytes(22)),
    riff_chunk("ibag", zero_bytes(4)),
    riff_chunk("imod", zero_bytes(10)),
    riff_chunk("igen", zero_bytes(4)),
  ])
  try @sf2.parse_sf2(missing_shdr) catch {
    err => inspect(err, content="Missing required chunk 'shdr'")
  } noraise {
    _ => fail("expected MissingChunk shdr")
  }

  // InvalidChunkLength in pdta (phdr length 10 not multiple of 38)
  try
    @sf2.parse_sf2(make_sf2_with_pdta(valid_pdta_map(phdr=zero_bytes(10))))
  catch {
    err =>
      inspect(
        err,
        content="Invalid chunk length for 'phdr': length 10 not compatible with record size 38",
      )
  } noraise {
    _ => fail("expected InvalidChunkLength phdr")
  }

  // MissingSentinel for shdr, inst, phdr
  try @sf2.parse_sf2(make_sf2_with_pdta(valid_pdta_map(shdr=b""))) catch {
    err => inspect(err, content="Missing terminal sentinel record in 'shdr'")
  } noraise {
    _ => fail("expected MissingSentinel shdr")
  }
  try @sf2.parse_sf2(make_sf2_with_pdta(valid_pdta_map(inst=b""))) catch {
    err => inspect(err, content="Missing terminal sentinel record in 'inst'")
  } noraise {
    _ => fail("expected MissingSentinel inst")
  }
  try @sf2.parse_sf2(make_sf2_with_pdta(valid_pdta_map(phdr=b""))) catch {
    err => inspect(err, content="Missing terminal sentinel record in 'phdr'")
  } noraise {
    _ => fail("expected MissingSentinel phdr")
  }

  // OutOfRangeIndex: phdr[1].bag_ndx = 5 > pbag.length() (1)
  let bad_phdr = @buffer.Buffer()
  bad_phdr.write_bytesview(zero_bytes(38))
  bad_phdr.write_bytesview(zero_bytes(24))
  bad_phdr.write_uint16_le(5U.to_uint16()) // EOP bag_ndx = 5
  bad_phdr.write_bytesview(zero_bytes(12))
  try
    @sf2.parse_sf2(make_sf2_with_pdta(valid_pdta_map(phdr=bad_phdr.to_bytes())))
  catch {
    err => inspect(err, content="Out of range index 5 in 'pbag' (limit 1)")
  } noraise {
    _ => fail("expected OutOfRangeIndex pbag")
  }

  // OutOfRangeIndex: inst[1].bag_ndx = 3 > ibag.length() (1)
  let bad_inst = @buffer.Buffer()
  bad_inst.write_bytesview(zero_bytes(22))
  bad_inst.write_bytesview(zero_bytes(20))
  bad_inst.write_uint16_le(3U.to_uint16()) // EOI bag_ndx = 3
  try
    @sf2.parse_sf2(make_sf2_with_pdta(valid_pdta_map(inst=bad_inst.to_bytes())))
  catch {
    err => inspect(err, content="Out of range index 3 in 'ibag' (limit 1)")
  } noraise {
    _ => fail("expected OutOfRangeIndex ibag")
  }

  // OutOfRangeIndex: pbag[1].gen_ndx = 9 > pgen.length() (1)
  let two_phdr = @buffer.Buffer()
  two_phdr.write_bytesview(zero_bytes(38))
  two_phdr.write_bytesview(zero_bytes(24))
  two_phdr.write_uint16_le(1U.to_uint16())
  two_phdr.write_bytesview(zero_bytes(12))
  let bad_pbag = @buffer.Buffer()
  bad_pbag.write_uint16_le(0U.to_uint16())
  bad_pbag.write_uint16_le(0U.to_uint16())
  bad_pbag.write_uint16_le(9U.to_uint16())
  bad_pbag.write_uint16_le(0U.to_uint16())
  try
    @sf2.parse_sf2(
      make_sf2_with_pdta(
        valid_pdta_map(phdr=two_phdr.to_bytes(), pbag=bad_pbag.to_bytes()),
      ),
    )
  catch {
    err => inspect(err, content="Out of range index 9 in 'gen' (limit 1)")
  } noraise {
    _ => fail("expected OutOfRangeIndex gen")
  }

  // OutOfRangeIndex: pbag[1].mod_ndx = 7 > pmod.length() (1)
  let bad_pbag_mod = @buffer.Buffer()
  bad_pbag_mod.write_uint16_le(0U.to_uint16())
  bad_pbag_mod.write_uint16_le(0U.to_uint16())
  bad_pbag_mod.write_uint16_le(0U.to_uint16())
  bad_pbag_mod.write_uint16_le(7U.to_uint16())
  try
    @sf2.parse_sf2(
      make_sf2_with_pdta(
        valid_pdta_map(phdr=two_phdr.to_bytes(), pbag=bad_pbag_mod.to_bytes()),
      ),
    )
  catch {
    err => inspect(err, content="Out of range index 7 in 'mod' (limit 1)")
  } noraise {
    _ => fail("expected OutOfRangeIndex mod")
  }
}

///|
test "SF2 metadata, SampleType, LoopMode, modulators, bank0 fallback, and stereo link" {
  let def = @sf2.SoundFontInfo::default()
  inspect(def.sound_engine, content="EMU8000")
  debug_inspect(@sf2.SampleType::from_raw(8), content="Linked")
  inspect(@sf2.SampleType::Linked.to_raw(), content="8")
  debug_inspect(@sf2.LoopMode::from_int(3), content="LoopUntilRelease")

  let sb = @sf2.Sf2Builder::new(bank_name="Stereo & Mod Bank")
  let pcm_l = [1000, 2000, 3000, 4000]
  let pcm_r = [-1000, -2000, -3000, -4000]
  let idx_l = sb.add_sample(
    "LeftSmp",
    pcm_l,
    44100,
    60,
    sample_link=1,
    sample_type=Left,
  )
  let idx_r = sb.add_sample(
    "RightSmp",
    pcm_r,
    44100,
    60,
    sample_link=0,
    sample_type=Right,
  )
  let mod_base : @sf2.Modulator = {
    src_oper: 0x0081,
    dest_oper: 6,
    amount: 50,
    amt_src_oper: 0,
    trans_oper: 0,
  }
  let mod_override : @sf2.Modulator = {
    src_oper: 0x0081,
    dest_oper: 6,
    amount: 120,
    amt_src_oper: 0,
    trans_oper: 0,
  }
  let inst = sb.add_instrument("StereoPair", [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_PAN, -500),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 3),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, idx_l),
      ],
      modulators: [mod_base],
    },
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_PAN, 500),
        @sf2.gen_val(@sf2.GEN_SAMPLE_MODES, 3),
        @sf2.gen_val(@sf2.GEN_SAMPLE_ID, idx_r),
      ],
      modulators: [],
    },
  ])
  sb.add_preset(
    "StereoPreset",
    0,
    0,
    [
      {
        generators: [
          @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
          @sf2.gen_range(@sf2.GEN_VEL_RANGE, 1, 127),
          @sf2.gen_val(@sf2.GEN_REVERB_EFFECTS_SEND, 100),
          @sf2.gen_val(@sf2.GEN_INSTRUMENT, inst),
        ],
        modulators: [mod_override],
      },
    ],
    global_zone=Some({
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_range(@sf2.GEN_VEL_RANGE, 0, 127),
      ],
      modulators: [],
    }),
  )
  let sf = @sf2.parse_sf2(sb.build())
  inspect(sf.sample_headers[0].sample_link, content="1")
  inspect(sf.sample_headers[1].sample_link, content="0")
  debug_inspect(sf.sample_headers[0].sample_type, content="Left")
  debug_inspect(sf.sample_headers[1].sample_type, content="Right")
  let p = sf.find_preset(5, 0, fallback_bank0=true).unwrap()
  inspect(p.name, content="StereoPreset")
  inspect(sf.find_preset(5, 99, fallback_bank0=true) is None, content="true")
  let regions = sf.resolve_preset_regions(p)
  inspect(regions.length(), content="2")
  debug_inspect(regions[0].sample_modes, content="LoopUntilRelease")
  inspect(regions[0].pan, content="-500")
  inspect(regions[1].pan, content="500")
  inspect(regions[0].modulators.length(), content="1")
  inspect(regions[0].modulators[0].amount, content="120")
}
