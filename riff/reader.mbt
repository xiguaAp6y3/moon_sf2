///|
/// Errors raised when reading binary streams or parsing RIFF containers.
#derive(Debug, Eq)
pub(all) suberror RiffError {
  UnexpectedEof(offset~ : Int32, needed~ : Int32, available~ : Int32)
  InvalidMagic(expected~ : String, actual~ : String, offset~ : Int32)
  InvalidChunkSize(id~ : String, size~ : Int32, remaining~ : Int32)
}

///|
pub impl Show for RiffError with fn output(self, logger) {
  match self {
    UnexpectedEof(offset~, needed~, available~) =>
      logger.write_string(
        "UnexpectedEof at \{offset}: needed \{needed} bytes, available \{available}",
      )
    InvalidMagic(expected~, actual~, offset~) =>
      logger.write_string(
        "InvalidMagic at \{offset}: expected '\{expected}', got '\{actual}'",
      )
    InvalidChunkSize(id~, size~, remaining~) =>
      logger.write_string(
        "InvalidChunkSize for '\{id}': size \{size}, remaining \{remaining}",
      )
  }
}

///|
pub extend RiffError with Show::{output, to_string}

///|
pub extend RiffError with Eq::{equal, not_equal}

///|
pub extend RiffError with @debug.Debug::{to_repr}

///|
/// Bounds-checked binary cursor over an immutable `Bytes` buffer.
pub struct ByteReader {
  data : Bytes
  mut pos : Int32
}

///|
/// Create a `ByteReader` positioned at byte 0.
pub fn ByteReader::new(data : Bytes) -> ByteReader {
  { data, pos: 0, }
}

///|
/// Create a `ByteReader` positioned at `offset`, clamped within bounds.
pub fn ByteReader::at(data : Bytes, offset : Int32) -> ByteReader {
  let clamped = if offset < 0 {
    0
  } else if offset > data.length() {
    data.length()
  } else {
    offset
  }
  { data, pos: clamped, }
}

///|
/// Current byte offset of the reader cursor.
pub fn ByteReader::position(self : ByteReader) -> Int32 {
  self.pos
}

///|
/// Total length of the underlying byte buffer.
pub fn ByteReader::length(self : ByteReader) -> Int32 {
  self.data.length()
}

///|
/// Remaining unread byte count.
pub fn ByteReader::remaining(self : ByteReader) -> Int32 {
  self.data.length() - self.pos
}

///|
/// Seek to an absolute byte offset, raising `UnexpectedEof` if out of range.
pub fn ByteReader::seek(
  self : ByteReader,
  offset : Int32,
) -> Unit raise RiffError {
  if offset < 0 || offset > self.data.length() {
    raise UnexpectedEof(
      offset=self.pos,
      needed=offset,
      available=self.data.length(),
    )
  }
  self.pos = offset
}

///|
/// Advance the cursor by `count` bytes.
pub fn ByteReader::skip(
  self : ByteReader,
  count : Int32,
) -> Unit raise RiffError {
  if count < 0 || count > self.remaining() {
    raise UnexpectedEof(
      offset=self.pos,
      needed=count,
      available=self.remaining(),
    )
  }
  self.pos += count
}

///|
fn ByteReader::ensure(self : ByteReader, count : Int32) -> Unit raise RiffError {
  if count < 0 || count > self.remaining() {
    raise UnexpectedEof(
      offset=self.pos,
      needed=count,
      available=self.remaining(),
    )
  }
}

///|
/// Read an unsigned 8-bit integer.
pub fn ByteReader::read_u8(self : ByteReader) -> Int32 raise RiffError {
  self.ensure(1)
  let b = self.data[self.pos].to_int()
  self.pos += 1
  b
}

///|
/// Read a signed 8-bit integer (`-128..=127`).
pub fn ByteReader::read_i8(self : ByteReader) -> Int32 raise RiffError {
  let u = self.read_u8()
  if u >= 128 {
    u - 256
  } else {
    u
  }
}

///|
/// Read a little-endian unsigned 16-bit integer.
pub fn ByteReader::read_u16_le(self : ByteReader) -> Int32 raise RiffError {
  self.ensure(2)
  let b0 = self.data[self.pos].to_int()
  let b1 = self.data[self.pos + 1].to_int()
  self.pos += 2
  b0 | (b1 << 8)
}

///|
/// Read a little-endian signed 16-bit integer (`-32768..=32767`).
pub fn ByteReader::read_i16_le(self : ByteReader) -> Int32 raise RiffError {
  let u = self.read_u16_le()
  if u >= 32768 {
    u - 65536
  } else {
    u
  }
}

///|
/// Read a little-endian unsigned 32-bit integer as `UInt`.
pub fn ByteReader::read_u32_le(self : ByteReader) -> UInt32 raise RiffError {
  self.ensure(4)
  let b0 = self.data[self.pos].to_uint()
  let b1 = self.data[self.pos + 1].to_uint()
  let b2 = self.data[self.pos + 2].to_uint()
  let b3 = self.data[self.pos + 3].to_uint()
  self.pos += 4
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
/// Read a little-endian signed 32-bit integer.
pub fn ByteReader::read_i32_le(self : ByteReader) -> Int32 raise RiffError {
  self.read_u32_le().reinterpret_as_int()
}

///|
/// Read a big-endian unsigned 16-bit integer (used by SMF MIDI).
pub fn ByteReader::read_u16_be(self : ByteReader) -> Int32 raise RiffError {
  self.ensure(2)
  let b0 = self.data[self.pos].to_int()
  let b1 = self.data[self.pos + 1].to_int()
  self.pos += 2
  (b0 << 8) | b1
}

///|
/// Read a big-endian unsigned 32-bit integer (used by SMF MIDI).
pub fn ByteReader::read_u32_be(self : ByteReader) -> UInt32 raise RiffError {
  self.ensure(4)
  let b0 = self.data[self.pos].to_uint()
  let b1 = self.data[self.pos + 1].to_uint()
  let b2 = self.data[self.pos + 2].to_uint()
  let b3 = self.data[self.pos + 3].to_uint()
  self.pos += 4
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
/// Read a 4-byte ASCII FourCC identifier.
pub fn ByteReader::read_fourcc(self : ByteReader) -> String raise RiffError {
  self.ensure(4)
  let buf = StringBuilder()
  for i in 0..<4 {
    let byte_val = self.data[self.pos + i].to_int()
    buf.write_char(Int32::unsafe_to_char(byte_val))
  }
  self.pos += 4
  buf.to_string()
}

///|
/// Read a fixed-length NUL-terminated ASCII string field (e.g., 20-byte SF2 names).
pub fn ByteReader::read_ascii_z(
  self : ByteReader,
  field_len : Int32,
) -> String raise RiffError {
  self.ensure(field_len)
  let buf = StringBuilder()
  let mut stopped = false
  for i in 0..<field_len {
    let b = self.data[self.pos + i].to_int()
    if !stopped {
      if b == 0 {
        stopped = true
      } else {
        buf.write_char(Int32::unsafe_to_char(b))
      }
    }
  }
  self.pos += field_len
  buf.to_string()
}

///|
/// Read a variable-length ASCII string field and strip trailing NUL padding.
pub fn ByteReader::read_ascii_trimmed(
  self : ByteReader,
  field_len : Int32,
) -> String raise RiffError {
  self.read_ascii_z(field_len)
}

///|
/// Copy `count` bytes into a new `Bytes`.
pub fn ByteReader::read_bytes(
  self : ByteReader,
  count : Int32,
) -> Bytes raise RiffError {
  self.ensure(count)
  let buf = @buffer.Buffer(capacity=count)
  for i in 0..<count {
    buf.write_byte(self.data[self.pos + i])
  }
  self.pos += count
  buf.to_bytes()
}
