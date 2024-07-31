import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang
import gleam/erlang/process
import gleam/http.{type Header} as _ghttp
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import glisten/socket.{type Socket, type SocketReason}
import glisten/transport.{type Transport}
import logging
import mist/internal/http.{type Connection}
import mist/internal/http2/frame.{
  type Frame, type PushState, type Setting, type StreamIdentifier, Complete,
  Data, Header,
}

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
    server_push: frame.Disabled,
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

fn send_headers(
  context: HpackContext,
  conn: Connection,
  headers: List(Header),
  end_stream: Bool,
  stream_identifier: StreamIdentifier(Frame),
) -> Result(HpackContext, process.ExitReason) {
  hpack_encode(context, headers)
  |> result.then(fn(pair) {
    let #(headers, new_context) = pair
    let header_frame =
      Header(
        data: Complete(headers),
        end_stream: end_stream,
        identifier: stream_identifier,
        priority: None,
      )
    let encoded = frame.encode(header_frame)
    case
      transport.send(
        conn.transport,
        conn.socket,
        bytes_builder.from_bit_array(encoded),
      )
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
  let encoded = frame.encode(data_frame)

  transport.send(
    conn.transport,
    conn.socket,
    bytes_builder.from_bit_array(encoded),
  )
  |> result.map_error(fn(err) {
    logging.log(logging.Debug, "failed to send :(  " <> erlang.format(err))
    process.Abnormal("Failed to send HTTP/2 data")
  })
}

// TODO:  handle max frame size
pub fn send_frame(
  frame_to_send: Frame,
  socket: Socket,
  transport: Transport,
) -> Result(Nil, SocketReason) {
  let data = frame.encode(frame_to_send)

  transport.send(transport, socket, bytes_builder.from_bit_array(data))
}

pub fn send_bytes_builder(
  resp: Response(BytesBuilder),
  conn: Connection,
  context: HpackContext,
  id: StreamIdentifier(Frame),
) -> Result(HpackContext, process.ExitReason) {
  let resp =
    resp
    |> http.add_default_headers(False)

  let headers = [#(":status", int.to_string(resp.status)), ..resp.headers]

  case bytes_builder.byte_size(resp.body) {
    0 -> send_headers(context, conn, headers, True, id)
    _ -> {
      send_headers(context, conn, headers, False, id)
      |> result.then(fn(context) {
        // TODO:  this should be broken up by window size
        // TODO:  fix end_stream
        send_data(conn, bytes_builder.to_bit_array(resp.body), id, True)
        |> result.replace(context)
      })
    }
  }
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
