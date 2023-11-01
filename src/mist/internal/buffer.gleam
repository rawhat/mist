pub type Buffer {
  Buffer(remaining: Int, data: BitArray)
}

pub fn empty() -> Buffer {
  Buffer(remaining: 0, data: <<>>)
}

pub fn new(data: BitArray) -> Buffer {
  Buffer(remaining: 0, data: data)
}

pub fn append(buffer: Buffer, data: BitArray) -> Buffer {
  Buffer(..buffer, data: <<buffer.data:bits, data:bits>>)
}

pub fn slice(buffer: Buffer, bits: Int) -> #(BitArray, BitArray) {
  let bytes = bits * 8
  case buffer.data {
    <<value:bits-size(bytes), rest:bits>> -> #(value, rest)
    _ -> #(buffer.data, <<>>)
  }
}

pub fn with_capacity(buffer: Buffer, size: Int) -> Buffer {
  Buffer(..buffer, remaining: size)
}

pub fn size(remaining: Int) -> Buffer {
  Buffer(data: <<>>, remaining: remaining)
}
