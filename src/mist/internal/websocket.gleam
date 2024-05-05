import gleam/bit_array
import gleam/bool
import gleam/bytes_builder.{type BytesBuilder}
import gleam/dynamic
import gleam/erlang.{rescue}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import glisten.{type Socket}
import glisten/socket/options
import glisten/transport.{type Transport}
import logging
import mist/internal/websocket/compression.{type Compression, type Context}

pub type DataFrame {
  TextFrame(payload_length: Int, payload: BitArray)
  BinaryFrame(payload_length: Int, payload: BitArray)
}

pub type ControlFrame {
  CloseFrame(payload_length: Int, payload: BitArray)
  PingFrame(payload_length: Int, payload: BitArray)
  PongFrame(payload_length: Int, payload: BitArray)
}

pub type Frame {
  Data(DataFrame)
  Control(ControlFrame)
  Continuation(length: Int, payload: BitArray)
}

@external(erlang, "crypto", "exor")
fn crypto_exor(a a: BitArray, b b: BitArray) -> BitArray

fn unmask_data(
  data: BitArray,
  masks: List(BitArray),
  index: Int,
  resp: BitArray,
) -> BitArray {
  case data {
    <<masked:bits-size(8), rest:bits>> -> {
      let assert Ok(mask_value) = list.at(masks, index % 4)
      let unmasked = crypto_exor(mask_value, masked)
      unmask_data(rest, masks, index + 1, <<resp:bits, unmasked:bits>>)
    }
    _ -> resp
  }
}

type FrameParseError {
  NeedMoreData(BitArray)
  InvalidFrame
}

pub type ParsedFrame {
  Complete(Frame)
  Incomplete(Frame)
}

fn inflate(
  compressed: Bool,
  context: Option(Context),
  data: BitArray,
) -> Result(#(Int, BitArray), FrameParseError) {
  case compressed, context {
    True, Some(context) -> {
      let data = compression.inflate(context, data)
      let length = bit_array.byte_size(data)
      Ok(#(length, data))
    }
    True, None -> Error(InvalidFrame)
    _, _ -> Ok(#(bit_array.byte_size(data), data))
  }
}

fn frame_from_message(
  message: BitArray,
  context: Option(Context),
) -> Result(#(ParsedFrame, BitArray), FrameParseError) {
  case message {
    <<
      complete:1,
      compressed:1,
      _reserved:2,
      opcode:int-size(4),
      1:1,
      payload_length:int-size(7),
      rest:bits,
    >> -> {
      let compressed = compressed == 1
      use <- bool.guard(
        when: compressed && option.is_none(context),
        return: Error(InvalidFrame),
      )
      let payload_size = case payload_length {
        126 -> 16
        127 -> 64
        _ -> 0
      }
      case rest {
        <<
          length:int-size(payload_size),
          mask1:bytes-size(1),
          mask2:bytes-size(1),
          mask3:bytes-size(1),
          mask4:bytes-size(1),
          rest:bits,
        >> -> {
          let payload_byte_size = case length {
            0 -> payload_length
            n -> n
          }
          case rest {
            <<payload:bytes-size(payload_byte_size), rest:bits>> -> {
              let data =
                unmask_data(payload, [mask1, mask2, mask3, mask4], 0, <<>>)
              case opcode {
                0 -> {
                  data
                  |> inflate(compressed, context, _)
                  |> result.map(fn(p) { Continuation(p.0, p.1) })
                }
                1 -> {
                  data
                  |> inflate(compressed, context, _)
                  |> result.map(fn(p) { Data(TextFrame(p.0, p.1)) })
                }
                2 -> {
                  data
                  |> inflate(compressed, context, _)
                  |> result.map(fn(p) { Data(BinaryFrame(p.0, p.1)) })
                }
                8 -> Ok(Control(CloseFrame(payload_length, data)))
                9 -> Ok(Control(PingFrame(payload_length, data)))
                10 -> Ok(Control(PongFrame(payload_length, data)))
                _ -> Error(InvalidFrame)
              }
              |> result.then(fn(frame) {
                case complete {
                  1 -> Ok(#(Complete(frame), rest))
                  0 -> Ok(#(Incomplete(frame), rest))
                  _ -> Error(InvalidFrame)
                }
              })
            }
            _ -> Error(NeedMoreData(message))
          }
        }
        _ -> Error(InvalidFrame)
      }
    }
    _ -> Error(InvalidFrame)
  }
}

pub fn compressed_frame_to_bytes_builder(
  frame: Frame,
  context: Context,
) -> BytesBuilder {
  case frame {
    Data(TextFrame(_payload_length, payload)) ->
      make_compressed_frame(1, payload, context)
    Data(BinaryFrame(_payload_length, payload)) ->
      make_compressed_frame(2, payload, context)
    Control(CloseFrame(payload_length, payload)) ->
      make_frame(8, payload_length, payload)
    Control(PongFrame(payload_length, payload)) ->
      make_frame(10, payload_length, payload)
    Control(PingFrame(payload_length, payload)) ->
      make_frame(9, payload_length, payload)
    Continuation(length, payload) -> make_frame(0, length, payload)
  }
}

pub fn frame_to_bytes_builder(frame: Frame) -> BytesBuilder {
  case frame {
    Data(TextFrame(payload_length, payload)) ->
      make_frame(1, payload_length, payload)
    Data(BinaryFrame(payload_length, payload)) ->
      make_frame(2, payload_length, payload)
    Control(CloseFrame(payload_length, payload)) ->
      make_frame(8, payload_length, payload)
    Control(PongFrame(payload_length, payload)) ->
      make_frame(10, payload_length, payload)
    Control(PingFrame(payload_length, payload)) ->
      make_frame(9, payload_length, payload)
    Continuation(length, payload) -> make_frame(0, length, payload)
  }
}

fn make_length(length: Int) -> BitArray {
  case length {
    length if length > 65_535 -> <<127:7, length:int-size(64)>>
    length if length >= 126 -> <<126:7, length:int-size(16)>>
    _length -> <<length:7>>
  }
}

fn make_compressed_frame(
  opcode: Int,
  payload: BitArray,
  context: Context,
) -> BytesBuilder {
  let data = compression.deflate(context, payload)
  let length = bit_array.byte_size(data)
  let length_section = make_length(length)
  <<1:1, 1:1, 0:2, opcode:4, 0:1, length_section:bits, data:bits>>
  |> bytes_builder.from_bit_array
}

fn make_frame(opcode: Int, length: Int, payload: BitArray) -> BytesBuilder {
  let length_section = make_length(length)
  <<1:1, 0:3, opcode:4, 0:1, length_section:bits, payload:bits>>
  |> bytes_builder.from_bit_array
}

pub fn to_text_frame(data: String, context: Option(Context)) -> BytesBuilder {
  let msg = bit_array.from_string(data)
  let size = bit_array.byte_size(msg)
  let frame = Data(TextFrame(size, msg))
  case context {
    Some(context) -> compressed_frame_to_bytes_builder(frame, context)
    _ -> frame_to_bytes_builder(frame)
  }
}

pub fn to_binary_frame(data: BitArray, context: Option(Context)) -> BytesBuilder {
  let size = bit_array.byte_size(data)
  let frame = Data(BinaryFrame(size, data))
  case context {
    Some(context) -> compressed_frame_to_bytes_builder(frame, context)
    _ -> frame_to_bytes_builder(frame)
  }
}

pub type ValidMessage(user_message) {
  SocketMessage(BitArray)
  SocketClosedMessage
  UserMessage(user_message)
}

pub type WebsocketMessage(user_message) {
  Valid(ValidMessage(user_message))
  Invalid
}

pub type WebsocketConnection {
  WebsocketConnection(
    socket: Socket,
    transport: Transport,
    deflate: Option(Context),
  )
}

pub type HandlerMessage(user_message) {
  Internal(Frame)
  User(user_message)
}

pub type WebsocketState(state) {
  WebsocketState(
    buffer: BitArray,
    user: state,
    permessage_deflate: Option(Compression),
  )
}

pub type Handler(state, message) =
  fn(state, WebsocketConnection, HandlerMessage(message)) ->
    actor.Next(message, state)

// TODO: this is pulled straight from glisten, prob should share it
fn message_selector() -> Selector(WebsocketMessage(user_message)) {
  process.new_selector()
  |> process.selecting_record3(atom.create_from_string("tcp"), fn(_sock, data) {
    data
    |> dynamic.bit_array
    |> result.replace_error(Nil)
    |> result.map(SocketMessage)
    |> result.map(Valid)
    |> result.unwrap(Invalid)
  })
  |> process.selecting_record3(atom.create_from_string("ssl"), fn(_sock, data) {
    data
    |> dynamic.bit_array
    |> result.replace_error(Nil)
    |> result.map(SocketMessage)
    |> result.map(Valid)
    |> result.unwrap(Invalid)
  })
  |> process.selecting_record2(atom.create_from_string("ssl_closed"), fn(_nil) {
    Valid(SocketClosedMessage)
  })
  |> process.selecting_record2(atom.create_from_string("tcp_closed"), fn(_nil) {
    Valid(SocketClosedMessage)
  })
}

pub fn has_deflate(extensions: List(String)) -> Bool {
  list.any(extensions, fn(str) { str == "permessage-deflate" })
}

pub fn initialize_connection(
  on_init: fn(WebsocketConnection) -> #(state, Option(Selector(user_message))),
  on_close: fn(state) -> Nil,
  handler: Handler(state, user_message),
  socket: Socket,
  transport: Transport,
  extensions: List(String),
) -> Result(Subject(WebsocketMessage(user_message)), Nil) {
  let compression = case has_deflate(extensions) {
    True -> Some(compression.init())
    False -> None
  }
  let connection =
    WebsocketConnection(
      socket: socket,
      transport: transport,
      deflate: option.map(compression, fn(compression) { compression.deflate }),
    )
  actor.start_spec(
    actor.Spec(
      init: fn() {
        let #(initial_state, user_selector) = on_init(connection)
        let selector = case user_selector {
          Some(user_selector) ->
            user_selector
            |> process.map_selector(UserMessage)
            |> process.map_selector(Valid)
            |> process.merge_selector(message_selector())
          _ -> message_selector()
        }
        actor.Ready(
          WebsocketState(
            buffer: <<>>,
            user: initial_state,
            permessage_deflate: compression,
          ),
          selector,
        )
      },
      init_timeout: 500,
      loop: fn(msg, state) {
        case msg {
          Valid(SocketMessage(data)) -> {
            let #(frames, rest) =
              get_messages(
                <<state.buffer:bits, data:bits>>,
                [],
                option.map(state.permessage_deflate, fn(compression) {
                  compression.inflate
                }),
              )
            frames
            |> aggregate_frames(None, [])
            |> result.map(fn(frames) {
              let next =
                apply_frames(
                  frames,
                  handler,
                  connection,
                  actor.continue(state.user),
                  on_close,
                )
              case next {
                actor.Continue(user_state, selector) -> {
                  actor.Continue(
                    WebsocketState(..state, buffer: rest, user: user_state),
                    selector,
                  )
                }
                actor.Stop(reason) -> actor.Stop(reason)
              }
            })
            |> result.lazy_unwrap(fn() {
              logging.log(logging.Error, "Received a malformed WebSocket frame")
              on_close(state.user)
              actor.Stop(process.Abnormal(
                "WebSocket received a malformed message",
              ))
            })
          }
          Valid(UserMessage(msg)) -> {
            rescue(fn() { handler(state.user, connection, User(msg)) })
            |> result.map(fn(cont) {
              case cont {
                actor.Continue(user_state, selector) -> {
                  let selector =
                    selector
                    |> map_user_selector
                    |> option.map(fn(with_user) {
                      process.merge_selector(message_selector(), with_user)
                    })
                  actor.Continue(
                    WebsocketState(..state, user: user_state),
                    selector,
                  )
                }
                actor.Stop(reason) -> {
                  on_close(state.user)
                  actor.Stop(reason)
                }
              }
            })
            |> result.map_error(fn(err) {
              logging.log(
                logging.Error,
                "Caught error in websocket handler: " <> erlang.format(err),
              )
            })
            |> result.lazy_unwrap(fn() {
              on_close(state.user)
              actor.Stop(process.Abnormal("Crash in user websocket handler"))
            })
          }
          Valid(SocketClosedMessage) -> {
            on_close(state.user)
            actor.Stop(process.Normal)
          }
          // TODO:  do we need to send something back for this?
          Invalid -> {
            logging.log(logging.Error, "Received a malformed WebSocket frame")
            on_close(state.user)
            actor.Stop(process.Abnormal(
              "WebSocket received a malformed message",
            ))
          }
        }
      },
    ),
  )
  |> result.replace_error(Nil)
  |> result.map(fn(subj) {
    let websocket_pid = process.subject_owner(subj)
    let assert Ok(_) =
      transport.controlling_process(
        connection.transport,
        connection.socket,
        websocket_pid,
      )
    case compression {
      Some(compression) -> {
        compression.set_controlling_process(compression.deflate, websocket_pid)
        compression.set_controlling_process(compression.inflate, websocket_pid)
        Nil
      }
      _ -> Nil
    }
    set_active(connection)
    subj
  })
  |> result.replace_error(Nil)
}

fn get_messages(
  data: BitArray,
  frames: List(ParsedFrame),
  context: Option(Context),
) -> #(List(ParsedFrame), BitArray) {
  case frame_from_message(data, context) {
    Ok(#(frame, <<>>)) -> #(list.reverse([frame, ..frames]), <<>>)
    Ok(#(frame, rest)) -> get_messages(rest, [frame, ..frames], context)
    Error(NeedMoreData(rest)) -> #(list.reverse(frames), rest)
    Error(InvalidFrame) -> #(list.reverse(frames), data)
  }
}

fn apply_frames(
  frames: List(Frame),
  handler: Handler(state, user_message),
  connection: WebsocketConnection,
  next: actor.Next(WebsocketMessage(user_message), state),
  on_close: fn(state) -> Nil,
) -> actor.Next(WebsocketMessage(user_message), state) {
  case frames, next {
    _, actor.Stop(reason) -> actor.Stop(reason)
    [], next -> {
      set_active(connection)
      next
    }
    [Control(CloseFrame(..)) as frame, ..], actor.Continue(state, _selector) -> {
      let _ =
        transport.send(
          connection.transport,
          connection.socket,
          frame_to_bytes_builder(frame),
        )
      on_close(state)
      actor.Stop(process.Normal)
    }
    [Control(PingFrame(length, payload)), ..], actor.Continue(state, _selector) -> {
      transport.send(
        connection.transport,
        connection.socket,
        frame_to_bytes_builder(Control(PongFrame(length, payload))),
      )
      |> result.map(fn(_nil) {
        set_active(connection)
        actor.continue(state)
      })
      |> result.lazy_unwrap(fn() {
        on_close(state)
        actor.Stop(process.Abnormal("Failed to send pong frame"))
      })
    }
    [frame, ..rest], actor.Continue(state, prev_selector) -> {
      case rescue(fn() { handler(state, connection, Internal(frame)) }) {
        Ok(actor.Continue(state, selector)) -> {
          let next_selector =
            selector
            |> map_user_selector
            |> option.or(prev_selector)
            |> option.map(fn(with_user) {
              process.merge_selector(message_selector(), with_user)
            })

          apply_frames(
            rest,
            handler,
            connection,
            actor.Continue(state, next_selector),
            on_close,
          )
        }
        Ok(actor.Stop(reason)) -> {
          on_close(state)
          actor.Stop(reason)
        }
        Error(reason) -> {
          logging.log(
            logging.Error,
            "Caught error in websocket handler: " <> erlang.format(reason),
          )
          on_close(state)
          actor.Stop(process.Abnormal("Crash in user websocket handler"))
        }
      }
    }
  }
}

pub fn aggregate_frames(
  frames: List(ParsedFrame),
  previous: Option(Frame),
  joined: List(Frame),
) -> Result(List(Frame), Nil) {
  case frames, previous {
    [], _ -> Ok(list.reverse(joined))
    [Complete(Continuation(length, data)), ..rest], Some(prev) -> {
      let next = append_frame(prev, length, data)
      aggregate_frames(rest, None, [next, ..joined])
    }
    [Incomplete(Continuation(length, data)), ..rest], Some(prev) -> {
      let next = append_frame(prev, length, data)
      aggregate_frames(rest, Some(next), joined)
    }
    [Incomplete(frame), ..rest], None -> {
      aggregate_frames(rest, Some(frame), joined)
    }
    [Complete(frame), ..rest], None -> {
      aggregate_frames(rest, None, [frame, ..joined])
    }
    _, _ -> Error(Nil)
  }
}

fn set_active(connection: WebsocketConnection) -> Nil {
  let assert Ok(_) =
    transport.set_opts(connection.transport, connection.socket, [
      options.ActiveMode(options.Once),
    ])

  Nil
}

fn map_user_selector(
  selector: Option(Selector(user_message)),
) -> Option(Selector(WebsocketMessage(user_message))) {
  option.map(selector, process.map_selector(_, fn(msg) {
    Valid(UserMessage(msg))
  }))
}

fn append_frame(left: Frame, length: Int, data: BitArray) -> Frame {
  case left {
    Data(TextFrame(len, payload)) ->
      Data(TextFrame(len + length, <<payload:bits, data:bits>>))
    Data(BinaryFrame(len, payload)) ->
      Data(BinaryFrame(len + length, <<payload:bits, data:bits>>))
    Control(CloseFrame(len, payload)) ->
      Control(CloseFrame(len + length, <<payload:bits, data:bits>>))
    Control(PingFrame(len, payload)) ->
      Control(PingFrame(len + length, <<payload:bits, data:bits>>))
    Control(PongFrame(len, payload)) ->
      Control(PongFrame(len + length, <<payload:bits, data:bits>>))
    Continuation(..) -> left
  }
}
