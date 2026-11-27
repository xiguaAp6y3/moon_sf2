///|
fn build_test_chunk(id : String, payload : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_string_utf8(id)
  buf.write_uint_le(payload.length().reinterpret_as_uint())
  buf.write_bytes(payload)
  if payload.length() % 2 == 1 {
    buf.write_byte(b'\x00')
  }
  buf.to_bytes()
}

///|
fn build_test_container(
  container_id : String,
  form_type : String,
  children : Array[Bytes],
) -> Bytes {
  let inner = @buffer.Buffer()
  inner.write_string_utf8(form_type)
  for c in children {
    inner.write_bytes(c)
  }
  let inner_bytes = inner.to_bytes()
  let out = @buffer.Buffer()
  out.write_string_utf8(container_id)
  out.write_uint_le(inner_bytes.length().reinterpret_as_uint())
  out.write_bytes(inner_bytes)
  out.to_bytes()
}

///|
test "parse nested RIFF with odd-sized subchunk padding" {
  let odd_chunk = build_test_chunk("INAM", b"Piano")
  let even_chunk = build_test_chunk("isng", b"EMU8000\x00")
  let list_chunk = build_test_container("LIST", "INFO", [odd_chunk, even_chunk])
  let riff = build_test_container("RIFF", "sfbk", [list_chunk])
  let root = @riff.parse_riff(riff)
  inspect(root.id, content="RIFF")
  debug_inspect(root.form_type, content="Some(\"sfbk\")")
  let info = root.find_list("INFO").unwrap()
  let inam = info.find_child("INAM").unwrap()
  let reader = @riff.ByteReader::at(riff, inam.data_offset)
  inspect(reader.read_ascii_z(inam.data_size), content="Piano")
  let isng = info.find_child("isng").unwrap()
  let reader2 = @riff.ByteReader::at(riff, isng.data_offset)
  inspect(reader2.read_ascii_z(isng.data_size), content="EMU8000")
}

///|
test "reject invalid RIFF header and truncated chunk" {
  try @riff.parse_riff(b"WAVE\x04\x00\x00\x00test") catch {
    err =>
      inspect(err, content="InvalidMagic at 0: expected 'RIFF', got 'WAVE'")
  } noraise {
    _ => fail("expected InvalidMagic")
  }
  try @riff.parse_riff(b"RIFF\x20\x00\x00\x00sfbk") catch {
    err =>
      inspect(err, content="InvalidChunkSize for 'RIFF': size 32, remaining 4")
  } noraise {
    _ => fail("expected InvalidChunkSize")
  }
}
