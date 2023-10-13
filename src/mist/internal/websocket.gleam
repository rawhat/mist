import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/dynamic
import gleam/erlang.{rescue}
import gleam/erlang/atom
import gleam/erlang/process.{Selector, Subject}
import gleam/list
import gleam/option.{Option, Some}
import gleam/otp/actor
import gleam/result
import glisten/socket.{Socket}
import glisten/socket/options
import glisten/socket/transport.{Transport}
import mist/internal/logger

pub type DataFrame {
  TextFrame(payload_length: Int, payload: BitString)
  BinaryFrame(payload_length: Int, payload: BitString)
}

pub type ControlFrame {
  // TODO:  should this include data?
  CloseFrame(payload_length: Int, payload: BitString)
  // We don't care about basicaly everything else for now
  PingFrame(payload_length: Int, payload: BitString)
  PongFrame(payload_length: Int, payload: BitString)
}

// TODO:  there are other message types, AND ALSO will need to buffer across
// multiple frames, potentially
pub type Frame {
  Data(DataFrame)
  Control(ControlFrame)
}

@external(erlang, "crypto", "exor")
fn crypto_exor(a a: BitString, b b: BitString) -> BitString

fn unmask_data(
  data: BitString,
  masks: List(BitString),
  index: Int,
  resp: BitString,
) -> BitString {
  case data {
    <<>> -> resp
    <<masked:bit_string-size(8), rest:bit_string>> -> {
      let assert Ok(mask_value) = list.at(masks, index % 4)
      let unmasked = crypto_exor(mask_value, masked)
      unmask_data(
        rest,
        masks,
        index + 1,
        <<resp:bit_string, unmasked:bit_string>>,
      )
    }
  }
}

pub fn frame_from_message(
  socket: Socket,
  transport: Transport,
  message: BitString,
) -> Result(Frame, Nil) {
  let assert <<_fin:1, rest:bit_string>> = message
  let assert <<_reserved:3, rest:bit_string>> = rest
  let assert <<opcode:int-size(4), rest:bit_string>> = rest
  // mask
  let assert <<1:1, rest:bit_string>> = rest
  let assert <<payload_length:int-size(7), rest:bit_string>> = rest
  let #(payload_length, rest) = case payload_length {
    126 -> {
      let assert <<length:int-size(16), rest:bit_string>> = rest
      #(length, rest)
    }
    127 -> {
      let assert <<length:int-size(64), rest:bit_string>> = rest
      #(length, rest)
    }
    _ -> #(payload_length, rest)
  }
  let assert <<
    mask1:bit_string-size(8),
    mask2:bit_string-size(8),
    mask3:bit_string-size(8),
    mask4:bit_string-size(8),
    rest:bit_string,
  >> = rest
  case payload_length - bit_string.byte_size(rest) {
    0 -> Ok(unmask_data(rest, [mask1, mask2, mask3, mask4], 0, <<>>))
    need -> {
      need
      |> transport.receive(socket, _)
      |> result.replace_error(Nil)
      |> result.map(fn(needed) {
        rest
        |> bit_string.append(needed)
        |> unmask_data([mask1, mask2, mask3, mask4], 0, <<>>)
      })
    }
  }
  |> result.map(fn(data) {
    case opcode {
      1 -> Data(TextFrame(payload_length, data))
      2 -> Data(BinaryFrame(payload_length, data))
      8 -> Control(CloseFrame(payload_length, data))
      9 -> Control(PingFrame(payload_length, data))
      10 -> Control(PongFrame(payload_length, data))
    }
  })
}

pub fn frame_to_bit_builder(frame: Frame) -> BitBuilder {
  case frame {
    Data(TextFrame(payload_length, payload)) ->
      make_frame(1, payload_length, payload)
    Control(CloseFrame(payload_length, payload)) ->
      make_frame(8, payload_length, payload)
    Data(BinaryFrame(payload_length, payload)) ->
      make_frame(2, payload_length, payload)
    Control(PongFrame(payload_length, payload)) ->
      make_frame(10, payload_length, payload)
    Control(PingFrame(payload_length, payload)) ->
      make_frame(9, payload_length, payload)
  }
}

fn make_frame(opcode: Int, length: Int, payload: BitString) -> BitBuilder {
  let length_section = case length {
    length if length > 65_535 -> <<127:7, length:int-size(64)>>
    length if length >= 126 -> <<126:7, length:int-size(16)>>
    _length -> <<length:7>>
  }

  <<1:1, 0:3, opcode:4, 0:1, length_section:bit_string, payload:bit_string>>
  |> bit_builder.from_bit_string
}

pub fn to_text_frame(data: BitString) -> BitBuilder {
  let size = bit_string.byte_size(data)
  frame_to_bit_builder(Data(TextFrame(size, data)))
}

pub fn to_binary_frame(data: BitString) -> BitBuilder {
  let size = bit_string.byte_size(data)
  frame_to_bit_builder(Data(BinaryFrame(size, data)))
}

pub type ValidMessage(user_message) {
  Internal(Frame)
  SocketClosed
  User(user_message)
}

pub type WebsocketMessage(user_message) {
  Valid(ValidMessage(user_message))
  Invalid
}

pub type WebsocketConnection {
  WebsocketConnection(socket: Socket, transport: Transport)
}

pub type Handler(state, message) =
  fn(state, WebsocketConnection, ValidMessage(message)) ->
    actor.Next(message, state)

pub fn initialize_connection(
  on_init: fn() -> #(state, Option(Selector(user_message))),
  on_close: fn() -> Nil,
  handler: Handler(state, user_message),
  socket: Socket,
  transport: Transport,
) -> Result(Subject(WebsocketMessage(user_message)), Nil) {
  let connection = WebsocketConnection(socket: socket, transport: transport)
  // TODO:  Will likely need to monitor this somehow... maybe have a
  // `selecting_forever`
  actor.start_spec(actor.Spec(
    init: fn() {
      let #(initial_state, user_selector) = on_init()
      // TODO: this is pulled straight from glisten, prob should share it
      let selector =
        process.new_selector()
        |> process.selecting_record3(
          atom.create_from_string("tcp"),
          fn(_sock, data) {
            data
            |> dynamic.bit_string
            |> result.replace_error(Nil)
            |> result.then(frame_from_message(socket, transport, _))
            |> result.map(Internal)
            |> result.map(Valid)
            |> result.unwrap(Invalid)
          },
        )
        |> process.selecting_record3(
          atom.create_from_string("ssl"),
          fn(_sock, data) {
            data
            |> dynamic.bit_string
            |> result.replace_error(Nil)
            |> result.then(frame_from_message(socket, transport, _))
            |> result.map(Internal)
            |> result.map(Valid)
            |> result.unwrap(Invalid)
          },
        )
        |> process.selecting_record2(
          atom.create_from_string("ssl_closed"),
          fn(_nil) { Valid(SocketClosed) },
        )
        |> process.selecting_record2(
          atom.create_from_string("tcp_closed"),
          fn(_nil) { Valid(SocketClosed) },
        )
        |> fn(selector) {
          case user_selector {
            Some(user_selector) ->
              user_selector
              |> process.map_selector(User)
              |> process.map_selector(Valid)
              |> process.merge_selector(selector)
            _ -> selector
          }
        }

      actor.Ready(initial_state, selector)
    },
    init_timeout: 500,
    loop: fn(msg, state) {
      case msg {
        Valid(Internal(Control(CloseFrame(..)) as frame)) -> {
          let _ =
            connection.transport.send(
              connection.socket,
              frame_to_bit_builder(frame),
            )
          on_close()
          actor.Stop(process.Normal)
        }
        Valid(Internal(Control(PingFrame(length, payload)))) -> {
          connection.transport.send(
            connection.socket,
            frame_to_bit_builder(Control(PongFrame(length, payload))),
          )
          |> result.map(fn(_nil) { actor.continue(state) })
          |> result.lazy_unwrap(fn() {
            on_close()
            actor.Stop(process.Abnormal("Failed to send pong frame"))
          })
        }
        Invalid -> {
          logger.error(#("Received a malformed Websocket frame"))
          actor.continue(state)
        }
        Valid(msg) -> {
          rescue(fn() { handler(state, connection, msg) })
          |> result.map(fn(cont) {
            case cont {
              actor.Continue(state, selector) -> {
                selector
                |> option.map(process.map_selector(_, fn(msg) {
                  Valid(User(msg))
                }))
                |> actor.Continue(state, _)
              }
              actor.Stop(reason) -> {
                on_close()
                actor.Stop(reason)
              }
            }
          })
          |> result.lazy_unwrap(fn() {
            logger.error("Caught error in websocket handler")
            on_close()
            actor.Stop(process.Abnormal("Websocket terminated"))
          })
        }
      }
    },
  ))
  |> result.replace_error(Nil)
  |> result.map(fn(subj) {
    let websocket_pid = process.subject_owner(subj)
    let assert Ok(_) =
      connection.transport.controlling_process(connection.socket, websocket_pid)
    let assert Ok(_) =
      connection.transport.set_opts(
        connection.socket,
        [options.ActiveMode(options.Active)],
      )
    subj
  })
  |> result.replace_error(Nil)
}
