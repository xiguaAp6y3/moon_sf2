///|
/// Programmatic builder for generating valid SoundFont2 (`RIFF sfbk`) binaries in pure MoonBit.
/// Useful for procedural wavetable banks and deterministic unit/integration tests.
pub struct Sf2Builder {
  bank_name : String
  sound_engine : String
  author : String
  sample_data : Array[Int32]
  sample_data_low8 : Array[Int32]
  mut has_sm24 : Bool
  sample_headers : Array[SampleHeader]
  instruments : Array[Instrument]
  presets : Array[Preset]
}

///|
pub fn Sf2Builder::new(bank_name~ : String = "MoonSF2 Bank") -> Sf2Builder {
  {
    bank_name,
    sound_engine: "EMU8000",
    author: "moon_sf2",
    sample_data: [],
    sample_data_low8: [],
    has_sm24: false,
    sample_headers: [],
    instruments: [],
    presets: [],
  }
}

///|
/// Append a mono 16-bit PCM waveform (`-32768..=32767`) plus SF2's required 46-sample zero trailer,
/// returning its sample header index.
pub fn Sf2Builder::add_sample(
  self : Sf2Builder,
  name : String,
  pcm16 : Array[Int32],
  sample_rate : Int32,
  original_pitch : Int32,
  loop_start~ : Int32 = 0,
  loop_end~ : Int32 = 0,
  pitch_correction~ : Int32 = 0,
  sample_link~ : Int32 = 0,
  sample_type~ : SampleType = Mono,
) -> Int32 {
  let start = self.sample_data.length()
  for s in pcm16 {
    self.sample_data.push(s)
    self.sample_data_low8.push(0)
  }
  let end = self.sample_data.length()
  // SF2 spec §7.10 requires at least 46 zero-valued samples after each sample end.
  for _ in 0..<46 {
    self.sample_data.push(0)
    self.sample_data_low8.push(0)
  }
  let eff_loop_start = start + loop_start
  let eff_loop_end = if loop_end > loop_start { start + loop_end } else { end }
  let idx = self.sample_headers.length()
  self.sample_headers.push({
    name,
    start,
    end,
    start_loop: eff_loop_start,
    end_loop: eff_loop_end,
    sample_rate,
    original_pitch,
    pitch_correction,
    sample_link,
    sample_type,
  })
  idx
}

///|
/// Append a mono 24-bit signed PCM waveform (`-8388608..=8388607`) stored across `smpl` + `sm24`.
pub fn Sf2Builder::add_sample_24bit(
  self : Sf2Builder,
  name : String,
  pcm24 : Array[Int32],
  sample_rate : Int32,
  original_pitch : Int32,
  loop_start~ : Int32 = 0,
  loop_end~ : Int32 = 0,
  pitch_correction~ : Int32 = 0,
  sample_link~ : Int32 = 0,
  sample_type~ : SampleType = Mono,
) -> Int32 {
  self.has_sm24 = true
  let start = self.sample_data.length()
  for s in pcm24 {
    let hi = s >> 8
    let lo = s & 0xFF
    self.sample_data.push(hi)
    self.sample_data_low8.push(lo)
  }
  let end = self.sample_data.length()
  for _ in 0..<46 {
    self.sample_data.push(0)
    self.sample_data_low8.push(0)
  }
  let eff_loop_start = start + loop_start
  let eff_loop_end = if loop_end > loop_start { start + loop_end } else { end }
  let idx = self.sample_headers.length()
  self.sample_headers.push({
    name,
    start,
    end,
    start_loop: eff_loop_start,
    end_loop: eff_loop_end,
    sample_rate,
    original_pitch,
    pitch_correction,
    sample_link,
    sample_type,
  })
  idx
}

///|
/// Add an instrument and return its index.
pub fn Sf2Builder::add_instrument(
  self : Sf2Builder,
  name : String,
  zones : Array[Zone],
  global_zone~ : Zone? = None,
) -> Int32 {
  let idx = self.instruments.length()
  self.instruments.push({ name, global_zone, zones, })
  idx
}

///|
/// Add a preset (`bank`, `preset` number `0..=127`).
pub fn Sf2Builder::add_preset(
  self : Sf2Builder,
  name : String,
  bank : Int32,
  preset : Int32,
  zones : Array[Zone],
  global_zone~ : Zone? = None,
) -> Unit {
  self.presets.push({
    name,
    preset,
    bank,
    library: 0,
    genre: 0,
    morphology: 0,
    global_zone,
    zones,
  })
}

///|
/// Construct a range generator (`keyRange` or `velRange`) from `[low, high]`.
pub fn gen_range(oper : Int32, low : Int32, high : Int32) -> RawGenerator {
  { oper, amount: (low & 0xFF) | ((high & 0xFF) << 8), }
}

///|
/// Construct a signed or unsigned scalar generator.
pub fn gen_val(oper : Int32, value : Int32) -> RawGenerator {
  { oper, amount: value & 0xFFFF, }
}

///|
fn write_fixed_ascii(
  buf : @buffer.Buffer,
  text : String,
  width : Int32,
) -> Unit {
  let len = text.length()
  let write_len = if len < width - 1 { len } else { width - 1 }
  for i in 0..<write_len {
    buf.write_byte(text[i].to_int().to_byte())
  }
  for _ in write_len..<width {
    buf.write_byte(b'\x00')
  }
}

///|
fn write_chunk(buf : @buffer.Buffer, id : String, payload : Bytes) -> Unit {
  buf.write_string_utf8(id)
  buf.write_uint_le(payload.length().reinterpret_as_uint())
  buf.write_bytesview(payload)
  if payload.length() % 2 == 1 {
    buf.write_byte(b'\x00')
  }
}

///|
fn write_list(
  buf : @buffer.Buffer,
  list_id : String,
  form_type : String,
  inner : Bytes,
) -> Unit {
  buf.write_string_utf8(list_id)
  buf.write_uint_le((inner.length() + 4).reinterpret_as_uint())
  buf.write_string_utf8(form_type)
  buf.write_bytesview(inner)
}

///|
/// Serialize the builder state into a spec-compliant SoundFont 2.01 binary `Bytes`.
pub fn Sf2Builder::build(self : Sf2Builder) -> Bytes {
  // 1. LIST/INFO
  let info_buf = @buffer.Buffer()
  let ifil = @buffer.Buffer()
  ifil.write_uint16_le(2U.to_uint16())
  ifil.write_uint16_le(1U.to_uint16())
  write_chunk(info_buf, "ifil", ifil.to_bytes())
  let isng = @buffer.Buffer()
  write_fixed_ascii(isng, self.sound_engine, self.sound_engine.length() + 1)
  write_chunk(info_buf, "isng", isng.to_bytes())
  let inam = @buffer.Buffer()
  write_fixed_ascii(inam, self.bank_name, self.bank_name.length() + 1)
  write_chunk(info_buf, "INAM", inam.to_bytes())
  let ieng = @buffer.Buffer()
  write_fixed_ascii(ieng, self.author, self.author.length() + 1)
  write_chunk(info_buf, "IENG", ieng.to_bytes())

  // 2. LIST/sdta
  let smpl_buf = @buffer.Buffer(capacity=self.sample_data.length() * 2)
  for s in self.sample_data {
    smpl_buf.write_int16_le(Int16::from_int(s))
  }
  let sdta_buf = @buffer.Buffer()
  write_chunk(sdta_buf, "smpl", smpl_buf.to_bytes())
  if self.has_sm24 {
    let sm24_buf = @buffer.Buffer(capacity=self.sample_data_low8.length())
    for lo in self.sample_data_low8 {
      sm24_buf.write_byte((lo & 0xFF).to_byte())
    }
    write_chunk(sdta_buf, "sm24", sm24_buf.to_bytes())
  }

  // 3. LIST/pdta
  let phdr_buf = @buffer.Buffer()
  let pbag_buf = @buffer.Buffer()
  let pmod_buf = @buffer.Buffer()
  let pgen_buf = @buffer.Buffer()
  let mut pbag_cursor = 0
  let mut pmod_cursor = 0
  let mut pgen_cursor = 0

  for p in self.presets {
    write_fixed_ascii(phdr_buf, p.name, 20)
    phdr_buf.write_uint16_le(p.preset.reinterpret_as_uint().to_uint16())
    phdr_buf.write_uint16_le(p.bank.reinterpret_as_uint().to_uint16())
    phdr_buf.write_uint16_le(pbag_cursor.reinterpret_as_uint().to_uint16())
    phdr_buf.write_uint_le(p.library.reinterpret_as_uint())
    phdr_buf.write_uint_le(p.genre.reinterpret_as_uint())
    phdr_buf.write_uint_le(p.morphology.reinterpret_as_uint())
    let zones : Array[Zone] = []
    match p.global_zone {
      Some(gz) => zones.push(gz)
      None => ()
    }
    for z in p.zones {
      zones.push(z)
    }
    for z in zones {
      pbag_buf.write_uint16_le(pgen_cursor.reinterpret_as_uint().to_uint16())
      pbag_buf.write_uint16_le(pmod_cursor.reinterpret_as_uint().to_uint16())
      pbag_cursor += 1
      for g in z.generators {
        pgen_buf.write_uint16_le(g.oper.reinterpret_as_uint().to_uint16())
        pgen_buf.write_uint16_le(g.amount.reinterpret_as_uint().to_uint16())
        pgen_cursor += 1
      }
      for m in z.modulators {
        pmod_buf.write_uint16_le(m.src_oper.reinterpret_as_uint().to_uint16())
        pmod_buf.write_uint16_le(m.dest_oper.reinterpret_as_uint().to_uint16())
        pmod_buf.write_int16_le(Int16::from_int(m.amount))
        pmod_buf.write_uint16_le(
          m.amt_src_oper.reinterpret_as_uint().to_uint16(),
        )
        pmod_buf.write_uint16_le(m.trans_oper.reinterpret_as_uint().to_uint16())
        pmod_cursor += 1
      }
    }
  }
  // Sentinels for preset tables
  write_fixed_ascii(phdr_buf, "EOP", 20)
  phdr_buf.write_uint16_le(0U.to_uint16())
  phdr_buf.write_uint16_le(0U.to_uint16())
  phdr_buf.write_uint16_le(pbag_cursor.reinterpret_as_uint().to_uint16())
  phdr_buf.write_uint_le(0U)
  phdr_buf.write_uint_le(0U)
  phdr_buf.write_uint_le(0U)
  pbag_buf.write_uint16_le(pgen_cursor.reinterpret_as_uint().to_uint16())
  pbag_buf.write_uint16_le(pmod_cursor.reinterpret_as_uint().to_uint16())
  for _ in 0..<5 {
    pmod_buf.write_uint16_le(0U.to_uint16())
  }
  pgen_buf.write_uint16_le(0U.to_uint16())
  pgen_buf.write_uint16_le(0U.to_uint16())

  let inst_buf = @buffer.Buffer()
  let ibag_buf = @buffer.Buffer()
  let imod_buf = @buffer.Buffer()
  let igen_buf = @buffer.Buffer()
  let mut ibag_cursor = 0
  let mut imod_cursor = 0
  let mut igen_cursor = 0

  for inst in self.instruments {
    write_fixed_ascii(inst_buf, inst.name, 20)
    inst_buf.write_uint16_le(ibag_cursor.reinterpret_as_uint().to_uint16())
    let zones : Array[Zone] = []
    match inst.global_zone {
      Some(gz) => zones.push(gz)
      None => ()
    }
    for z in inst.zones {
      zones.push(z)
    }
    for z in zones {
      ibag_buf.write_uint16_le(igen_cursor.reinterpret_as_uint().to_uint16())
      ibag_buf.write_uint16_le(imod_cursor.reinterpret_as_uint().to_uint16())
      ibag_cursor += 1
      for g in z.generators {
        igen_buf.write_uint16_le(g.oper.reinterpret_as_uint().to_uint16())
        igen_buf.write_uint16_le(g.amount.reinterpret_as_uint().to_uint16())
        igen_cursor += 1
      }
      for m in z.modulators {
        imod_buf.write_uint16_le(m.src_oper.reinterpret_as_uint().to_uint16())
        imod_buf.write_uint16_le(m.dest_oper.reinterpret_as_uint().to_uint16())
        imod_buf.write_int16_le(Int16::from_int(m.amount))
        imod_buf.write_uint16_le(
          m.amt_src_oper.reinterpret_as_uint().to_uint16(),
        )
        imod_buf.write_uint16_le(m.trans_oper.reinterpret_as_uint().to_uint16())
        imod_cursor += 1
      }
    }
  }
  write_fixed_ascii(inst_buf, "EOI", 20)
  inst_buf.write_uint16_le(ibag_cursor.reinterpret_as_uint().to_uint16())
  ibag_buf.write_uint16_le(igen_cursor.reinterpret_as_uint().to_uint16())
  ibag_buf.write_uint16_le(imod_cursor.reinterpret_as_uint().to_uint16())
  for _ in 0..<5 {
    imod_buf.write_uint16_le(0U.to_uint16())
  }
  igen_buf.write_uint16_le(0U.to_uint16())
  igen_buf.write_uint16_le(0U.to_uint16())

  let shdr_buf = @buffer.Buffer()
  for s in self.sample_headers {
    write_fixed_ascii(shdr_buf, s.name, 20)
    shdr_buf.write_uint_le(s.start.reinterpret_as_uint())
    shdr_buf.write_uint_le(s.end.reinterpret_as_uint())
    shdr_buf.write_uint_le(s.start_loop.reinterpret_as_uint())
    shdr_buf.write_uint_le(s.end_loop.reinterpret_as_uint())
    shdr_buf.write_uint_le(s.sample_rate.reinterpret_as_uint())
    shdr_buf.write_byte(s.original_pitch.to_byte())
    shdr_buf.write_byte((s.pitch_correction & 0xFF).to_byte())
    shdr_buf.write_uint16_le(s.sample_link.reinterpret_as_uint().to_uint16())
    shdr_buf.write_uint16_le(
      s.sample_type.to_raw().reinterpret_as_uint().to_uint16(),
    )
  }
  write_fixed_ascii(shdr_buf, "EOS", 20)
  for _ in 0..<26 {
    shdr_buf.write_byte(b'\x00')
  }

  let pdta_buf = @buffer.Buffer()
  write_chunk(pdta_buf, "phdr", phdr_buf.to_bytes())
  write_chunk(pdta_buf, "pbag", pbag_buf.to_bytes())
  write_chunk(pdta_buf, "pmod", pmod_buf.to_bytes())
  write_chunk(pdta_buf, "pgen", pgen_buf.to_bytes())
  write_chunk(pdta_buf, "inst", inst_buf.to_bytes())
  write_chunk(pdta_buf, "ibag", ibag_buf.to_bytes())
  write_chunk(pdta_buf, "imod", imod_buf.to_bytes())
  write_chunk(pdta_buf, "igen", igen_buf.to_bytes())
  write_chunk(pdta_buf, "shdr", shdr_buf.to_bytes())

  let body_buf = @buffer.Buffer()
  write_list(body_buf, "LIST", "INFO", info_buf.to_bytes())
  write_list(body_buf, "LIST", "sdta", sdta_buf.to_bytes())
  write_list(body_buf, "LIST", "pdta", pdta_buf.to_bytes())

  let root = @buffer.Buffer()
  write_list(root, "RIFF", "sfbk", body_buf.to_bytes())
  root.to_bytes()
}
