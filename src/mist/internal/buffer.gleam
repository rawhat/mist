import gleam/bit_array
import gleam/int

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
  let data_size = bit_array.byte_size(data)
  let remaining = int.max(buffer.remaining - data_size, 0)
  Buffer(data: <<buffer.data:bits, data:bits>>, remaining: remaining)
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
