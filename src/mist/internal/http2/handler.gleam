import gleam/bytes_builder
import gleam/result
import gleam/list
import gleam/option.{Some}
import mist/internal/buffer.{type Buffer}
import mist/internal/http.{type Connection, type Handler, Connection, Initial}
import mist/internal/http2/frame.{Complete, Settings}
import gleam/io
import mist/internal/http2.{type HpackContext, type Http2Settings, Http2Settings}
import mist/internal/http2/stream
import gleam/erlang/process

pub type State {
  State(
    frame_buffer: Buffer,
    hpack_context: HpackContext,
    settings: Http2Settings,
  )
}

pub fn upgrade(data: BitArray, conn: Connection) -> Result(State, String) {
  let initial_settings = http2.default_settings()
  let settings_frame =
    frame.Settings(ack: False, settings: [
      frame.HeaderTableSize(initial_settings.header_table_size),
      frame.ServerPush(initial_settings.server_push),
      frame.MaxConcurrentStreams(initial_settings.max_concurrent_streams),
      frame.InitialWindowSize(initial_settings.initial_window_size),
      frame.MaxFrameSize(initial_settings.max_frame_size),
    ])
  let assert Ok(_nil) =
    settings_frame
    |> frame.encode
    |> bytes_builder.from_bit_array
    |> conn.transport.send(conn.socket, _)

  frame.decode(data)
  |> result.map_error(fn(_err) { "Missing first frame" })
  |> result.then(fn(pair) {
    let assert #(frame, rest) = pair
    case frame {
      Settings(settings: settings, ..) -> {
        let http2_settings =
          initial_settings
          |> list.fold(
            settings,
            _,
            fn(settings, setting) {
              case setting {
                frame.HeaderTableSize(size) ->
                  Http2Settings(..settings, header_table_size: size)
                frame.ServerPush(push) ->
                  Http2Settings(..settings, server_push: push)
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
        Ok(State(
          frame_buffer: buffer.new(rest),
          settings: http2_settings,
          hpack_context: http2.hpack_new_context(
            http2_settings.header_table_size,
          ),
        ))
      }
      _ -> {
        let assert Ok(_) = conn.transport.close(conn.socket)
        Error("SETTINGS frame must be sent first")
      }
    }
  })
}

pub fn call(
  state: State,
  msg: BitArray,
  conn: Connection,
  handler: Handler,
) -> State {
  let new_buffer = buffer.append(state.frame_buffer, msg)
  case frame.decode(new_buffer.data) {
    Ok(#(frame.WindowUpdate(amount, identifier), rest)) -> {
      case frame.get_stream_identifier(identifier) {
        0 -> {
          io.println("setting window size!")
          State(
            frame_buffer: buffer.new(rest),
            settings: Http2Settings(
              ..state.settings,
              initial_window_size: amount,
            ),
            hpack_context: state.hpack_context,
          )
        }
        _n -> {
          todo
        }
      }
    }
    Ok(#(frame.Header(Complete(data), end_stream, identifier, _priority), rest)) -> {
      // TODO:  will this be the end headers?  i guess we should wait to
      // receive all of them before starting the stream.  is that how it
      // works?
      let conn =
        Connection(
          body: Initial(<<>>),
          socket: conn.socket,
          transport: conn.transport,
          client_ip: conn.client_ip,
        )
      let assert Ok(new_stream) =
        stream.new(
          identifier,
          state.settings.initial_window_size,
          handler,
          conn,
          fn(_resp) { Nil },
        )
      let assert Ok(#(headers, context)) =
        http2.hpack_decode(state.hpack_context, data)
      process.send(new_stream, stream.Headers(headers, end_stream))
      State(..state, frame_buffer: buffer.new(rest), hpack_context: context)
    }
    Ok(data) -> {
      io.debug(#("we got a frame!!111oneone", data))
      todo
    }
    Error(frame.NoError) -> {
      state
    }
    Error(_connection_error) -> {
      // TODO:
      //  - send GOAWAY with last good stream ID
      //  - close the connection
      todo
    }
  }
}
