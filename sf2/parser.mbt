///|
/// Parse a complete SoundFont2 (`.sf2`) byte buffer into a `SoundFont`.
pub fn parse_sf2(data : Bytes) -> SoundFont raise Sf2Error {
  let root = @riff.parse_riff(data) catch { err => raise Riff(err~) }
  match root.form_type {
    Some("sfbk") => ()
    Some(other) => raise InvalidFormType(expected="sfbk", actual=other)
    None => raise InvalidFormType(expected="sfbk", actual="")
  }
  let info = match root.find_list("INFO") {
    Some(info_chunk) => parse_info(data, info_chunk)
    None => raise MissingChunk(name="LIST/INFO")
  }
  let samples = match root.find_list("sdta") {
    Some(sdta_chunk) => parse_sdta(data, sdta_chunk)
    None => raise MissingChunk(name="LIST/sdta")
  }
  let pdta_chunk = match root.find_list("pdta") {
    Some(c) => c
    None => raise MissingChunk(name="LIST/pdta")
  }
  let (sample_headers, instruments, presets) = parse_pdta(data, pdta_chunk)
  { info, samples, sample_headers, instruments, presets, }
}

///|
fn parse_info(
  data : Bytes,
  info_chunk : @riff.RiffChunk,
) -> SoundFontInfo raise Sf2Error {
  let mut version : SoundFontVersion = { major: 2, minor: 1, }
  let mut sound_engine = "EMU8000"
  let mut bank_name = ""
  let mut rom_name = ""
  let mut rom_version : SoundFontVersion? = None
  let mut creation_date = ""
  let mut author = ""
  let mut target_product = ""
  let mut copyright = ""
  let mut comments = ""
  let mut tools = ""
  for child in info_chunk.children {
    let r = @riff.ByteReader::at(data, child.data_offset)
    match child.id {
      "ifil" =>
        if child.data_size >= 4 {
          let major = r.read_u16_le() catch { err => raise Riff(err~) }
          let minor = r.read_u16_le() catch { err => raise Riff(err~) }
          version = { major, minor, }
        }
      "iver" =>
        if child.data_size >= 4 {
          let major = r.read_u16_le() catch { err => raise Riff(err~) }
          let minor = r.read_u16_le() catch { err => raise Riff(err~) }
          rom_version = Some({ major, minor, })
        }
      "isng" =>
        sound_engine = r.read_ascii_z(child.data_size) catch {
          err => raise Riff(err~)
        }
      "INAM" =>
        bank_name = r.read_ascii_z(child.data_size) catch {
          err => raise Riff(err~)
        }
      "irom" =>
        rom_name = r.read_ascii_z(child.data_size) catch {
          err => raise Riff(err~)
        }
      "ICRD" =>
        creation_date = r.read_ascii_z(child.data_size) catch {
          err => raise Riff(err~)
        }
      "IENG" =>
        author = r.read_ascii_z(child.data_size) catch {
          err => raise Riff(err~)
        }
      "IPRD" =>
        target_product = r.read_ascii_z(child.data_size) catch {
          err => raise Riff(err~)
        }
      "ICOP" =>
        copyright = r.read_ascii_z(child.data_size) catch {
          err => raise Riff(err~)
        }
      "ICMT" =>
        comments = r.read_ascii_z(child.data_size) catch {
          err => raise Riff(err~)
        }
      "ISFT" =>
        tools = r.read_ascii_z(child.data_size) catch {
          err => raise Riff(err~)
        }
      _ => ()
    }
  }
  {
    version,
    sound_engine,
    bank_name,
    rom_name,
    rom_version,
    creation_date,
    author,
    target_product,
    copyright,
    comments,
    tools,
  }
}

///|
fn parse_sdta(
  data : Bytes,
  sdta_chunk : @riff.RiffChunk,
) -> FixedArray[Double] raise Sf2Error {
  let smpl = match sdta_chunk.find_child("smpl") {
    Some(c) => c
    None => raise MissingChunk(name="smpl")
  }
  if smpl.data_size % 2 != 0 {
    raise InvalidChunkLength(
      name="smpl",
      expected_multiple=2,
      actual=smpl.data_size,
    )
  }
  let sample_count = smpl.data_size / 2
  let sm24_opt = match sdta_chunk.find_child("sm24") {
    Some(c) => if c.data_size == sample_count { Some(c) } else { None }
    None => None
  }
  let samples = FixedArray::make(sample_count, 0.0)
  let r16 = @riff.ByteReader::at(data, smpl.data_offset)
  match sm24_opt {
    Some(sm24) => {
      let r24 = @riff.ByteReader::at(data, sm24.data_offset)
      for i in 0..<sample_count {
        let hi = r16.read_i16_le() catch { err => raise Riff(err~) }
        let lo = r24.read_u8() catch { err => raise Riff(err~) }
        let val24 = (hi << 8) | lo
        samples[i] = val24.to_double() / 8388608.0
      }
    }
    None =>
      for i in 0..<sample_count {
        let s = r16.read_i16_le() catch { err => raise Riff(err~) }
        samples[i] = s.to_double() / 32768.0
      }
  }
  samples
}

///|
priv struct RawPresetHeader {
  name : String
  preset : Int32
  bank : Int32
  bag_ndx : Int32
  library : Int32
  genre : Int32
  morphology : Int32
}

///|
priv struct RawBag {
  gen_ndx : Int32
  mod_ndx : Int32
}

///|
priv struct RawInstHeader {
  name : String
  bag_ndx : Int32
}

///|
fn require_chunk(
  parent : @riff.RiffChunk,
  name : String,
  record_size : Int32,
) -> @riff.RiffChunk raise Sf2Error {
  let chunk = match parent.find_child(name) {
    Some(c) => c
    None => raise MissingChunk(name~)
  }
  if chunk.data_size % record_size != 0 || chunk.data_size < record_size {
    raise InvalidChunkLength(
      name~,
      expected_multiple=record_size,
      actual=chunk.data_size,
    )
  }
  chunk
}

///|
fn parse_pdta(
  data : Bytes,
  pdta : @riff.RiffChunk,
) -> (Array[SampleHeader], Array[Instrument], Array[Preset]) raise Sf2Error {
  let phdr_c = require_chunk(pdta, "phdr", 38)
  let pbag_c = require_chunk(pdta, "pbag", 4)
  let pmod_c = require_chunk(pdta, "pmod", 10)
  let pgen_c = require_chunk(pdta, "pgen", 4)
  let inst_c = require_chunk(pdta, "inst", 22)
  let ibag_c = require_chunk(pdta, "ibag", 4)
  let imod_c = require_chunk(pdta, "imod", 10)
  let igen_c = require_chunk(pdta, "igen", 4)
  let shdr_c = require_chunk(pdta, "shdr", 46)

  let shdr = parse_shdr(data, shdr_c)
  let pmod = parse_mods(data, pmod_c)
  let pgen = parse_gens(data, pgen_c)
  let pbag = parse_bags(data, pbag_c)
  let phdr = parse_phdr(data, phdr_c)

  let imod = parse_mods(data, imod_c)
  let igen = parse_gens(data, igen_c)
  let ibag = parse_bags(data, ibag_c)
  let inst_raw = parse_inst(data, inst_c)

  let instruments = build_instruments(inst_raw, ibag, igen, imod)
  let presets = build_presets(phdr, pbag, pgen, pmod)
  (shdr, instruments, presets)
}

///|
fn parse_shdr(
  data : Bytes,
  chunk : @riff.RiffChunk,
) -> Array[SampleHeader] raise Sf2Error {
  let count = chunk.data_size / 46
  if count < 1 {
    raise MissingSentinel(table="shdr")
  }
  let r = @riff.ByteReader::at(data, chunk.data_offset)
  let out : Array[SampleHeader] = []
  // Last record is EOS sentinel.
  for i in 0..<count {
    let name = r.read_ascii_z(20) catch { err => raise Riff(err~) }
    let start = r.read_u32_le() catch { err => raise Riff(err~) }
    let end = r.read_u32_le() catch { err => raise Riff(err~) }
    let start_loop = r.read_u32_le() catch { err => raise Riff(err~) }
    let end_loop = r.read_u32_le() catch { err => raise Riff(err~) }
    let sample_rate = r.read_u32_le() catch { err => raise Riff(err~) }
    let original_pitch = r.read_u8() catch { err => raise Riff(err~) }
    let pitch_correction = r.read_i8() catch { err => raise Riff(err~) }
    let sample_link = r.read_u16_le() catch { err => raise Riff(err~) }
    let sample_type_raw = r.read_u16_le() catch { err => raise Riff(err~) }
    if i < count - 1 {
      out.push({
        name,
        start: start.reinterpret_as_int(),
        end: end.reinterpret_as_int(),
        start_loop: start_loop.reinterpret_as_int(),
        end_loop: end_loop.reinterpret_as_int(),
        sample_rate: sample_rate.reinterpret_as_int(),
        original_pitch,
        pitch_correction,
        sample_link,
        sample_type: SampleType::from_raw(sample_type_raw),
      })
    }
  }
  out
}

///|
fn parse_phdr(
  data : Bytes,
  chunk : @riff.RiffChunk,
) -> Array[RawPresetHeader] raise Sf2Error {
  let count = chunk.data_size / 38
  let r = @riff.ByteReader::at(data, chunk.data_offset)
  let out : Array[RawPresetHeader] = []
  for _ in 0..<count {
    let name = r.read_ascii_z(20) catch { err => raise Riff(err~) }
    let preset = r.read_u16_le() catch { err => raise Riff(err~) }
    let bank = r.read_u16_le() catch { err => raise Riff(err~) }
    let bag_ndx = r.read_u16_le() catch { err => raise Riff(err~) }
    let library = r.read_u32_le() catch { err => raise Riff(err~) }
    let genre = r.read_u32_le() catch { err => raise Riff(err~) }
    let morphology = r.read_u32_le() catch { err => raise Riff(err~) }
    out.push({
      name,
      preset,
      bank,
      bag_ndx,
      library: library.reinterpret_as_int(),
      genre: genre.reinterpret_as_int(),
      morphology: morphology.reinterpret_as_int(),
    })
  }
  out
}

///|
fn parse_inst(
  data : Bytes,
  chunk : @riff.RiffChunk,
) -> Array[RawInstHeader] raise Sf2Error {
  let count = chunk.data_size / 22
  let r = @riff.ByteReader::at(data, chunk.data_offset)
  let out : Array[RawInstHeader] = []
  for _ in 0..<count {
    let name = r.read_ascii_z(20) catch { err => raise Riff(err~) }
    let bag_ndx = r.read_u16_le() catch { err => raise Riff(err~) }
    out.push({ name, bag_ndx, })
  }
  out
}

///|
fn parse_bags(
  data : Bytes,
  chunk : @riff.RiffChunk,
) -> Array[RawBag] raise Sf2Error {
  let count = chunk.data_size / 4
  let r = @riff.ByteReader::at(data, chunk.data_offset)
  let out : Array[RawBag] = []
  for _ in 0..<count {
    let gen_ndx = r.read_u16_le() catch { err => raise Riff(err~) }
    let mod_ndx = r.read_u16_le() catch { err => raise Riff(err~) }
    out.push({ gen_ndx, mod_ndx, })
  }
  out
}

///|
fn parse_gens(
  data : Bytes,
  chunk : @riff.RiffChunk,
) -> Array[RawGenerator] raise Sf2Error {
  let count = chunk.data_size / 4
  let r = @riff.ByteReader::at(data, chunk.data_offset)
  let out : Array[RawGenerator] = []
  for _ in 0..<count {
    let oper = r.read_u16_le() catch { err => raise Riff(err~) }
    let amount = r.read_u16_le() catch { err => raise Riff(err~) }
    out.push({ oper, amount, })
  }
  out
}

///|
fn parse_mods(
  data : Bytes,
  chunk : @riff.RiffChunk,
) -> Array[Modulator] raise Sf2Error {
  let count = chunk.data_size / 10
  let r = @riff.ByteReader::at(data, chunk.data_offset)
  let out : Array[Modulator] = []
  for _ in 0..<count {
    let src_oper = r.read_u16_le() catch { err => raise Riff(err~) }
    let dest_oper = r.read_u16_le() catch { err => raise Riff(err~) }
    let amount = r.read_i16_le() catch { err => raise Riff(err~) }
    let amt_src_oper = r.read_u16_le() catch { err => raise Riff(err~) }
    let trans_oper = r.read_u16_le() catch { err => raise Riff(err~) }
    out.push({ src_oper, dest_oper, amount, amt_src_oper, trans_oper, })
  }
  out
}

///|
fn slice_zone(
  bag_idx : Int32,
  bags : Array[RawBag],
  gens : Array[RawGenerator],
  mods : Array[Modulator],
) -> Zone raise Sf2Error {
  if bag_idx < 0 || bag_idx + 1 >= bags.length() {
    raise OutOfRangeIndex(table="bag", index=bag_idx, limit=bags.length())
  }
  let g_start = bags[bag_idx].gen_ndx
  let g_end = bags[bag_idx + 1].gen_ndx
  let m_start = bags[bag_idx].mod_ndx
  let m_end = bags[bag_idx + 1].mod_ndx
  if g_start < 0 || g_end < g_start || g_end > gens.length() {
    raise OutOfRangeIndex(table="gen", index=g_end, limit=gens.length())
  }
  if m_start < 0 || m_end < m_start || m_end > mods.length() {
    raise OutOfRangeIndex(table="mod", index=m_end, limit=mods.length())
  }
  let zone_gens : Array[RawGenerator] = []
  for gi in g_start..<g_end {
    zone_gens.push(gens[gi])
  }
  let zone_mods : Array[Modulator] = []
  for mi in m_start..<m_end {
    zone_mods.push(mods[mi])
  }
  { generators: zone_gens, modulators: zone_mods, }
}

///|
fn zone_has_gen(zone : Zone, target_oper : Int32) -> Bool {
  for g in zone.generators {
    if g.oper == target_oper {
      return true
    }
  }
  false
}

///|
fn build_instruments(
  insts : Array[RawInstHeader],
  ibag : Array[RawBag],
  igen : Array[RawGenerator],
  imod : Array[Modulator],
) -> Array[Instrument] raise Sf2Error {
  if insts.length() < 1 {
    raise MissingSentinel(table="inst")
  }
  let out : Array[Instrument] = []
  let n = insts.length() - 1
  for i in 0..<n {
    let start_bag = insts[i].bag_ndx
    let end_bag = insts[i + 1].bag_ndx
    if start_bag < 0 || end_bag < start_bag || end_bag >= ibag.length() {
      raise OutOfRangeIndex(table="ibag", index=end_bag, limit=ibag.length())
    }
    let mut global_zone : Zone? = None
    let local_zones : Array[Zone] = []
    for b in start_bag..<end_bag {
      let z = slice_zone(b, ibag, igen, imod)
      // SF2 §7.7: First zone without sampleID is the global zone.
      if b == start_bag && !zone_has_gen(z, GEN_SAMPLE_ID) {
        global_zone = Some(z)
      } else if zone_has_gen(z, GEN_SAMPLE_ID) {
        local_zones.push(z)
      }
    }
    out.push({ name: insts[i].name, global_zone, zones: local_zones, })
  }
  out
}

///|
fn build_presets(
  phdr : Array[RawPresetHeader],
  pbag : Array[RawBag],
  pgen : Array[RawGenerator],
  pmod : Array[Modulator],
) -> Array[Preset] raise Sf2Error {
  if phdr.length() < 1 {
    raise MissingSentinel(table="phdr")
  }
  let out : Array[Preset] = []
  let n = phdr.length() - 1
  for i in 0..<n {
    let start_bag = phdr[i].bag_ndx
    let end_bag = phdr[i + 1].bag_ndx
    if start_bag < 0 || end_bag < start_bag || end_bag >= pbag.length() {
      raise OutOfRangeIndex(table="pbag", index=end_bag, limit=pbag.length())
    }
    let mut global_zone : Zone? = None
    let local_zones : Array[Zone] = []
    for b in start_bag..<end_bag {
      let z = slice_zone(b, pbag, pgen, pmod)
      if b == start_bag && !zone_has_gen(z, GEN_INSTRUMENT) {
        global_zone = Some(z)
      } else if zone_has_gen(z, GEN_INSTRUMENT) {
        local_zones.push(z)
      }
    }
    out.push({
      name: phdr[i].name,
      preset: phdr[i].preset,
      bank: phdr[i].bank,
      library: phdr[i].library,
      genre: phdr[i].genre,
      morphology: phdr[i].morphology,
      global_zone,
      zones: local_zones,
    })
  }
  out
}

///|
/// Find a preset by `(bank, preset)` number. Falls back to bank 0 if needed when `fallback_bank0` is true.
pub fn SoundFont::find_preset(
  self : SoundFont,
  bank : Int32,
  preset_num : Int32,
  fallback_bank0~ : Bool = false,
) -> Preset? {
  for p in self.presets {
    if p.bank == bank && p.preset == preset_num {
      return Some(p)
    }
  }
  if fallback_bank0 && bank != 0 {
    for p in self.presets {
      if p.bank == 0 && p.preset == preset_num {
        return Some(p)
      }
    }
  }
  None
}

///|
fn default_gen_table() -> FixedArray[Int32] {
  let t = FixedArray::make(60, 0)
  t[GEN_INITIAL_FILTER_FC] = 13500
  t[GEN_DELAY_MOD_LFO] = -12000
  t[GEN_DELAY_VIB_LFO] = -12000
  t[GEN_DELAY_MOD_ENV] = -12000
  t[GEN_ATTACK_MOD_ENV] = -12000
  t[GEN_HOLD_MOD_ENV] = -12000
  t[GEN_DECAY_MOD_ENV] = -12000
  t[GEN_RELEASE_MOD_ENV] = -12000
  t[GEN_DELAY_VOL_ENV] = -12000
  t[GEN_ATTACK_VOL_ENV] = -12000
  t[GEN_HOLD_VOL_ENV] = -12000
  t[GEN_DECAY_VOL_ENV] = -12000
  t[GEN_RELEASE_VOL_ENV] = -12000
  t[GEN_KEYNUM] = -1
  t[GEN_VELOCITY] = -1
  t[GEN_SCALE_TUNING] = 100
  t[GEN_OVERRIDING_ROOT_KEY] = -1
  t
}

///|
fn apply_override_zone(
  table : FixedArray[Int32],
  key_range : Ref[(Int32, Int32)],
  vel_range : Ref[(Int32, Int32)],
  zone : Zone,
) -> Unit {
  for g in zone.generators {
    if g.oper == GEN_KEY_RANGE {
      key_range.val = (g.range_low(), g.range_high())
    } else if g.oper == GEN_VEL_RANGE {
      vel_range.val = (g.range_low(), g.range_high())
    } else if g.oper >= 0 && g.oper < table.length() {
      table[g.oper] = g.signed()
    }
  }
}

///|
fn collect_preset_deltas(
  global_zone : Zone?,
  local_zone : Zone,
) -> (FixedArray[Int32], (Int32, Int32), (Int32, Int32), Int32?) {
  let deltas = FixedArray::make(60, 0)
  let mut p_key = (0, 127)
  let mut p_vel = (0, 127)
  let mut inst_id : Int32? = None
  match global_zone {
    Some(gz) =>
      for g in gz.generators {
        if g.oper == GEN_KEY_RANGE {
          p_key = (g.range_low(), g.range_high())
        } else if g.oper == GEN_VEL_RANGE {
          p_vel = (g.range_low(), g.range_high())
        } else if g.oper >= 0 && g.oper < deltas.length() {
          deltas[g.oper] = g.signed()
        }
      }
    None => ()
  }
  for g in local_zone.generators {
    if g.oper == GEN_KEY_RANGE {
      p_key = (g.range_low(), g.range_high())
    } else if g.oper == GEN_VEL_RANGE {
      p_vel = (g.range_low(), g.range_high())
    } else if g.oper == GEN_INSTRUMENT {
      inst_id = Some(g.amount & 0xFFFF)
    } else if g.oper >= 0 && g.oper < deltas.length() {
      deltas[g.oper] = g.signed()
    }
  }
  (deltas, p_key, p_vel, inst_id)
}

///|
fn max_int(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn min_int(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn append_or_override_mods(
  dst : Array[Modulator],
  src : Array[Modulator],
) -> Unit {
  for m in src {
    let mut replaced = false
    for i in 0..<dst.length() {
      let existing = dst[i]
      if existing.src_oper == m.src_oper &&
        existing.dest_oper == m.dest_oper &&
        existing.amt_src_oper == m.amt_src_oper {
        dst[i] = m
        replaced = true
        break
      }
    }
    if !replaced {
      dst.push(m)
    }
  }
}

///|
/// Resolve all flattened `ZoneRegion` entries for a given `Preset`, applying
/// global-zone inheritance, key/velocity range intersection, and additive preset offsets.
pub fn SoundFont::resolve_preset_regions(
  self : SoundFont,
  preset : Preset,
) -> Array[ZoneRegion] {
  let regions : Array[ZoneRegion] = []
  for p_zone in preset.zones {
    let (p_deltas, p_key, p_vel, inst_id_opt) = collect_preset_deltas(
      preset.global_zone,
      p_zone,
    )
    match inst_id_opt {
      None => ()
      Some(inst_idx) => {
        if inst_idx < 0 || inst_idx >= self.instruments.length() {
          continue
        }
        let inst = self.instruments[inst_idx]
        for i_zone in inst.zones {
          let table = default_gen_table()
          let i_key = Ref((0, 127))
          let i_vel = Ref((0, 127))
          match inst.global_zone {
            Some(igz) => apply_override_zone(table, i_key, i_vel, igz)
            None => ()
          }
          apply_override_zone(table, i_key, i_vel, i_zone)
          let key_low = max_int(p_key.0, i_key.val.0)
          let key_high = min_int(p_key.1, i_key.val.1)
          let vel_low = max_int(p_vel.0, i_vel.val.0)
          let vel_high = min_int(p_vel.1, i_vel.val.1)
          if key_low > key_high || vel_low > vel_high {
            continue
          }
          let sample_index = table[GEN_SAMPLE_ID]
          if sample_index < 0 || sample_index >= self.sample_headers.length() {
            continue
          }
          // Additive preset-level generator offsets (SF2 §9.4: excludes range/index/sampleModes/exclusive/rootKey/keynum/velocity).
          let additive_ops = [
            GEN_MOD_LFO_TO_PITCH,
            GEN_VIB_LFO_TO_PITCH,
            GEN_MOD_ENV_TO_PITCH,
            GEN_INITIAL_FILTER_FC,
            GEN_INITIAL_FILTER_Q,
            GEN_MOD_LFO_TO_FILTER_FC,
            GEN_MOD_ENV_TO_FILTER_FC,
            GEN_MOD_LFO_TO_VOLUME,
            GEN_CHORUS_EFFECTS_SEND,
            GEN_REVERB_EFFECTS_SEND,
            GEN_PAN,
            GEN_DELAY_MOD_LFO,
            GEN_FREQ_MOD_LFO,
            GEN_DELAY_VIB_LFO,
            GEN_FREQ_VIB_LFO,
            GEN_DELAY_MOD_ENV,
            GEN_ATTACK_MOD_ENV,
            GEN_HOLD_MOD_ENV,
            GEN_DECAY_MOD_ENV,
            GEN_SUSTAIN_MOD_ENV,
            GEN_RELEASE_MOD_ENV,
            GEN_KEYNUM_TO_MOD_ENV_HOLD,
            GEN_KEYNUM_TO_MOD_ENV_DECAY,
            GEN_DELAY_VOL_ENV,
            GEN_ATTACK_VOL_ENV,
            GEN_HOLD_VOL_ENV,
            GEN_DECAY_VOL_ENV,
            GEN_SUSTAIN_VOL_ENV,
            GEN_RELEASE_VOL_ENV,
            GEN_KEYNUM_TO_VOL_ENV_HOLD,
            GEN_KEYNUM_TO_VOL_ENV_DECAY,
            GEN_INITIAL_ATTENUATION,
            GEN_COARSE_TUNE,
            GEN_FINE_TUNE,
            GEN_SCALE_TUNING,
          ]
          for op in additive_ops {
            table[op] = table[op] + p_deltas[op]
          }
          let start_offset = table[GEN_START_ADDRS_OFFSET] +
            table[GEN_START_ADDRS_COARSE_OFFSET] * 32768
          let end_offset = table[GEN_END_ADDRS_OFFSET] +
            table[GEN_END_ADDRS_COARSE_OFFSET] * 32768
          let start_loop_offset = table[GEN_STARTLOOP_ADDRS_OFFSET] +
            table[GEN_STARTLOOP_ADDRS_COARSE_OFFSET] * 32768
          let end_loop_offset = table[GEN_ENDLOOP_ADDRS_OFFSET] +
            table[GEN_ENDLOOP_ADDRS_COARSE_OFFSET] * 32768
          let mods : Array[Modulator] = []
          match inst.global_zone {
            Some(igz) => append_or_override_mods(mods, igz.modulators)
            None => ()
          }
          append_or_override_mods(mods, i_zone.modulators)
          match preset.global_zone {
            Some(pgz) => append_or_override_mods(mods, pgz.modulators)
            None => ()
          }
          append_or_override_mods(mods, p_zone.modulators)
          regions.push({
            key_low,
            key_high,
            vel_low,
            vel_high,
            sample_index,
            start_offset,
            end_offset,
            start_loop_offset,
            end_loop_offset,
            mod_lfo_to_pitch: table[GEN_MOD_LFO_TO_PITCH],
            vib_lfo_to_pitch: table[GEN_VIB_LFO_TO_PITCH],
            mod_env_to_pitch: table[GEN_MOD_ENV_TO_PITCH],
            initial_filter_fc: table[GEN_INITIAL_FILTER_FC],
            initial_filter_q: table[GEN_INITIAL_FILTER_Q],
            mod_lfo_to_filter_fc: table[GEN_MOD_LFO_TO_FILTER_FC],
            mod_env_to_filter_fc: table[GEN_MOD_ENV_TO_FILTER_FC],
            mod_lfo_to_volume: table[GEN_MOD_LFO_TO_VOLUME],
            chorus_send: table[GEN_CHORUS_EFFECTS_SEND],
            reverb_send: table[GEN_REVERB_EFFECTS_SEND],
            pan: table[GEN_PAN],
            delay_mod_lfo: table[GEN_DELAY_MOD_LFO],
            freq_mod_lfo: table[GEN_FREQ_MOD_LFO],
            delay_vib_lfo: table[GEN_DELAY_VIB_LFO],
            freq_vib_lfo: table[GEN_FREQ_VIB_LFO],
            delay_mod_env: table[GEN_DELAY_MOD_ENV],
            attack_mod_env: table[GEN_ATTACK_MOD_ENV],
            hold_mod_env: table[GEN_HOLD_MOD_ENV],
            decay_mod_env: table[GEN_DECAY_MOD_ENV],
            sustain_mod_env: table[GEN_SUSTAIN_MOD_ENV],
            release_mod_env: table[GEN_RELEASE_MOD_ENV],
            keynum_to_mod_env_hold: table[GEN_KEYNUM_TO_MOD_ENV_HOLD],
            keynum_to_mod_env_decay: table[GEN_KEYNUM_TO_MOD_ENV_DECAY],
            delay_vol_env: table[GEN_DELAY_VOL_ENV],
            attack_vol_env: table[GEN_ATTACK_VOL_ENV],
            hold_vol_env: table[GEN_HOLD_VOL_ENV],
            decay_vol_env: table[GEN_DECAY_VOL_ENV],
            sustain_vol_env: table[GEN_SUSTAIN_VOL_ENV],
            release_vol_env: table[GEN_RELEASE_VOL_ENV],
            keynum_to_vol_env_hold: table[GEN_KEYNUM_TO_VOL_ENV_HOLD],
            keynum_to_vol_env_decay: table[GEN_KEYNUM_TO_VOL_ENV_DECAY],
            keynum_override: table[GEN_KEYNUM],
            velocity_override: table[GEN_VELOCITY],
            initial_attenuation: table[GEN_INITIAL_ATTENUATION],
            coarse_tune: table[GEN_COARSE_TUNE],
            fine_tune: table[GEN_FINE_TUNE],
            sample_modes: LoopMode::from_int(table[GEN_SAMPLE_MODES]),
            scale_tuning: table[GEN_SCALE_TUNING],
            exclusive_class: table[GEN_EXCLUSIVE_CLASS],
            overriding_root_key: table[GEN_OVERRIDING_ROOT_KEY],
            modulators: mods,
          })
        }
      }
    }
  }
  regions
}
