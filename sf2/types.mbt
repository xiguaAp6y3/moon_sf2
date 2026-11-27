///|
/// Errors raised while parsing or validating a SoundFont2 (`sfbk`) binary.
#derive(Debug, Eq)
pub(all) suberror Sf2Error {
  Riff(err~ : @riff.RiffError)
  InvalidFormType(expected~ : String, actual~ : String)
  MissingChunk(name~ : String)
  InvalidChunkLength(
    name~ : String,
    expected_multiple~ : Int32,
    actual~ : Int32,
  )
  MissingSentinel(table~ : String)
  OutOfRangeIndex(table~ : String, index~ : Int32, limit~ : Int32)
}

///|
pub impl Show for Sf2Error with fn output(self, logger) {
  match self {
    Riff(err~) => logger.write_string("RIFF error: \{err}")
    InvalidFormType(expected~, actual~) =>
      logger.write_string(
        "Invalid SF2 form type: expected '\{expected}', got '\{actual}'",
      )
    MissingChunk(name~) =>
      logger.write_string("Missing required chunk '\{name}'")
    InvalidChunkLength(name~, expected_multiple~, actual~) =>
      logger.write_string(
        "Invalid chunk length for '\{name}': length \{actual} not compatible with record size \{expected_multiple}",
      )
    MissingSentinel(table~) =>
      logger.write_string("Missing terminal sentinel record in '\{table}'")
    OutOfRangeIndex(table~, index~, limit~) =>
      logger.write_string(
        "Out of range index \{index} in '\{table}' (limit \{limit})",
      )
  }
}

///|
pub extend Sf2Error with Show::{output, to_string}

///|
pub extend Sf2Error with Eq::{equal, not_equal}

///|
pub extend Sf2Error with @debug.Debug::{to_repr}

///|
/// SoundFont version tuple (`major.minor`).
#derive(Debug, Eq)
pub(all) struct SoundFontVersion {
  major : Int32
  minor : Int32
}

///|
pub extend SoundFontVersion with Eq::{equal, not_equal}

///|
pub extend SoundFontVersion with @debug.Debug::{to_repr}

///|
/// Metadata extracted from the `LIST/INFO` chunk.
#derive(Debug, Eq)
pub(all) struct SoundFontInfo {
  version : SoundFontVersion
  sound_engine : String
  bank_name : String
  rom_name : String
  rom_version : SoundFontVersion?
  creation_date : String
  author : String
  target_product : String
  copyright : String
  comments : String
  tools : String
}

///|
pub extend SoundFontInfo with Eq::{equal, not_equal}

///|
pub extend SoundFontInfo with @debug.Debug::{to_repr}

///|
pub fn SoundFontInfo::default() -> SoundFontInfo {
  {
    version: { major: 2, minor: 1, },
    sound_engine: "EMU8000",
    bank_name: "",
    rom_name: "",
    rom_version: None,
    creation_date: "",
    author: "",
    target_product: "",
    copyright: "",
    comments: "",
    tools: "",
  }
}

///|
/// Sample link / channel role in `shdr` (`sfSampleType`).
#derive(Debug, Eq)
pub(all) enum SampleType {
  Mono
  Right
  Left
  Linked
  RomMono
  RomRight
  RomLeft
  RomLinked
  Unknown(Int32)
}

///|
pub extend SampleType with Eq::{equal, not_equal}

///|
pub extend SampleType with @debug.Debug::{to_repr}

///|
pub fn SampleType::from_raw(raw : Int32) -> SampleType {
  match raw {
    1 => Mono
    2 => Right
    4 => Left
    8 => Linked
    0x8001 => RomMono
    0x8002 => RomRight
    0x8004 => RomLeft
    0x8008 => RomLinked
    other => Unknown(other)
  }
}

///|
pub fn SampleType::to_raw(self : SampleType) -> Int32 {
  match self {
    Mono => 1
    Right => 2
    Left => 4
    Linked => 8
    RomMono => 0x8001
    RomRight => 0x8002
    RomLeft => 0x8004
    RomLinked => 0x8008
    Unknown(v) => v
  }
}

///|
/// Loop playback mode specified by generator `sampleModes` (54).
#derive(Debug, Eq)
pub(all) enum LoopMode {
  NoLoop
  LoopContinuous
  LoopUntilRelease
}

///|
pub extend LoopMode with Eq::{equal, not_equal}

///|
pub extend LoopMode with @debug.Debug::{to_repr}

///|
pub fn LoopMode::from_int(v : Int32) -> LoopMode {
  match v {
    1 => LoopContinuous
    3 => LoopUntilRelease
    _ => NoLoop
  }
}

///|
/// Sample descriptor parsed from `shdr` (46 bytes per record).
#derive(Debug, Eq)
pub(all) struct SampleHeader {
  name : String
  start : Int32
  end : Int32
  start_loop : Int32
  end_loop : Int32
  sample_rate : Int32
  original_pitch : Int32
  pitch_correction : Int32
  sample_link : Int32
  sample_type : SampleType
}

///|
pub extend SampleHeader with Eq::{equal, not_equal}

///|
pub extend SampleHeader with @debug.Debug::{to_repr}

///|
/// Raw SF2 generator entry (`sfGenOper`, `genAmount`).
#derive(Debug, Eq)
pub(all) struct RawGenerator {
  oper : Int32
  amount : Int32
}

///|
pub extend RawGenerator with Eq::{equal, not_equal}

///|
pub extend RawGenerator with @debug.Debug::{to_repr}

///|
/// Extract low byte (`0..=127`) of a range generator (`keyRange` / `velRange`).
pub fn RawGenerator::range_low(self : RawGenerator) -> Int32 {
  self.amount & 0xFF
}

///|
/// Extract high byte (`0..=127`) of a range generator (`keyRange` / `velRange`).
pub fn RawGenerator::range_high(self : RawGenerator) -> Int32 {
  (self.amount >> 8) & 0xFF
}

///|
/// Interpret the raw 16-bit generator amount as a signed `Int16` (`-32768..=32767`).
pub fn RawGenerator::signed(self : RawGenerator) -> Int32 {
  let u = self.amount & 0xFFFF
  if u >= 32768 {
    u - 65536
  } else {
    u
  }
}

///|
/// Raw SF2 modulator record (`pmod` / `imod`, 10 bytes each).
#derive(Debug, Eq)
pub(all) struct Modulator {
  src_oper : Int32
  dest_oper : Int32
  amount : Int32
  amt_src_oper : Int32
  trans_oper : Int32
}

///|
pub extend Modulator with Eq::{equal, not_equal}

///|
pub extend Modulator with @debug.Debug::{to_repr}

///|
/// Preset or instrument zone containing generators and modulators.
#derive(Debug, Eq)
pub(all) struct Zone {
  generators : Array[RawGenerator]
  modulators : Array[Modulator]
}

///|
pub extend Zone with Eq::{equal, not_equal}

///|
pub extend Zone with @debug.Debug::{to_repr}

///|
/// Parsed instrument (`inst` + `ibag`/`imod`/`igen`).
#derive(Debug, Eq)
pub(all) struct Instrument {
  name : String
  global_zone : Zone?
  zones : Array[Zone]
}

///|
pub extend Instrument with Eq::{equal, not_equal}

///|
pub extend Instrument with @debug.Debug::{to_repr}

///|
/// Parsed preset (`phdr` + `pbag`/`pmod`/`pgen`).
#derive(Debug, Eq)
pub(all) struct Preset {
  name : String
  preset : Int32
  bank : Int32
  library : Int32
  genre : Int32
  morphology : Int32
  global_zone : Zone?
  zones : Array[Zone]
}

///|
pub extend Preset with Eq::{equal, not_equal}

///|
pub extend Preset with @debug.Debug::{to_repr}

///|
/// Resolved synthesis parameters for a single playable `(PresetZone x InstrumentZone)` pair.
/// All generators are already merged according to SoundFont 2.01 §9.4.
#derive(Debug, Eq)
pub(all) struct ZoneRegion {
  key_low : Int32
  key_high : Int32
  vel_low : Int32
  vel_high : Int32
  sample_index : Int32
  start_offset : Int32
  end_offset : Int32
  start_loop_offset : Int32
  end_loop_offset : Int32
  mod_lfo_to_pitch : Int32
  vib_lfo_to_pitch : Int32
  mod_env_to_pitch : Int32
  initial_filter_fc : Int32
  initial_filter_q : Int32
  mod_lfo_to_filter_fc : Int32
  mod_env_to_filter_fc : Int32
  mod_lfo_to_volume : Int32
  chorus_send : Int32
  reverb_send : Int32
  pan : Int32
  delay_mod_lfo : Int32
  freq_mod_lfo : Int32
  delay_vib_lfo : Int32
  freq_vib_lfo : Int32
  delay_mod_env : Int32
  attack_mod_env : Int32
  hold_mod_env : Int32
  decay_mod_env : Int32
  sustain_mod_env : Int32
  release_mod_env : Int32
  keynum_to_mod_env_hold : Int32
  keynum_to_mod_env_decay : Int32
  delay_vol_env : Int32
  attack_vol_env : Int32
  hold_vol_env : Int32
  decay_vol_env : Int32
  sustain_vol_env : Int32
  release_vol_env : Int32
  keynum_to_vol_env_hold : Int32
  keynum_to_vol_env_decay : Int32
  keynum_override : Int32
  velocity_override : Int32
  initial_attenuation : Int32
  coarse_tune : Int32
  fine_tune : Int32
  sample_modes : LoopMode
  scale_tuning : Int32
  exclusive_class : Int32
  overriding_root_key : Int32
  modulators : Array[Modulator]
}

///|
pub extend ZoneRegion with Eq::{equal, not_equal}

///|
pub extend ZoneRegion with @debug.Debug::{to_repr}

///|
/// Check whether this region covers the MIDI `(key, velocity)` pair.
pub fn ZoneRegion::matches(
  self : ZoneRegion,
  key : Int32,
  velocity : Int32,
) -> Bool {
  key >= self.key_low &&
  key <= self.key_high &&
  velocity >= self.vel_low &&
  velocity <= self.vel_high
}

///|
/// Complete in-memory SoundFont2 bank ready for synthesis.
pub struct SoundFont {
  info : SoundFontInfo
  samples : FixedArray[Double]
  sample_headers : Array[SampleHeader]
  instruments : Array[Instrument]
  presets : Array[Preset]
}

///|
/// SoundFont generator operator IDs per SF2 2.01 §8.1.2.
pub const GEN_START_ADDRS_OFFSET : Int32 = 0

///|
pub const GEN_END_ADDRS_OFFSET : Int32 = 1

///|
pub const GEN_STARTLOOP_ADDRS_OFFSET : Int32 = 2

///|
pub const GEN_ENDLOOP_ADDRS_OFFSET : Int32 = 3

///|
pub const GEN_START_ADDRS_COARSE_OFFSET : Int32 = 4

///|
pub const GEN_MOD_LFO_TO_PITCH : Int32 = 5

///|
pub const GEN_VIB_LFO_TO_PITCH : Int32 = 6

///|
pub const GEN_MOD_ENV_TO_PITCH : Int32 = 7

///|
pub const GEN_INITIAL_FILTER_FC : Int32 = 8

///|
pub const GEN_INITIAL_FILTER_Q : Int32 = 9

///|
pub const GEN_MOD_LFO_TO_FILTER_FC : Int32 = 10

///|
pub const GEN_MOD_ENV_TO_FILTER_FC : Int32 = 11

///|
pub const GEN_END_ADDRS_COARSE_OFFSET : Int32 = 12

///|
pub const GEN_MOD_LFO_TO_VOLUME : Int32 = 13

///|
pub const GEN_CHORUS_EFFECTS_SEND : Int32 = 15

///|
pub const GEN_REVERB_EFFECTS_SEND : Int32 = 16

///|
pub const GEN_PAN : Int32 = 17

///|
pub const GEN_DELAY_MOD_LFO : Int32 = 21

///|
pub const GEN_FREQ_MOD_LFO : Int32 = 22

///|
pub const GEN_DELAY_VIB_LFO : Int32 = 23

///|
pub const GEN_FREQ_VIB_LFO : Int32 = 24

///|
pub const GEN_DELAY_MOD_ENV : Int32 = 25

///|
pub const GEN_ATTACK_MOD_ENV : Int32 = 26

///|
pub const GEN_HOLD_MOD_ENV : Int32 = 27

///|
pub const GEN_DECAY_MOD_ENV : Int32 = 28

///|
pub const GEN_SUSTAIN_MOD_ENV : Int32 = 29

///|
pub const GEN_RELEASE_MOD_ENV : Int32 = 30

///|
pub const GEN_KEYNUM_TO_MOD_ENV_HOLD : Int32 = 31

///|
pub const GEN_KEYNUM_TO_MOD_ENV_DECAY : Int32 = 32

///|
pub const GEN_DELAY_VOL_ENV : Int32 = 33

///|
pub const GEN_ATTACK_VOL_ENV : Int32 = 34

///|
pub const GEN_HOLD_VOL_ENV : Int32 = 35

///|
pub const GEN_DECAY_VOL_ENV : Int32 = 36

///|
pub const GEN_SUSTAIN_VOL_ENV : Int32 = 37

///|
pub const GEN_RELEASE_VOL_ENV : Int32 = 38

///|
pub const GEN_KEYNUM_TO_VOL_ENV_HOLD : Int32 = 39

///|
pub const GEN_KEYNUM_TO_VOL_ENV_DECAY : Int32 = 40

///|
pub const GEN_INSTRUMENT : Int32 = 41

///|
pub const GEN_KEY_RANGE : Int32 = 43

///|
pub const GEN_VEL_RANGE : Int32 = 44

///|
pub const GEN_STARTLOOP_ADDRS_COARSE_OFFSET : Int32 = 45

///|
pub const GEN_KEYNUM : Int32 = 46

///|
pub const GEN_VELOCITY : Int32 = 47

///|
pub const GEN_INITIAL_ATTENUATION : Int32 = 48

///|
pub const GEN_ENDLOOP_ADDRS_COARSE_OFFSET : Int32 = 50

///|
pub const GEN_COARSE_TUNE : Int32 = 51

///|
pub const GEN_FINE_TUNE : Int32 = 52

///|
pub const GEN_SAMPLE_ID : Int32 = 53

///|
pub const GEN_SAMPLE_MODES : Int32 = 54

///|
pub const GEN_SCALE_TUNING : Int32 = 56

///|
pub const GEN_EXCLUSIVE_CLASS : Int32 = 57

///|
pub const GEN_OVERRIDING_ROOT_KEY : Int32 = 58
