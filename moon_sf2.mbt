///|
/// Parse a SoundFont2 (`.sf2`) byte buffer into a `@sf2.SoundFont`.
pub fn parse_sf2(data : Bytes) -> @sf2.SoundFont raise @sf2.Sf2Error {
  @sf2.parse_sf2(data)
}

///|
/// Parse a Standard MIDI File (`.mid`) byte buffer into a `@midi.MidiFile`.
pub fn parse_midi(data : Bytes) -> @midi.MidiFile raise @midi.MidiError {
  @midi.parse_midi(data)
}

///|
/// Create a `Synthesizer` from a parsed `SoundFont` with optional `SynthSettings`.
pub fn new_synthesizer(
  sound_font : @sf2.SoundFont,
  sample_rate~ : Int32 = 44100,
  maximum_polyphony~ : Int32 = 64,
  enable_effects~ : Bool = true,
  master_volume~ : Double = 0.5,
) -> @synth.Synthesizer {
  let settings : @synth.SynthSettings = {
    sample_rate,
    block_size: 64,
    maximum_polyphony,
    enable_reverb_and_chorus: enable_effects,
    master_volume,
    interpolation: Cubic,
  }
  @synth.Synthesizer::new(sound_font, settings~)
}

///|
/// Encode stereo float buffers (`-1.0..=1.0`) into a 16-bit PCM RIFF/WAV byte buffer.
pub fn encode_wav_pcm16(
  left : FixedArray[Double],
  right : FixedArray[Double],
  frame_count : Int32,
  sample_rate : Int32,
) -> Bytes {
  @synth.encode_wav_pcm16(left, right, frame_count, sample_rate)
}

///|
/// Render a complete MIDI file with a SoundFont2 bank directly into 16-bit stereo WAV bytes.
/// Adds `tail_seconds` (default `0.5`) so release tails and reverb decay cleanly.
pub fn render_midi_to_wav(
  sf2_bytes : Bytes,
  midi_bytes : Bytes,
  sample_rate~ : Int32 = 44100,
  tail_seconds~ : Double = 0.5,
  enable_effects~ : Bool = true,
) -> Bytes raise {
  let sf = @sf2.parse_sf2(sf2_bytes)
  let mf = @midi.parse_midi(midi_bytes)
  let syn = new_synthesizer(sf, sample_rate~, enable_effects~)
  let seq = @midi.MidiSequencer::new(syn, mf)
  let total_sec = mf.duration_seconds + tail_seconds
  let frames = (total_sec * sample_rate.to_double()).to_int().max(1)
  let left = FixedArray::make(frames, 0.0)
  let right = FixedArray::make(frames, 0.0)
  seq.render(left, right, frames)
  @synth.encode_wav_pcm16(left, right, frames, sample_rate)
}

///|
/// Inspect top-level RIFF chunks of a SoundFont or WAV file.
pub fn inspect_riff(data : Bytes) -> @riff.RiffChunk raise @riff.RiffError {
  @riff.parse_riff(data)
}
