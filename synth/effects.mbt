///|
pub struct CombFilter {
  buffer : FixedArray[Double]
  mut buffer_index : Int32
  mut filter_store : Double
  feedback : Double
  damp1 : Double
  damp2 : Double
}

///|
fn CombFilter::new(
  size : Int32,
  feedback : Double,
  damp : Double,
) -> CombFilter {
  let len = if size < 1 { 1 } else { size }
  {
    buffer: FixedArray::make(len, 0.0),
    buffer_index: 0,
    filter_store: 0.0,
    feedback,
    damp1: damp,
    damp2: 1.0 - damp,
  }
}

///|
fn CombFilter::process(
  self : CombFilter,
  input : FixedArray[Double],
  output : FixedArray[Double],
  count : Int32,
) -> Unit {
  let len = self.buffer.length()
  for t in 0..<count {
    let out = self.buffer[self.buffer_index]
    self.filter_store = out * self.damp2 + self.filter_store * self.damp1
    self.buffer[self.buffer_index] = input[t] +
      self.filter_store * self.feedback
    self.buffer_index += 1
    if self.buffer_index >= len {
      self.buffer_index = 0
    }
    output[t] = output[t] + out
  }
}

///|
fn CombFilter::mute(self : CombFilter) -> Unit {
  for i in 0..<self.buffer.length() {
    self.buffer[i] = 0.0
  }
  self.filter_store = 0.0
}

///|
pub struct AllPassFilter {
  buffer : FixedArray[Double]
  mut buffer_index : Int32
  feedback : Double
}

///|
fn AllPassFilter::new(size : Int32) -> AllPassFilter {
  let len = if size < 1 { 1 } else { size }
  { buffer: FixedArray::make(len, 0.0), buffer_index: 0, feedback: 0.5, }
}

///|
fn AllPassFilter::process(
  self : AllPassFilter,
  block : FixedArray[Double],
  count : Int32,
) -> Unit {
  let len = self.buffer.length()
  for t in 0..<count {
    let bufout = self.buffer[self.buffer_index]
    let input = block[t]
    block[t] = bufout - input
    self.buffer[self.buffer_index] = input + bufout * self.feedback
    self.buffer_index += 1
    if self.buffer_index >= len {
      self.buffer_index = 0
    }
  }
}

///|
fn AllPassFilter::mute(self : AllPassFilter) -> Unit {
  for i in 0..<self.buffer.length() {
    self.buffer[i] = 0.0
  }
}

///|
/// Stereo Schroeder / Freeverb reverb processor scaled cleanly to `sample_rate`.
pub struct Reverb {
  combs_l : Array[CombFilter]
  combs_r : Array[CombFilter]
  allpasses_l : Array[AllPassFilter]
  allpasses_r : Array[AllPassFilter]
  input_buf : FixedArray[Double]
  wet1 : Double
  wet2 : Double
}

///|
fn scale_tuning(base_samples : Int32, sample_rate : Int32) -> Int32 {
  let scaled = (base_samples.to_double() * sample_rate.to_double() / 44100.0).to_int()
  if scaled < 1 {
    1
  } else {
    scaled
  }
}

///|
pub fn Reverb::new(sample_rate : Int32, block_size : Int32) -> Reverb {
  let comb_tunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
  let allpass_tunings = [556, 441, 341, 225]
  let stereo_spread = 23
  let room_size = 0.5 * 0.28 + 0.7
  let damp = 0.5 * 0.4
  let combs_l : Array[CombFilter] = []
  let combs_r : Array[CombFilter] = []
  for c in comb_tunings {
    combs_l.push(CombFilter::new(scale_tuning(c, sample_rate), room_size, damp))
    combs_r.push(
      CombFilter::new(
        scale_tuning(c + stereo_spread, sample_rate),
        room_size,
        damp,
      ),
    )
  }
  let allpasses_l : Array[AllPassFilter] = []
  let allpasses_r : Array[AllPassFilter] = []
  for a in allpass_tunings {
    allpasses_l.push(AllPassFilter::new(scale_tuning(a, sample_rate)))
    allpasses_r.push(
      AllPassFilter::new(scale_tuning(a + stereo_spread, sample_rate)),
    )
  }
  let wet = 0.5 * 3.0
  let width = 1.0
  let wet1 = wet * (width * 0.5 + 0.5)
  let wet2 = wet * ((1.0 - width) * 0.5)
  {
    combs_l,
    combs_r,
    allpasses_l,
    allpasses_r,
    input_buf: FixedArray::make(block_size, 0.0),
    wet1,
    wet2,
  }
}

///|
pub fn Reverb::mute(self : Reverb) -> Unit {
  for c in self.combs_l {
    c.mute()
  }
  for c in self.combs_r {
    c.mute()
  }
  for a in self.allpasses_l {
    a.mute()
  }
  for a in self.allpasses_r {
    a.mute()
  }
}

///|
pub fn Reverb::process(
  self : Reverb,
  in_l : FixedArray[Double],
  in_r : FixedArray[Double],
  out_l : FixedArray[Double],
  out_r : FixedArray[Double],
  count : Int32,
) -> Unit {
  let fixed_gain = 0.015
  for t in 0..<count {
    self.input_buf[t] = (in_l[t] + in_r[t]) * fixed_gain
    out_l[t] = 0.0
    out_r[t] = 0.0
  }
  for c in self.combs_l {
    c.process(self.input_buf, out_l, count)
  }
  for c in self.combs_r {
    c.process(self.input_buf, out_r, count)
  }
  for a in self.allpasses_l {
    a.process(out_l, count)
  }
  for a in self.allpasses_r {
    a.process(out_r, count)
  }
  for t in 0..<count {
    let l = out_l[t]
    let r = out_r[t]
    out_l[t] = l * self.wet1 + r * self.wet2
    out_r[t] = r * self.wet1 + l * self.wet2
  }
}

///|
/// Stereo modulated delay-line Chorus effect.
pub struct Chorus {
  buf_l : FixedArray[Double]
  buf_r : FixedArray[Double]
  mut buf_index : Int32
  delay_table : FixedArray[Double]
  mut delay_index_l : Int32
  mut delay_index_r : Int32
}

///|
pub fn Chorus::new(
  sample_rate : Int32,
  delay_sec~ : Double = 0.002,
  depth_sec~ : Double = 0.0019,
  frequency_hz~ : Double = 0.4,
) -> Chorus {
  let buf_len = (sample_rate.to_double() * (delay_sec + depth_sec)).to_int() + 2
  let table_len = (sample_rate.to_double() / frequency_hz).to_int().max(16)
  let delay_table = FixedArray::make(table_len, 0.0)
  for i in 0..<table_len {
    let phase = 2.0 * @math.PI * i.to_double() / table_len.to_double()
    delay_table[i] = sample_rate.to_double() *
      (delay_sec + depth_sec * 0.5 * (1.0 - @math.cos(phase)))
  }
  {
    buf_l: FixedArray::make(buf_len, 0.0),
    buf_r: FixedArray::make(buf_len, 0.0),
    buf_index: 0,
    delay_table,
    delay_index_l: 0,
    delay_index_r: table_len / 4,
  }
}

///|
pub fn Chorus::mute(self : Chorus) -> Unit {
  for i in 0..<self.buf_l.length() {
    self.buf_l[i] = 0.0
    self.buf_r[i] = 0.0
  }
}

///|
fn read_modulated(
  buf : FixedArray[Double],
  write_idx : Int32,
  delay_samples : Double,
) -> Double {
  let len = buf.length()
  let mut pos = write_idx.to_double() - delay_samples
  while pos < 0.0 {
    pos = pos + len.to_double()
  }
  let idx1 = pos.to_int() % len
  let idx2 = (idx1 + 1) % len
  let frac = pos - @math.floor(pos)
  buf[idx1] + frac * (buf[idx2] - buf[idx1])
}

///|
pub fn Chorus::process(
  self : Chorus,
  in_l : FixedArray[Double],
  in_r : FixedArray[Double],
  out_l : FixedArray[Double],
  out_r : FixedArray[Double],
  count : Int32,
) -> Unit {
  let len = self.buf_l.length()
  let tlen = self.delay_table.length()
  for t in 0..<count {
    let dl = self.delay_table[self.delay_index_l]
    let dr = self.delay_table[self.delay_index_r]
    out_l[t] = read_modulated(self.buf_l, self.buf_index, dl)
    out_r[t] = read_modulated(self.buf_r, self.buf_index, dr)
    self.buf_l[self.buf_index] = in_l[t]
    self.buf_r[self.buf_index] = in_r[t]
    self.buf_index += 1
    if self.buf_index >= len {
      self.buf_index = 0
    }
    self.delay_index_l = (self.delay_index_l + 1) % tlen
    self.delay_index_r = (self.delay_index_r + 1) % tlen
  }
}
