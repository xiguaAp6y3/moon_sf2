///|
/// Parsed node in a RIFF chunk hierarchy.
#derive(Debug, Eq)
pub(all) struct RiffChunk {
  id : String
  form_type : String?
  data_offset : Int32
  data_size : Int32
  children : Array[RiffChunk]
}

///|
pub extend RiffChunk with Eq::{equal, not_equal}

///|
pub extend RiffChunk with @debug.Debug::{to_repr}

///|
/// Parse a complete RIFF container starting at offset 0.
pub fn parse_riff(data : Bytes) -> RiffChunk raise RiffError {
  let reader = ByteReader::new(data)
  let chunk = parse_chunk(reader)
  if chunk.id != "RIFF" {
    raise InvalidMagic(expected="RIFF", actual=chunk.id, offset=0)
  }
  chunk
}

///|
fn parse_chunk(reader : ByteReader) -> RiffChunk raise RiffError {
  let id = reader.read_fourcc()
  let raw_size = reader.read_u32_le()
  let size_int = raw_size.reinterpret_as_int()
  if size_int < 0 || size_int > reader.remaining() {
    raise InvalidChunkSize(id~, size=size_int, remaining=reader.remaining())
  }
  let payload_start = reader.position()
  if id == "RIFF" || id == "LIST" {
    if size_int < 4 {
      raise InvalidChunkSize(id~, size=size_int, remaining=reader.remaining())
    }
    let form_type = reader.read_fourcc()
    let children : Array[RiffChunk] = []
    let end_pos = payload_start + size_int
    while reader.position() < end_pos {
      let child = parse_chunk(reader)
      children.push(child)
    }
    reader.seek(end_pos)
    // RIFF chunks are word-aligned (padded by 1 byte when size is odd).
    if size_int % 2 == 1 && reader.remaining() > 0 {
      reader.skip(1)
    }
    {
      id,
      form_type: Some(form_type),
      data_offset: payload_start + 4,
      data_size: size_int - 4,
      children,
    }
  } else {
    reader.skip(size_int)
    if size_int % 2 == 1 && reader.remaining() > 0 {
      reader.skip(1)
    }
    {
      id,
      form_type: None,
      data_offset: payload_start,
      data_size: size_int,
      children: [],
    }
  }
}

///|
/// Find the first child chunk with the given FourCC `id`.
pub fn RiffChunk::find_child(self : RiffChunk, id : String) -> RiffChunk? {
  for child in self.children {
    if child.id == id {
      return Some(child)
    }
  }
  None
}

///|
/// Find the first `LIST` child chunk matching `form_type`.
pub fn RiffChunk::find_list(self : RiffChunk, form_type : String) -> RiffChunk? {
  for child in self.children {
    if child.id == "LIST" && child.form_type == Some(form_type) {
      return Some(child)
    }
  }
  None
}

///|
/// Extract this chunk's payload bytes from the backing buffer.
pub fn RiffChunk::payload_bytes(
  self : RiffChunk,
  backing : Bytes,
) -> Bytes raise RiffError {
  let reader = ByteReader::at(backing, self.data_offset)
  reader.read_bytes(self.data_size)
}
