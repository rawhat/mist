import gleam/http.{type Header} as _http
import gleam/list
import gleam/option.{type Option, None}
import mist/internal/http2/frame.{type PushState, type Setting}

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
  list.fold(
    settings,
    _,
    fn(settings, setting) {
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
    },
  )
}

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
