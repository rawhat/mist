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

/// Splits data at the byte count, returning all data when it is shorter.
pub fn slice(data: BitArray, byte_size: Int) -> #(BitArray, BitArray) {
  case data {
    <<value:bytes-size(byte_size), rest:bits>> -> #(value, rest)
    _ -> #(data, <<>>)
  }
}

pub fn with_capacity(buffer: Buffer, size: Int) -> Buffer {
  Buffer(..buffer, remaining: size)
}

pub fn size(remaining: Int) -> Buffer {
  Buffer(data: <<>>, remaining: remaining)
}
