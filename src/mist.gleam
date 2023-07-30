import gleam/bit_builder.{BitBuilder}
import gleam/erlang/process.{ProcessDown, Selector}
import gleam/function
import gleam/http/request.{Request}
import gleam/http/response.{Response}
import gleam/int
import gleam/io
import gleam/iterator.{Iterator}
import gleam/option.{None, Option, Some}
import gleam/otp/actor
import gleam/result
import glisten
import glisten/acceptor
import glisten/socket
import mist/file
import mist/internal/handler.{
  Bytes as InternalBytes, Chunked as InternalChunked, File as InternalFile,
  ResponseData as InternalResponseData, Websocket as InternalWebsocket,
}
import mist/internal/http.{Connection as InternalConnection}
import mist/internal/websocket.{
  BinaryFrame, Data, Internal, SocketClosed, TextFrame, User, ValidMessage,
  WebsocketConnection,
}

/// Re-exported type that represents the default `Request` body type. See
/// `mist.read_body` to convert this type into a `BitString`. The `Connection`
/// also holds some additional information about the request. Currently, the
/// only useful field is `client_ip` which is a `Result` with a tuple of
/// integers representing the IPv4 address.
pub type Connection =
  InternalConnection

/// The response body type. This allows `mist` to handle these different cases
/// for you. `Bytes` is the regular data return. `Websocket` will upgrade the
/// socket to websockets, but should not be used directly. See the
/// `mist.upgrade` function for usage. `Chunked` will use
/// `Transfer-Encoding: chunked` to send an iterator in chunks. `File` will use
/// Erlang's `sendfile` to more efficiently return a file to the client. See the
/// `mist.file` module for some helper functions.
pub type ResponseData {
  Websocket(Selector(ProcessDown))
  Bytes(BitBuilder)
  Chunked(Iterator(BitBuilder))
  File(
    descriptor: file.FileDescriptor,
    content_type: String,
    offset: Int,
    length: Int,
  )
}

/// The possible errors from reading the request body. If the size is larger
/// than the provided value, `ExcessBody` is returned. If there is an error
/// reading the body from the socket or the body is malformed (i.e a chunked
/// request with invalid sizes), `MalformedBody` is returned.
pub type ReadError {
  ExcessBody
  MalformedBody
}

/// The request body is not pulled from the socket until requested. The
/// `content-length` header is used to determine whether the socket is read
/// from or not. The read may also fail, and a `ReadError` is raised.
pub fn read_body(
  req: Request(Connection),
  max_body_limit max_body_limit: Int,
) -> Result(Request(BitString), ReadError) {
  req
  |> request.get_header("content-length")
  |> result.then(int.parse)
  |> result.unwrap(0)
  |> fn(content_length) {
    case content_length {
      value if value <= max_body_limit -> {
        http.read_body(req)
        |> result.replace_error(MalformedBody)
      }
      _ -> {
        Error(ExcessBody)
      }
    }
  }
}

pub opaque type Builder(request_body, response_body) {
  Builder(
    port: Int,
    handler: fn(Request(request_body)) -> Response(response_body),
    after_start: fn(Int) -> Nil,
  )
}

/// Create a new `mist` handler with a given function. The default port is
/// 4000.
pub fn new(handler: fn(Request(in)) -> Response(out)) -> Builder(in, out) {
  Builder(
    port: 4000,
    handler: handler,
    after_start: fn(port) {
      let message = "Listening on localhost:" <> int.to_string(port)
      io.println(message)
    },
  )
}

/// Assign a different listening port to the service.
pub fn port(builder: Builder(in, out), port: Int) -> Builder(in, out) {
  Builder(..builder, port: port)
}

/// This function allows for implicitly reading the body of requests up
/// to a given size. If the size is too large, or the read fails, the provided
/// `failure_response` will be sent back as the response.
pub fn read_request_body(
  builder: Builder(BitString, out),
  bytes_limit bytes_limit: Int,
  failure_response failure_response: Response(out),
) -> Builder(Connection, out) {
  let handler = fn(request) {
    case read_body(request, bytes_limit) {
      Ok(request) -> builder.handler(request)
      Error(_) -> failure_response
    }
  }
  Builder(builder.port, handler, builder.after_start)
}

/// Override the default function to be called after the service starts. The
/// default is to log a message with the listening port.
pub fn after_start(
  builder: Builder(in, out),
  after_start: fn(Int) -> Nil,
) -> Builder(in, out) {
  Builder(..builder, after_start: after_start)
}

fn convert_body_types(
  resp: Response(ResponseData),
) -> Response(InternalResponseData) {
  let new_body = case resp.body {
    Websocket(selector) -> InternalWebsocket(selector)
    Bytes(data) -> InternalBytes(data)
    File(descriptor, content_type, offset, length) ->
      InternalFile(descriptor, content_type, offset, length)
    Chunked(iter) -> InternalChunked(iter)
  }
  response.set_body(resp, new_body)
}

/// Start a `mist` service over HTTP with the provided builder.
pub fn start_http(
  builder: Builder(Connection, ResponseData),
) -> Result(Nil, glisten.StartError) {
  builder.handler
  |> function.compose(convert_body_types)
  |> handler.with_func
  |> acceptor.new_pool_with_data(handler.new_state())
  |> glisten.serve(builder.port, _)
  |> result.map(fn(nil) {
    builder.after_start(builder.port)
    // TODO:  This should not be `Nil` but instead a subject that can receive
    // messages, such as shutdown
    nil
  })
}

/// Start a `mist` service over HTTPS with the provided builder. This method
/// requires both a certificate file and a key file. The library will attempt
/// to read these files off of the disk.
pub fn start_https(
  builder: Builder(Connection, ResponseData),
  certfile certfile: String,
  keyfile keyfile: String,
) -> Result(Nil, glisten.StartError) {
  builder.handler
  |> function.compose(convert_body_types)
  |> handler.with_func
  |> acceptor.new_pool_with_data(handler.new_state())
  |> glisten.serve_ssl(builder.port, certfile, keyfile, _)
  |> result.map(fn(nil) {
    builder.after_start(builder.port)
    // TODO:  This should not be `Nil` but instead a subject that can receive
    // messages, such as shutdown
    nil
  })
}

/// These are the types of messages that a websocket handler may receive.
pub type WebsocketMessage(custom) {
  Text(BitString)
  Binary(BitString)
  Closed
  Shutdown
  Custom(custom)
}

fn internal_to_public_ws_message(
  msg: ValidMessage(custom),
) -> WebsocketMessage(custom) {
  case msg {
    Internal(Data(TextFrame(_length, data))) -> Text(data)
    Internal(Data(BinaryFrame(_length, data))) -> Binary(data)
    SocketClosed -> Closed
    User(msg) -> Custom(msg)
  }
}

pub opaque type WebsocketBuilder(state, message) {
  WebsocketBuilder(
    request: Request(Connection),
    state: state,
    handler: fn(state, WebsocketConnection, ValidMessage(message)) ->
      actor.Next(state),
    selector: Option(process.Selector(message)),
  )
}

/// Initializes a builder for upgrading a connection to Websockets. The
/// default handler will shut down the process on receipt of a message.
/// The default state is empty, and no external messages can be received.
pub fn websocket(request: Request(Connection)) -> WebsocketBuilder(Nil, any) {
  WebsocketBuilder(
    request: request,
    state: Nil,
    handler: fn(_, _, _) { actor.Stop(process.Normal) },
    selector: None,
  )
}

/// Provide an external selector for user-specified messages that the websocket
/// process may receive. These will be provided in the `Custom` type.
pub fn selecting(
  builder: WebsocketBuilder(state, message),
  selector: process.Selector(message),
) -> WebsocketBuilder(state, message) {
  WebsocketBuilder(..builder, selector: Some(selector))
}

/// Adds some initial state to the websocket handler.
pub fn with_state(
  builder: WebsocketBuilder(state, message),
  state: state,
) -> WebsocketBuilder(state, message) {
  WebsocketBuilder(..builder, state: state)
}

/// Provides a function to call for each `WebsocketMessage` received by the
/// process.
pub fn on_message(
  builder: WebsocketBuilder(state, message),
  handler: fn(state, WebsocketConnection, WebsocketMessage(message)) ->
    actor.Next(state),
) -> WebsocketBuilder(state, message) {
  let handler = fn(state, connection, message) {
    message
    |> internal_to_public_ws_message
    |> handler(state, connection, _)
  }
  WebsocketBuilder(builder.request, builder.state, handler, builder.selector)
}

/// Sends a binary frame across the websocket.
pub fn send_binary_frame(
  connection: WebsocketConnection,
  frame: BitString,
) -> Result(Nil, socket.SocketReason) {
  frame
  |> websocket.to_binary_frame
  |> connection.transport.send(connection.socket, _)
}

/// Sends a text frame across the websocket.
pub fn send_text_frame(
  connection: WebsocketConnection,
  frame: BitString,
) -> Result(Nil, socket.SocketReason) {
  frame
  |> websocket.to_text_frame
  |> connection.transport.send(connection.socket, _)
}

/// Upgrade a request to handle websockets. If the request is
/// malformed, or the websocket process fails to initialize, an empty
/// 400 response will be sent to the client.
pub fn upgrade(
  builder: WebsocketBuilder(state, message),
) -> Response(ResponseData) {
  let socket = builder.request.body.socket
  let transport = builder.request.body.transport
  builder.request
  |> http.upgrade(socket, transport, _)
  |> result.then(fn(_nil) {
    websocket.initialize_connection(
      builder.state,
      builder.selector,
      builder.handler,
      socket,
      transport,
    )
  })
  |> result.map(fn(subj) {
    let ws_process = process.subject_owner(subj)
    let monitor = process.monitor_process(ws_process)
    let selector =
      process.new_selector()
      |> process.selecting_process_down(monitor, function.identity)
    response.new(200)
    |> response.set_body(Websocket(selector))
  })
  |> result.lazy_unwrap(fn() {
    response.new(400)
    |> response.set_body(Bytes(bit_builder.new()))
  })
}
