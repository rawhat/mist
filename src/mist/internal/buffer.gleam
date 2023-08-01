pub type Buffer {
  Buffer(remaining: Int, data: BitString)
}

pub fn empty() -> Buffer {
  Buffer(remaining: 0, data: <<>>)
}

pub fn new(data: BitString) -> Buffer {
  Buffer(remaining: 0, data: data)
}

pub fn append(buffer: Buffer, data: BitString) -> Buffer {
  Buffer(..buffer, data: <<buffer.data:bit_string, data:bit_string>>)
}

pub fn slice(buffer: Buffer, bits: Int) -> #(BitString, BitString) {
  let bytes = bits * 8
  case buffer.data {
    <<value:bit_string-size(bytes), rest:bit_string>> -> #(value, rest)
    _ -> #(buffer.data, <<>>)
  }
}

pub fn with_capacity(buffer: Buffer, size: Int) -> Buffer {
  Buffer(..buffer, remaining: size)
}

pub fn size(remaining: Int) -> Buffer {
  Buffer(data: <<>>, remaining: remaining)
}
