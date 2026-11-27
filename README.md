# moon_sf2

Pure MoonBit **SoundFont2 (SF2)** wavetable bank parser and **General MIDI** polyphonic software synthesizer with zero C FFI dependencies. Designed for `wasm`, `wasm-gc`, `js`, and `native` targets.

## Project Goal

`moon_sf2` provides a self-contained, memory-safe, zero-FFI audio synthesis pipeline in pure MoonBit—covering RIFF/SF2 binary parsing and authoring, SoundFont2 voice/envelope/filter/modulator DSP, stereo Reverb & Chorus effects, Standard MIDI File (SMF) parsing and sample-accurate sequencing, and 16-bit PCM WAV export.

## Installation

Add the module to your MoonBit project via `mooncakes.io`:

```bash
moon add xiguaAp6y3/moon_sf2
```

Then import the packages you need in your `moon.pkg`:

```text
import {
  "xiguaAp6y3/moon_sf2",
  "xiguaAp6y3/moon_sf2/sf2",
  "xiguaAp6y3/moon_sf2/synth",
  "xiguaAp6y3/moon_sf2/midi",
}
```

## Package Architecture

| Package | Responsibility |
| --- | --- |
| `xiguaAp6y3/moon_sf2` | High-level facade (`parse_sf2`, `parse_midi`, `new_synthesizer`, `render_midi_to_wav`, `encode_wav_pcm16`, `inspect_riff`) |
| `xiguaAp6y3/moon_sf2/riff` | Bounds-checked `ByteReader` and recursive word-aligned `RIFF` / `LIST` container parser |
| `xiguaAp6y3/moon_sf2/sf2` | SoundFont 2.01 & 2.04 parser (`INFO`, `sdta` `smpl`/`sm24`, 9-table `pdta` Hydra), zone inheritance, and `Sf2Builder` |
| `xiguaAp6y3/moon_sf2/synth` | Polyphonic wavetable `Synthesizer`, DAHDSR envelopes, dual LFOs, Biquad low-pass filter, modulators, stereo Reverb/Chorus, WAV encoder |
| `xiguaAp6y3/moon_sf2/midi` | Standard MIDI File (Format 0/1/2) parser, sample-accurate `MidiSequencer`, and `MidiBuilder` |
| `xiguaAp6y3/moon_sf2/cmd/main` | Self-contained runnable demo generating an in-memory SF2 bank, C-major MIDI arpeggio, and stereo WAV |

## Features

- **Zero-FFI RIFF / SF2 2.01 & 2.04 Parser** (`xiguaAp6y3/moon_sf2/riff`, `xiguaAp6y3/moon_sf2/sf2`)
  - Bounds-checked `ByteReader` and recursive word-aligned `RIFF` / `LIST` container parser
  - Full `INFO`, `sdta` (`smpl` 16-bit + `sm24` 24-bit PCM extension), and 9-table `pdta` Hydra parser (`phdr`, `pbag`, `pmod`, `pgen`, `inst`, `ibag`, `imod`, `igen`, `shdr`)
  - Global-zone inheritance, key/velocity range intersection, and additive preset/instrument generator resolution per SoundFont 2.01 §9.4
  - Programmatic `Sf2Builder` for generating valid `RIFF sfbk` binaries in pure MoonBit
- **Polyphonic SoundFont2 & General MIDI Synthesizer** (`xiguaAp6y3/moon_sf2/synth`)
  - DAHDSR Volume & Modulation envelopes, dual delayed LFOs (Modulation & Vibrato), resonant 2nd-order Biquad low-pass filter
  - 16 MIDI channels (including Bank/Program selection, percussion Channel 9 bank 128, CC#1/7/10/11/64/91/93/120/121/123, 14-bit Pitch Bend, RPN Pitch Bend Sensitivity)
  - Continuous & until-release sample looping with linear and cubic Catmull-Rom interpolation, polyphony voice stealing, and exclusive class cutoff
  - Built-in Stereo Schroeder/Freeverb Reverb and modulated delay-line Chorus
- **Standard MIDI File (SMF) Parser & Sample-Accurate Sequencer** (`xiguaAp6y3/moon_sf2/midi`)
  - Format 0/1/2 track parsing with VLQ delta-times, Running Status, Tempo meta events, and `MidiBuilder`
  - Built-in 16-bit PCM RIFF/WAV encoder

## Usage & Runnable Example

### 1. Build an SF2 + MIDI In-Memory and Render WAV

The snippet below is an executable `mbt check` test verified by `moon test`:

```mbt check
///|
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

### 2. Real-Time Note Triggering & Streaming Render

```moonbit no-check
let sf = @moon_sf2.parse_sf2(sf2_bytes)
let syn = @moon_sf2.new_synthesizer(sf, sample_rate=44100)
syn.note_on(0, 60, 100)

let frames = 2048
let left = FixedArray::make(frames, 0.0)
let right = FixedArray::make(frames, 0.0)
syn.render(left, right, frames)
syn.note_off(0, 60)

let wav_bytes = @moon_sf2.encode_wav_pcm16(left, right, frames, 44100)
```

## Reproducible Build, Test & Run

Requires a MoonBit toolchain with `moonc >= 1.0.0-rc1` (check with `moon version --all`):

```bash
moon update
moon check --deny-warn --target all
moon build --deny-warn --target all
moon test --deny-warn --target all
moon run cmd/main
moon fmt --check
moon info
```

Running the built-in CLI demo (`moon run cmd/main`) prints:

```text
moon_sf2 demo rendered successfully!
SF2 bytes: 784
MIDI bytes: 72
WAV bytes: 273464 (container=RIFF)
```

## Reference & Attribution

The synthesizer architecture, SF2 generator/envelope/modulator semantics, and stereo effect design are inspired by:
- [sinshu/rustysynth](https://github.com/sinshu/rustysynth) (MIT License)
- [schellingb/TinySoundFont](https://github.com/schellingb/TinySoundFont) (MIT License)

See [NOTICE](NOTICE) for third-party attributions and [LICENSE](LICENSE) for the full Apache-2.0 License.
