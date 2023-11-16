import gleam/bytes_builder.{type BytesBuilder}
import gleam/bit_array
import gleam/dynamic
import gleam/erlang.{rescue}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/list
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/result
import glisten/socket.{type Socket}
import glisten/socket/options
import glisten/socket/transport.{type Transport}
import mist/internal/logger

pub type DataFrame {
  TextFrame(payload_length: Int, payload: BitArray)
  BinaryFrame(payload_length: Int, payload: BitArray)
}

pub type ControlFrame {
  // TODO:  should this include data?
  CloseFrame(payload_length: Int, payload: BitArray)
  // We don't care about basicaly everything else for now
  PingFrame(payload_length: Int, payload: BitArray)
  PongFrame(payload_length: Int, payload: BitArray)
}

// TODO:  there are other message types, AND ALSO will need to buffer across
// multiple frames, potentially
pub type Frame {
  Data(DataFrame)
  Control(ControlFrame)
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
    <<>> -> resp
    <<masked:bits-size(8), rest:bits>> -> {
      let assert Ok(mask_value) = list.at(masks, index % 4)
      let unmasked = crypto_exor(mask_value, masked)
      unmask_data(rest, masks, index + 1, <<resp:bits, unmasked:bits>>)
    }
  }
}

pub fn frame_from_message(
  socket: Socket,
  transport: Transport,
  message: BitArray,
) -> Result(Frame, Nil) {
  let assert <<_fin:1, rest:bits>> = message
  let assert <<_reserved:3, rest:bits>> = rest
  let assert <<opcode:int-size(4), rest:bits>> = rest
  // mask
  let assert <<1:1, rest:bits>> = rest
  let assert <<payload_length:int-size(7), rest:bits>> = rest
  let #(payload_length, rest) = case payload_length {
    126 -> {
      let assert <<length:int-size(16), rest:bits>> = rest
      #(length, rest)
    }
    127 -> {
      let assert <<length:int-size(64), rest:bits>> = rest
      #(length, rest)
    }
    _ -> #(payload_length, rest)
  }
  let assert <<
    mask1:bits-size(8),
    mask2:bits-size(8),
    mask3:bits-size(8),
    mask4:bits-size(8),
    rest:bits,
  >> = rest
  case payload_length - bit_array.byte_size(rest) {
    0 -> Ok(unmask_data(rest, [mask1, mask2, mask3, mask4], 0, <<>>))
    need -> {
      need
      |> transport.receive(socket, _)
      |> result.replace_error(Nil)
      |> result.map(fn(needed) {
        rest
        |> bit_array.append(needed)
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

pub fn frame_to_bytes_builder(frame: Frame) -> BytesBuilder {
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

fn make_frame(opcode: Int, length: Int, payload: BitArray) -> BytesBuilder {
  let length_section = case length {
    length if length > 65_535 -> <<127:7, length:int-size(64)>>
    length if length >= 126 -> <<126:7, length:int-size(16)>>
    _length -> <<length:7>>
  }

  <<1:1, 0:3, opcode:4, 0:1, length_section:bits, payload:bits>>
  |> bytes_builder.from_bit_array
}

pub fn to_text_frame(data: BitArray) -> BytesBuilder {
  let size = bit_array.byte_size(data)
  frame_to_bytes_builder(Data(TextFrame(size, data)))
}

pub fn to_binary_frame(data: BitArray) -> BytesBuilder {
  let size = bit_array.byte_size(data)
  frame_to_bytes_builder(Data(BinaryFrame(size, data)))
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
  on_close: fn(state) -> Nil,
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
            |> dynamic.bit_array
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
            |> dynamic.bit_array
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
              frame_to_bytes_builder(frame),
            )
          on_close(state)
          actor.Stop(process.Normal)
        }
        Valid(Internal(Control(PingFrame(length, payload)))) -> {
          connection.transport.send(
            connection.socket,
            frame_to_bytes_builder(Control(PongFrame(length, payload))),
          )
          |> result.map(fn(_nil) {
            let assert Ok(_) =
              connection.transport.set_opts(
                connection.socket,
                [options.ActiveMode(options.Once)],
              )
            actor.continue(state)
          })
          |> result.lazy_unwrap(fn() {
            on_close(state)
            actor.Stop(process.Abnormal("Failed to send pong frame"))
          })
        }
        Invalid -> {
          logger.error(#("Received a malformed Websocket frame"))
          let assert Ok(_) =
            connection.transport.set_opts(
              connection.socket,
              [options.ActiveMode(options.Once)],
            )
          actor.continue(state)
        }
        Valid(msg) -> {
          rescue(fn() { handler(state, connection, msg) })
          |> result.map(fn(cont) {
            case cont {
              actor.Continue(state, selector) -> {
                let assert Ok(_) =
                  connection.transport.set_opts(
                    connection.socket,
                    [options.ActiveMode(options.Once)],
                  )
                selector
                |> option.map(process.map_selector(_, fn(msg) {
                  Valid(User(msg))
                }))
                |> actor.Continue(state, _)
              }
              actor.Stop(reason) -> {
                on_close(state)
                actor.Stop(reason)
              }
            }
          })
          |> result.lazy_unwrap(fn() {
            logger.error("Caught error in websocket handler")
            on_close(state)
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
        [options.ActiveMode(options.Once)],
      )
    subj
  })
  |> result.replace_error(Nil)
}
