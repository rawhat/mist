import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mist/internal/buffer.{type Buffer}
import mist/internal/http.{
  type Connection, type Handler, type ResponseData, Connection, Initial,
}
import mist/internal/http2.{type HpackContext, type Http2Settings, Http2Settings}
import mist/internal/http2/frame.{
  type Frame, type StreamIdentifier, Complete, Continued, Settings,
}
import mist/internal/http2/stream

pub type Message {
  Send(identifier: StreamIdentifier(Frame), resp: Response(ResponseData))
}

pub type PendingSend {
  PendingSend
}

pub type State {
  State(
    fragment: Option(Frame),
    frame_buffer: Buffer,
    hpack_context: HpackContext,
    pending_sends: List(PendingSend),
    self: Subject(Message),
    settings: Http2Settings,
    streams: Dict(StreamIdentifier(Frame), stream.State),
  )
}

pub fn with_hpack_context(state: State, context: HpackContext) -> State {
  State(..state, hpack_context: context)
}

pub fn append_data(state: State, data: BitArray) -> State {
  State(..state, frame_buffer: buffer.append(state.frame_buffer, data))
}

pub fn upgrade(
  data: BitArray,
  conn: Connection,
  self: Subject(Message),
) -> Result(State, process.ExitReason) {
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
  |> result.map_error(fn(_err) { process.Abnormal("Missing first frame") })
  |> result.then(fn(pair) {
    let assert #(frame, rest) = pair
    case frame {
      Settings(settings: settings, ..) -> {
        let http2_settings = http2.update_settings(initial_settings, settings)
        Ok(State(
          fragment: None,
          frame_buffer: buffer.new(rest),
          hpack_context: http2.hpack_new_context(
            http2_settings.header_table_size,
          ),
          pending_sends: [],
          self: self,
          settings: http2_settings,
          streams: dict.new(),
        ))
      }
      _ -> {
        let assert Ok(_) = conn.transport.close(conn.socket)
        Error(process.Abnormal("SETTINGS frame must be sent first"))
      }
    }
  })
}

pub fn call(
  state: State,
  conn: Connection,
  handler: Handler,
) -> Result(State, process.ExitReason) {
  case frame.decode(state.frame_buffer.data) {
    Ok(#(frame, rest)) -> {
      io.println("frame:  " <> erlang.format(frame))
      io.println("rest:  " <> erlang.format(rest))
      let new_state = State(..state, frame_buffer: buffer.new(rest))
      case handle_frame(frame, new_state, conn, handler) {
        Ok(updated) -> call(updated, conn, handler)
        Error(reason) -> Error(reason)
      }
    }
    Error(frame.NoError) -> Ok(state)
    Error(_connection_error) -> {
      // TODO:
      //  - send GOAWAY with last good stream ID
      //  - close the connection
      Ok(state)
    }
  }
}

import gleam/erlang

// TODO:  this should use the frame error types to actually do some shit with
// the stream(s)
fn handle_frame(
  frame: Frame,
  state: State,
  conn: Connection,
  handler: Handler,
) -> Result(State, process.ExitReason) {
  case state.fragment, frame {
    Some(frame.Header(
      identifier: id1,
      data: Continued(existing),
      end_stream: end_stream,
      priority: priority,
    )), frame.Continuation(data: Complete(data), identifier: id2) if id1 == id2 -> {
      let complete_frame =
        frame.Header(
          identifier: id1,
          data: Complete(<<existing:bits, data:bits>>),
          end_stream: end_stream,
          priority: priority,
        )
      handle_frame(complete_frame, State(..state, fragment: None), conn, handler,
      )
    }
    Some(frame.Header(
      identifier: id1,
      data: Continued(existing),
      end_stream: end_stream,
      priority: priority,
    )), frame.Continuation(data: Continued(data), identifier: id2) if id1 == id2 -> {
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
          io.println("setting window size!")
          Ok(
            State(
              ..state,
              settings: Http2Settings(
                ..state.settings,
                initial_window_size: amount,
              ),
              hpack_context: state.hpack_context,
            ),
          )
        }
        _n -> {
          todo
        }
      }
    }
    None, frame.Header(Complete(data), end_stream, identifier, _priority) -> {
      // TODO:
      //  x add stream to dict
      //  - figure out how to get the headers to it
      //  - figure out how to allow reading from the body
      //    - this presumably would require "blocking" on that until it
      //      receives the rest of the data
      let conn =
        Connection(
          body: Initial(<<>>),
          socket: conn.socket,
          transport: conn.transport,
          client_ip: conn.client_ip,
        )
      let assert Ok(#(headers, context)) =
        http2.hpack_decode(state.hpack_context, data)
      io.println("we got some headers:  " <> erlang.format(headers))

      let pending_content_length =
        headers
        |> list.key_find("content-length")
        |> result.then(int.parse)
        |> option.from_result

      let assert Ok(new_stream) =
        stream.new(
          identifier,
          state.settings.initial_window_size,
          handler,
          conn,
          fn(resp) { process.send(state.self, Send(identifier, resp)) },
        )
      let stream_state =
        stream.State(
          id: identifier,
          state: stream.Open,
          subj: new_stream,
          receive_window_size: state.settings.initial_window_size,
          send_window_size: state.settings.initial_window_size,
          pending_content_length: pending_content_length,
        )
      let streams = dict.insert(state.streams, identifier, stream_state)
      process.send(new_stream, stream.Headers(headers, end_stream))
      Ok(State(..state, hpack_context: context, streams: streams))
    }
    None, frame.Priority(..) -> {
      Ok(state)
    }
    None, frame.Settings(ack: True, ..) -> {
      let resp = frame.settings_ack()
      conn.transport.send(conn.socket, bytes_builder.from_bit_array(resp))
      |> result.replace(state)
      |> result.replace_error(process.Abnormal(
        "Failed to respond to settings ACK",
      ))
    }
    _, frame.Settings(..) -> {
      let resp = frame.settings_ack()
      conn.transport.send(conn.socket, bytes_builder.from_bit_array(resp))
      |> result.replace(state)
      |> result.replace_error(process.Abnormal(
        "Failed to respond to settings ACK",
      ))
    }
    None, frame.GoAway(..) -> {
      io.println("byeeee~~")
      Error(process.Normal)
    }
    // TODO:  obviously fill these out
    _, _ -> Ok(state)
  }
}

fn do_pending_sends() -> todo_type {
  todo
}
