import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang/process
import gleam/http.{type Header} as _http
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mist/internal/http2/frame.{
  type Frame, type PushState, type Setting, type StreamIdentifier, Complete,
  Data, Header,
}
import mist/internal/http.{type Connection}

pub type Http2Settings {
  Http2Settings(
    header_table_size: Int,
    server_push: PushState,
    max_concurrent_streams: Int,
    initial_window_size: Int,
    max_frame_size: Int,
    max_header_list_size: Option(Int),
  )
}

pub fn default_settings() -> Http2Settings {
  Http2Settings(
    header_table_size: 4096,
    server_push: frame.Enabled,
    max_concurrent_streams: 100,
    initial_window_size: 65_535,
    max_frame_size: 16_384,
    max_header_list_size: None,
  )
}

pub fn update_settings(
  current: Http2Settings,
  settings: List(Setting),
) -> Http2Settings {
  list.fold(settings, current, fn(settings, setting) {
    case setting {
      frame.HeaderTableSize(size) ->
        Http2Settings(..settings, header_table_size: size)
      frame.ServerPush(push) -> Http2Settings(..settings, server_push: push)
      frame.MaxConcurrentStreams(max) ->
        Http2Settings(..settings, max_concurrent_streams: max)
      frame.InitialWindowSize(size) ->
        Http2Settings(..settings, initial_window_size: size)
      frame.MaxFrameSize(size) ->
        Http2Settings(..settings, max_frame_size: size)
      frame.MaxHeaderListSize(size) ->
        Http2Settings(..settings, max_header_list_size: Some(size))
    }
  })
}

import gleam/erlang
import gleam/io

fn send_headers(
  context: HpackContext,
  conn: Connection,
  headers: List(Header),
  end_stream: Bool,
  stream_identifier: StreamIdentifier(Frame),
) -> Result(HpackContext, process.ExitReason) {
  io.println("going to encode:  " <> erlang.format(headers))
  hpack_encode(context, headers)
  |> result.then(fn(pair) {
    io.println("hi we encoded:  " <> erlang.format(pair))
    let assert #(headers, new_context) = pair
    let header_frame =
      Header(
        data: Complete(headers),
        end_stream: end_stream,
        identifier: stream_identifier,
        priority: None,
      )
    let encoded = frame.encode(header_frame)
    case
      conn.transport.send(conn.socket, bytes_builder.from_bit_array(encoded))
    {
      Ok(_nil) -> Ok(new_context)
      Error(_reason) -> Error(process.Abnormal("Failed to send HTTP/2 headers"))
    }
  })
}

fn send_data(
  conn: Connection,
  data: BitArray,
  stream_identifier: StreamIdentifier(Frame),
  end_stream: Bool,
) -> Result(Nil, process.ExitReason) {
  let data_frame =
    Data(data: data, end_stream: end_stream, identifier: stream_identifier)
  io.println("gonna send data frame:  " <> erlang.format(data_frame))
  let encoded = frame.encode(data_frame)

  conn.transport.send(conn.socket, bytes_builder.from_bit_array(encoded))
  |> result.map_error(fn(err) {
    io.println("failed to send :(  " <> erlang.format(err))
  })
  |> result.replace_error(process.Abnormal("Failed to send HTTP/2 data"))
}

pub fn send_bytes_builder(
  resp: Response(BytesBuilder),
  conn: Connection,
  context: HpackContext,
  id: StreamIdentifier(Frame),
) -> Result(HpackContext, process.ExitReason) {
  let resp = http.add_default_headers(resp, False)
  // TODO:  fix end_stream
  send_headers(context, conn, resp.headers, False, id)
  |> result.then(fn(context) {
    // TODO:  fix end_stream
    send_data(conn, bytes_builder.to_bit_array(resp.body), id, True)
    |> result.replace(context)
  })
}

pub type HpackContext

@external(erlang, "hpack", "new_context")
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
