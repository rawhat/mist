import gleam/bit_array
import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}

pub type Context

type Flush {
  Sync
}

type Deflated {
  Deflated
}

type Default {
  Default
}

pub type Compression {
  Compression(inflate: Context, deflate: Context)
}

pub fn init() -> Compression {
  let inflate_context = open()
  inflate_init(inflate_context, -15)
  let deflate_context = open()
  deflate_init(deflate_context, Default, Deflated, -15, 8, Default)

  Compression(inflate: inflate_context, deflate: deflate_context)
}

@external(erlang, "zlib", "inflateInit")
fn inflate_init(context: Context, bits: Int) -> Atom

@external(erlang, "zlib", "deflateInit")
fn deflate_init(
  context: Context,
  level: Default,
  deflated: Deflated,
  bits: Int,
  mem_level: Int,
  strategy: Default,
) -> Atom

@external(erlang, "zlib", "open")
fn open() -> Context

@external(erlang, "zlib", "inflate")
fn do_inflate(context: Context, data: BitArray) -> BytesBuilder

pub fn inflate(context: Context, data: BitArray) -> BitArray {
  context
  |> do_inflate(<<data:bits, 0x00, 0x00, 0xFF, 0xFF>>)
  |> bytes_builder.to_bit_array
}

@external(erlang, "zlib", "deflate")
fn do_deflate(context: Context, data: BitArray, flush: Flush) -> BytesBuilder

pub fn deflate(context: Context, data: BitArray) -> BitArray {
  let data =
    context
    |> do_deflate(data, Sync)
    |> bytes_builder.to_bit_array

  let size = bit_array.byte_size(data) - 4

  case data {
    <<value:bytes-size(size), 0x00, 0x00, 0xFF, 0xFF>> -> value
    _ -> data
  }
}

@external(erlang, "zlib", "set_controlling_process")
pub fn set_controlling_process(context: Context, pid: Pid) -> Atom
