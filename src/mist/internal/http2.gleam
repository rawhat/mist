import gleam/http.{type Header} as _http

pub type HpackContext

@external(erlang, "mist_ffi", "hpack_new_context")
pub fn hpack_new_context(size: Int) -> HpackContext

@external(erlang, "mist_ffi", "hpack_new_max_table_size")
pub fn hpack_max_table_size(context: HpackContext, size: Int) -> HpackContext

pub type HpackError {
  Compression
  BadHeaderPacket(BitArray)
}

@external(erlang, "mist_ffi", "hpack_decode")
pub fn hpack_decode(
  context: HpackContext,
  bin: BitArray,
) -> Result(#(List(Header), HpackContext), HpackError)

@external(erlang, "mist_ffi", "hpack_encode")
pub fn hpack_encode(
  context: HpackContext,
  headers: List(Header),
) -> Result(#(BitArray, HpackContext), error)
