import gleam/bit_string
import gleam/bit_string
import gleam/erlang/charlist.{Charlist}
import gleam/http/request.{Request}
import gleam/http/response.{Response}
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import gleam/string
import mist/http.{parse_request, to_string}
import mist/glisten/glisten/tcp.{
  LoopFn, ReceiveMessage, Socket, TcpClosed, send,
}

pub type WebsocketState {
  WebsocketState(upgraded: Bool)
}

pub fn new_state() -> WebsocketState {
  WebsocketState(upgraded: False)
}

// TODO:  need binary here as well
pub type WebsocketMessage {
  TextMessage(data: String)
}

pub type WebsocketHandler =
  fn(WebsocketMessage, Socket, WebsocketState) -> #(Socket, WebsocketState)

external fn charlist_to_binary(char: Charlist) -> BitString =
  "erlang" "list_to_binary"

external fn bin_to_charlist(bs: BitString) -> Charlist =
  "erlang" "bitstring_to_list"

// TODO:  there are other message types, AND ALSO will need to buffer across
// multiple frames, potentially
pub type WebsocketFrame {
  TextFrame(payload_length: Int, payload: String)
  // We don't care about basicaly everything else
  PingFrame(payload_length: Int, payload: String)
  PongFrame(payload_length: Int, payload: String)
}

pub fn xor(a: BitString, b: BitString, resp: BitString) -> BitString {
  case a, b {
    <<>>, <<>> -> resp
    <<0:1, a_rest:bit_string>>, <<1:1, b_rest:bit_string>> | <<
      1:1,
      a_rest:bit_string,
    >>, <<0:1, b_rest:bit_string>> ->
      xor(a_rest, b_rest, <<resp:bit_string, 1:1>>)
    <<_, a_rest:bit_string>>, <<_, b_rest:bit_string>> ->
      xor(a_rest, b_rest, <<resp:bit_string, 0:1>>)
  }
}

external fn crypto_exor(a: BitString, b: BitString) -> BitString =
  "crypto" "exor"

fn unmask_data(
  data: BitString,
  masks: List(BitString),
  index: Int,
  resp: BitString,
) -> BitString {
  case data {
    <<>> -> resp
    <<masked:bit_string-size(8), rest:bit_string>> -> {
      assert Ok(mask_value) = list.at(masks, index % 4)
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

pub fn frame_from_message(message: Charlist) -> Result(WebsocketFrame, Nil) {
  assert <<
    _fin:1,
    _reserved:3,
    opcode:int-size(4),
    1:1,
    payload_length:int-size(7),
    mask1:bit_string-size(8),
    mask2:bit_string-size(8),
    mask3:bit_string-size(8),
    mask4:bit_string-size(8),
    rest:bit_string,
  >> = charlist_to_binary(message)

  assert Ok(data) =
    rest
    |> unmask_data([mask1, mask2, mask3, mask4], 0, <<>>)
    |> bit_string.to_string

  case opcode {
    1 -> TextFrame(payload_length: payload_length, payload: data)
  }
  |> Ok
}

// TODO:  support other message types here too
pub fn message_to_frame(data: String) -> WebsocketFrame {
  TextFrame(
    payload_length: data
    |> bit_string.from_string
    |> bit_string.byte_size,
    payload: data,
  )
}

pub fn frame_to_charlist(frame: WebsocketFrame) -> Charlist {
  case frame {
    TextFrame(payload_length, payload) -> {
      let fin = 1
      let mask_flag = 0
      let payload_bs = bit_string.from_string(payload)
      // TODO:  support extended payload length
      <<fin:1, 0:3, 1:4, mask_flag:1, payload_length:7, payload_bs:bit_string>>
    }
    PingFrame(..) -> <<>>
    PongFrame(payload_length, payload) -> {
      let payload_bs = bit_string.from_string(payload)
      <<1:1, 0:3, 10:4, 0:1, payload_length:7, payload_bs:bit_string>>
    }
  }
  |> bin_to_charlist
}

pub fn ws_send(socket: Socket, data: String) -> Result(Nil, tcp.SocketReason) {
  let size =
    data
    |> bit_string.from_string
    |> bit_string.byte_size
  let msg = frame_to_charlist(TextFrame(size, data))
  let resp = send(socket, msg)
  resp
}

pub fn websocket_handler(handler: WebsocketHandler) -> LoopFn(WebsocketState) {
  fn(msg, state) {
    let #(socket, WebsocketState(upgraded) as ws_state) = state
    case msg, upgraded {
      ReceiveMessage(data), False ->
        case data
        |> charlist.to_string
        |> bit_string.from_string
        |> parse_request {
          Ok(req) -> {
            assert Ok(resp) = upgrade_socket(req)
            assert Ok(_) =
              resp
              |> to_string
              |> bit_string.to_string
              |> result.map(charlist.from_string)
              |> result.map(send(socket, _))
            actor.Continue(#(socket, WebsocketState(True)))
          }
          _ -> {
            actor.Stop(process.Normal)
          }
        }
      ReceiveMessage(data), True -> {
        assert Ok(TextFrame(payload: data, ..)) = frame_from_message(data)
        let next = handler(TextMessage(data), socket, ws_state)
        actor.Continue(next)
      }
      TcpClosed(_), _ -> actor.Continue(state)
      _msg, _ -> {
        actor.Continue(state)
      }
    }
  }
}

const websocket_key = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

pub type ShaHash {
  Sha
}

pub external fn crypto_hash(hash: ShaHash, data: String) -> String =
  "crypto" "hash"

pub external fn base64_encode(data: String) -> String =
  "base64" "encode"

pub fn parse_key(key: String) -> String {
    key
    |> string.append(websocket_key)
    |> crypto_hash(Sha, _)
    |> base64_encode
}

pub fn upgrade_socket(
  req: Request(BitString),
) -> Result(Response(BitString), Request(BitString)) {
  try _upgrade =
    request.get_header(req, "upgrade")
    |> result.replace_error(req)
  try key =
    request.get_header(req, "sec-websocket-key")
    |> result.replace_error(req)
  try _version =
    request.get_header(req, "sec-websocket-version")
    |> result.replace_error(req)

  io.debug(key)
  io.debug(websocket_key)

  let accept_key = parse_key(key)

  response.new(101)
  |> response.set_body(bit_string.from_string(""))
  |> response.prepend_header("Upgrade", "websocket")
  |> response.prepend_header("Connection", "Upgrade")
  |> response.prepend_header("Sec-WebSocket-Accept", accept_key)
  |> Ok
}

pub fn echo_handler(
  msg: WebsocketMessage,
  socket: Socket,
  state: WebsocketState,
) -> #(Socket, WebsocketState) {
  assert Ok(_resp) = ws_send(socket, msg.data)

  #(socket, state)
}
