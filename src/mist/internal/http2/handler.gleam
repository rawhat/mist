import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mist/internal/buffer.{type Buffer}
import mist/internal/http.{type Connection, type Handler, Connection, Initial}
import mist/internal/http2.{type HpackContext, type Http2Settings, Http2Settings}
import mist/internal/http2/flow_control
import mist/internal/http2/frame.{
  type Frame, type StreamIdentifier, Complete, Continued,
}
import mist/internal/http2/stream.{type SendMessage, Ready}

pub type PendingSend {
  PendingSend
}

pub type State {
  State(
    fragment: Option(Frame),
    frame_buffer: Buffer,
    pending_sends: List(PendingSend),
    receive_hpack_context: HpackContext,
    self: Subject(SendMessage),
    send_hpack_context: HpackContext,
    send_window_size: Int,
    receive_window_size: Int,
    settings: Http2Settings,
    streams: Dict(StreamIdentifier(Frame), stream.State),
  )
}

pub fn send_hpack_context(state: State, context: HpackContext) -> State {
  State(..state, send_hpack_context: context)
}

pub fn receive_hpack_context(state: State, context: HpackContext) -> State {
  State(..state, receive_hpack_context: context)
}

fn get_last_stream_id(state: State) -> Int {
  dict.fold(state.streams, 0, fn(max_id, id, _stream) {
    let stream_id = frame.get_stream_identifier(id)
    case stream_id > max_id {
      True -> stream_id
      False -> max_id
    }
  })
}

pub fn append_data(state: State, data: BitArray) -> State {
  State(..state, frame_buffer: buffer.append(state.frame_buffer, data))
}

pub fn upgrade(
  data: BitArray,
  conn: Connection,
  self: Subject(SendMessage),
) -> Result(State, String) {
  upgrade_with_settings(data, conn, self, None)
}

pub fn upgrade_with_settings(
  data: BitArray,
  conn: Connection,
  self: Subject(SendMessage),
  custom_settings: Option(http2.Http2Settings),
) -> Result(State, String) {
  let initial_settings =
    option.unwrap(custom_settings, http2.default_settings())
  let settings_frame =
    frame.Settings(
      ack: False,
      settings: [
        frame.MaxConcurrentStreams(initial_settings.max_concurrent_streams),
        frame.InitialWindowSize(initial_settings.initial_window_size),
        frame.MaxFrameSize(initial_settings.max_frame_size),
      ]
        |> fn(settings) {
          initial_settings.max_header_list_size
          |> option.map(frame.MaxHeaderListSize)
          |> option.map(fn(header_setting) { [header_setting, ..settings] })
          |> option.unwrap(settings)
        },
    )

  let sent =
    http2.send_frame(settings_frame, conn.socket, conn.transport)
    |> result.replace_error("Failed to send settings frame")

  use _nil <- result.map(sent)
  State(
    fragment: None,
    frame_buffer: buffer.new(data),
    pending_sends: [],
    receive_hpack_context: http2.hpack_new_context(
      initial_settings.header_table_size,
    ),
    receive_window_size: initial_settings.initial_window_size,
    self: self,
    send_hpack_context: http2.hpack_new_context(
      initial_settings.header_table_size,
    ),
    send_window_size: initial_settings.initial_window_size,
    settings: initial_settings,
    streams: dict.new(),
  )
}

pub fn call(
  state: State,
  conn: Connection,
  handler: Handler,
) -> Result(State, Result(Nil, String)) {
  let #(cleaned_buffer, should_continue, set_active) = case
    state.frame_buffer.data
  {
    <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8, rest:bits>> -> {
      #(buffer.new(rest), True, True)
    }
    _ -> #(state.frame_buffer, True, False)
  }

  case should_continue {
    False -> Ok(state)
    True -> {
      let _ = case set_active {
        True -> http.set_socket_active(conn.transport, conn.socket)
        False -> Ok(Nil)
      }

      let state = State(..state, frame_buffer: cleaned_buffer)
      // Only decode if we have at least 9 bytes (minimum frame header size)
      case bit_array.byte_size(state.frame_buffer.data) {
        size if size < 9 -> Ok(state)
        // Not enough data for a frame header
        _ ->
          case frame.decode(state.frame_buffer.data) {
            Ok(#(frame, rest)) -> {
              let new_state = State(..state, frame_buffer: buffer.new(rest))
              case handle_frame(frame, new_state, conn, handler) {
                Ok(updated) -> call(updated, conn, handler)
                Error(reason) -> Error(Error(reason))
              }
            }
            Error(frame.NoError) -> Ok(state)
            Error(connection_error) -> {
              // Send GOAWAY frame with last good stream ID
              let last_stream_id = get_last_stream_id(state)
              let _ =
                http2.send_frame(
                  frame.GoAway(
                    data: <<>>,
                    error: connection_error,
                    last_stream_id: frame.stream_identifier(last_stream_id),
                  ),
                  conn.socket,
                  conn.transport,
                )

              // Return error to terminate connection
              let error_msg = case connection_error {
                frame.ProtocolError -> "Protocol error"
                frame.InternalError -> "Internal error"
                frame.FlowControlError -> "Flow control error"
                frame.SettingsTimeout -> "Settings timeout"
                frame.StreamClosed -> "Stream closed error"
                frame.FrameSizeError -> "Frame size error"
                frame.RefusedStream -> "Refused stream"
                frame.Cancel -> "Cancelled"
                frame.CompressionError -> "Compression error"
                frame.ConnectError -> "Connect error"
                frame.EnhanceYourCalm -> "Enhance your calm"
                frame.InadequateSecurity -> "Inadequate security"
                frame.Http11Required -> "HTTP/1.1 required"
                frame.Unsupported(code) ->
                  "Unsupported error code: " <> int.to_string(code)
                frame.NoError -> "No error"
              }
              Error(Error(error_msg))
            }
          }
      }
    }
  }
}

// TODO:  this should use the frame error types to actually do some shit with
// the stream(s)
fn handle_frame(
  frame: Frame,
  state: State,
  conn: Connection,
  handler: Handler,
) -> Result(State, String) {
  case state.fragment, frame {
    // Handle existing continuation frame logic (simplified)
    Some(frame.Header(
      identifier: id1,
      data: Continued(existing),
      end_stream: end_stream,
      priority: priority,
    )),
      frame.Continuation(data: Complete(data), identifier: id2)
      if id1 == id2
    -> {
      let complete_frame =
        frame.Header(
          identifier: id1,
          data: Complete(<<existing:bits, data:bits>>),
          end_stream: end_stream,
          priority: priority,
        )
      handle_frame(
        complete_frame,
        State(..state, fragment: None),
        conn,
        handler,
      )
    }
    Some(frame.Header(
      identifier: id1,
      data: Continued(existing),
      end_stream: end_stream,
      priority: priority,
    )),
      frame.Continuation(data: Continued(data), identifier: id2)
      if id1 == id2
    -> {
      let next =
        frame.Header(
          identifier: id1,
          data: Continued(<<existing:bits, data:bits>>),
          end_stream: end_stream,
          priority: priority,
        )
      Ok(State(..state, fragment: Some(next)))
    }
    None, frame.WindowUpdate(amount, identifier) -> {
      case frame.get_stream_identifier(identifier) {
        0 -> {
          // do_pending_sends(state)
          Ok(
            State(
              ..state,
              settings: Http2Settings(
                ..state.settings,
                initial_window_size: amount,
              ),
            ),
          )
        }
        _stream_id -> {
          use stream <- result.try(
            state.streams
            |> dict.get(identifier)
            |> result.replace_error("Window update for non-existent stream"),
          )
          case
            flow_control.update_send_window(stream.send_window_size, amount)
          {
            Ok(update) -> {
              let new_stream = stream.State(..stream, send_window_size: update)
              Ok(
                State(
                  ..state,
                  streams: dict.insert(state.streams, identifier, new_stream),
                ),
              )
            }
            _err -> Error("Failed to update send window")
          }
        }
      }
    }
    None, frame.Header(Continued(data), end_stream, identifier, priority) -> {
      // Incomplete header frame - store as fragment
      Ok(
        State(
          ..state,
          fragment: Some(frame.Header(
            data: Continued(data),
            end_stream: end_stream,
            identifier: identifier,
            priority: priority,
          )),
        ),
      )
    }
    None, frame.Header(Complete(data), end_stream, identifier, _priority) -> {
      let conn =
        Connection(
          body: Initial(<<>>),
          socket: conn.socket,
          transport: conn.transport,
        )
      use #(headers, context) <- result.try(
        http2.hpack_decode(state.receive_hpack_context, data)
        |> result.map_error(fn(_) { "Failed to decode HPACK headers" })
      )

      let pending_content_length =
        headers
        |> list.key_find("content-length")
        |> result.try(int.parse)
        |> option.from_result

      use new_stream <- result.try(
        stream.new(identifier, handler, headers, conn, state.self, end_stream)
        |> result.map_error(fn(_) { "Failed to create new stream" })
      )
      process.send(new_stream.data, Ready)

      let stream_state =
        stream.State(
          id: identifier,
          state: stream.Open,
          subject: new_stream.data,
          receive_window_size: state.settings.initial_window_size,
          send_window_size: state.settings.initial_window_size,
          pending_content_length: pending_content_length,
        )
      let streams = dict.insert(state.streams, identifier, stream_state)
      Ok(State(..state, receive_hpack_context: context, streams: streams))
    }
    None, frame.Data(identifier: identifier, data: data, end_stream: end_stream)
    -> {
      let data_size = bit_array.byte_size(data)
      let #(conn_receive_window_size, conn_window_increment) =
        flow_control.compute_receive_window(
          state.receive_window_size,
          data_size,
        )

      case dict.get(state.streams, identifier) {
        Error(_) -> {
          // Stream doesn't exist - send RST_STREAM
          let _ =
            http2.send_frame(
              frame.Termination(
                error: frame.StreamClosed,
                identifier: identifier,
              ),
              conn.socket,
              conn.transport,
            )
          Ok(state)
        }
        Ok(stream_state) -> {
          let #(updated_stream, increment) =
            stream.receive_data(stream_state, data_size)

          // Update stream state based on end_stream flag
          let final_stream = case end_stream {
            True ->
              case updated_stream.state {
                stream.Open ->
                  stream.State(..updated_stream, state: stream.RemoteClosed)
                stream.LocalClosed ->
                  stream.State(..updated_stream, state: stream.Closed)
                _ -> updated_stream
              }
            False -> updated_stream
          }

          let updated_streams = case final_stream.state {
            stream.Closed -> dict.delete(state.streams, identifier)
            _ -> dict.insert(state.streams, identifier, final_stream)
          }

          let _ =
            case conn_window_increment > 0 {
              True -> {
                http2.send_frame(
                  frame.WindowUpdate(
                    identifier: frame.stream_identifier(0),
                    amount: conn_window_increment,
                  ),
                  conn.socket,
                  conn.transport,
                )
              }
              False -> Ok(Nil)
            }
            |> result.replace_error("Failed to send connection window update")

          let _ =
            case increment > 0 {
              True -> {
                http2.send_frame(
                  frame.WindowUpdate(identifier: identifier, amount: increment),
                  conn.socket,
                  conn.transport,
                )
              }
              False -> Ok(Nil)
            }
            |> result.replace_error("Failed to send stream window update")

          process.send(
            final_stream.subject,
            stream.Data(bits: data, end: end_stream),
          )

          Ok(
            State(
              ..state,
              streams: updated_streams,
              receive_window_size: conn_receive_window_size,
            ),
          )
        }
      }
    }
    None, frame.Priority(..) -> {
      Ok(state)
    }
    None, frame.Settings(ack: True, ..) -> {
      Ok(state)
    }
    _, frame.Settings(ack: False, settings: new_settings) -> {
      // Update settings and HPACK context
      use updated_settings <- result.try(
        http2.update_settings(state.settings, new_settings)
        |> result.map_error(fn(err) {
          // Send GOAWAY for invalid settings
          let _ =
            http2.send_frame(
              frame.GoAway(
                data: <<>>,
                error: frame.ProtocolError,
                last_stream_id: frame.stream_identifier(get_last_stream_id(
                  state,
                )),
              ),
              conn.socket,
              conn.transport,
            )
          err
        }),
      )

      // Update HPACK context table size if changed
      let updated_receive_context = case
        updated_settings.header_table_size != state.settings.header_table_size
      {
        True ->
          http2.hpack_max_table_size(
            state.receive_hpack_context,
            updated_settings.header_table_size,
          )
        False -> state.receive_hpack_context
      }

      let updated_send_context = case
        updated_settings.header_table_size != state.settings.header_table_size
      {
        True ->
          http2.hpack_max_table_size(
            state.send_hpack_context,
            updated_settings.header_table_size,
          )
        False -> state.send_hpack_context
      }

      let updated_state =
        State(
          ..state,
          settings: updated_settings,
          receive_hpack_context: updated_receive_context,
          send_hpack_context: updated_send_context,
        )

      http2.send_frame(frame.settings_ack(), conn.socket, conn.transport)
      |> result.replace(updated_state)
      |> result.replace_error("Failed to respond to settings ACK")
    }
    None, frame.GoAway(data, error, last_stream_id) -> {
      // Gracefully close streams above last_stream_id
      let last_id = frame.get_stream_identifier(last_stream_id)
      let _cleaned_streams =
        dict.filter(state.streams, fn(stream_id, _stream) {
          frame.get_stream_identifier(stream_id) <= last_id
        })

      let error_msg = case error {
        frame.NoError -> "Connection closed gracefully"
        _ -> "Connection closed with error: " <> bit_array.inspect(data)
      }

      Error(error_msg)
    }
    // TODO:  obviously fill these out
    _, _frame -> {
      Ok(state)
    }
  }
}
