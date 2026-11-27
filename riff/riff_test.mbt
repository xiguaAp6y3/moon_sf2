///|
fn build_test_chunk(id : String, payload : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_string_utf8(id)
  buf.write_uint_le(payload.length().reinterpret_as_uint())
  buf.write_bytesview(payload)
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
    inner.write_bytesview(c)
  }
  let inner_bytes = inner.to_bytes()
  let out = @buffer.Buffer()
  out.write_string_utf8(container_id)
  out.write_uint_le(inner_bytes.length().reinterpret_as_uint())
  out.write_bytesview(inner_bytes)
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

///|
test "ByteReader helpers, payload_bytes, and LIST error paths" {
  // Odd-sized LIST container alignment + payload_bytes
  let sub = build_test_chunk("txt ", b"abc")
  let info_list = build_test_container("LIST", "INFO", [sub])
  // Construct an odd-sized LIST (size = 13: "JUNK" + 9-byte unpadded child) followed by pad byte + "tail"
  let odd_list_buf = @buffer.Buffer()
  odd_list_buf.write_string_utf8("LIST")
  odd_list_buf.write_uint_le(13U)
  odd_list_buf.write_string_utf8("JUNK")
  odd_list_buf.write_string_utf8("sub ")
  odd_list_buf.write_uint_le(1U)
  odd_list_buf.write_byte(b'x')
  odd_list_buf.write_byte(b'\x00') // LIST odd-size alignment pad
  let tail_chunk = build_test_chunk("tail", b"ok")
  let root = build_test_container("RIFF", "TEST", [
    info_list,
    odd_list_buf.to_bytes(),
    tail_chunk,
  ])
  let parsed = @riff.parse_riff(root)
  let info = parsed.find_list("INFO").unwrap()
  let txt = info.find_child("txt ").unwrap()
  inspect(txt.payload_bytes(root) == b"abc", content="true")
  inspect(parsed.find_child("tail") is Some(_), content="true")

  // LIST with size < 4 raises InvalidChunkSize
  let bad_list = b"RIFF\x0c\x00\x00\x00TESTLIST\x02\x00\x00\x00ab"
  try @riff.parse_riff(bad_list) catch {
    err => inspect(err.to_string().contains("InvalidChunkSize"), content="true")
  } noraise {
    _ => fail("expected InvalidChunkSize for short LIST")
  }

  // ByteReader edge cases: at clamping, read_i8 negative, read_i32_le, read_ascii_trimmed, read_bytes, seek/skip EOF
  let raw = b"\xfe\xff\xff\xff\x80Hi\x00\x00"
  let r0 = @riff.ByteReader::at(raw, -5)
  inspect(r0.position(), content="0")
  inspect(r0.length(), content="9")
  inspect(r0.read_i32_le(), content="-2")
  inspect(r0.read_i8(), content="-128")
  inspect(r0.read_ascii_trimmed(4), content="Hi")
  let r_end = @riff.ByteReader::at(raw, 999)
  inspect(r_end.position(), content="9")

  try r_end.seek(-1) catch {
    err => inspect(err.to_string().contains("UnexpectedEof"), content="true")
  } noraise {
    _ => fail("expected UnexpectedEof on negative seek")
  }
  try r_end.skip(1) catch {
    err => inspect(err.to_string().contains("UnexpectedEof"), content="true")
  } noraise {
    _ => fail("expected UnexpectedEof on skip past end")
  }
  try r0.read_bytes(10) catch {
    err => inspect(err.to_string().contains("UnexpectedEof"), content="true")
  } noraise {
    _ => fail("expected UnexpectedEof on read_bytes")
  }
}
