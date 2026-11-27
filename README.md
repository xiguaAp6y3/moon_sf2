# moon_sf2

Pure MoonBit **SoundFont2 (SF2)** wavetable bank parser and **General MIDI** polyphonic software synthesizer with zero C FFI dependencies. Designed for Native, Wasm, Wasm-GC, and JS targets.

## Features

- **Zero-FFI RIFF / SF2 2.01 & 2.04 Parser** (`xiguaAp6y3/moon_sf2/riff`, `xiguaAp6y3/moon_sf2/sf2`)
  - Bounds-checked `ByteReader` and recursive word-aligned `RIFF` / `LIST` container parser
  - Full `INFO`, `sdta` (`smpl` 16-bit + `sm24` 24-bit PCM extension), and 9-table `pdta` Hydra parser (`phdr`, `pbag`, `pmod`, `pgen`, `inst`, `ibag`, `imod`, `igen`, `shdr`)
  - Global-zone inheritance, key/velocity range intersection, and additive preset/instrument generator resolution per SoundFont 2.01 §9.4
  - Programmatic `Sf2Builder` for generating valid `RIFF sfbk` binaries in pure MoonBit
- **Polyphonic SoundFont2 & General MIDI Synthesizer** (`xiguaAp6y3/moon_sf2/synth`)
  - DAHDSR Volume & Modulation envelopes, dual delayed LFOs (Modulation & Vibrato), resonant 2nd-order Biquad low-pass filter
  - 16 MIDI channels (including Bank/Program selection, percussion Channel 9 bank 128, CC#1/7/10/11/64/91/93/120/121/123, 14-bit Pitch Bend, RPN Pitch Bend Sensitivity)
  - Continuous & until-release sample looping with linear interpolation, polyphony voice stealing, and exclusive class cutoff
  - Built-in Stereo Schroeder/Freeverb Reverb and modulated delay-line Chorus
- **Standard MIDI File (SMF) Parser & Sample-Accurate Sequencer** (`xiguaAp6y3/moon_sf2/midi`)
  - Format 0/1/2 track parsing with VLQ delta-times, Running Status, Tempo meta events, and `MidiBuilder`
  - Built-in 16-bit PCM RIFF/WAV encoder

## Quick Example

```mbt check
test "build minimal sf2 and synthesize" {
  let sb = @sf2.Sf2Builder::new(bank_name="QuickStart")
  let pcm = [0, 16000, 28000, 16000, 0, -16000, -28000, -16000]
  let smp = sb.add_sample("Wave", pcm, 44100, 69, loop_start=0, loop_end=8)
  let inst = sb.add_instrument("Inst", [
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
  sb.add_preset("Preset", 0, 0, [
    {
      generators: [
        @sf2.gen_range(@sf2.GEN_KEY_RANGE, 0, 127),
        @sf2.gen_val(@sf2.GEN_INSTRUMENT, inst),
      ],
      modulators: [],
    },
  ])
  let mb = @midi.MidiBuilder::new(resolution=480)
  mb.add_note(0, 120, 0, 69, 100)
  let wav = @moon_sf2.render_midi_to_wav(
    sb.build(),
    mb.build(),
    sample_rate=22050,
    tail_seconds=0.05,
  )
  inspect(wav.length() > 44, content="true")
}
```

## Build, Test & Run

```bash
moon check --deny-warn --target all
moon test --deny-warn
moon run cmd/main
```

## Reference & Attribution

The synthesizer architecture, SF2 generator/envelope semantics, and stereo effect design are inspired by:
- [sinshu/rustysynth](https://github.com/sinshu/rustysynth) (MIT License)
- [schellingb/TinySoundFont](https://github.com/schellingb/TinySoundFont) (MIT License)

Licensed under the [Apache-2.0 License](LICENSE).
