import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Down, type Selector, type Subject}
import gleam/function
import gleam/http.{type Scheme, Http, Https} as gleam_http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}
import gleam/yielder.{type Yielder}
import glisten
import glisten/transport
import gramps/websocket.{BinaryFrame, Data, TextFrame} as gramps_websocket
import logging
import mist/internal/buffer.{type Buffer, Buffer}
import mist/internal/encoder
import mist/internal/file
import mist/internal/handler
import mist/internal/http.{
  type Connection as InternalConnection,
  type ResponseData as InternalResponseData, Bytes as InternalBytes,
  Chunked as InternalChunked, File as InternalFile,
  ServerSentEvents as InternalServerSentEvents, Websocket as InternalWebsocket,
}
import mist/internal/next
import mist/internal/websocket.{
  type HandlerMessage, type WebsocketConnection as InternalWebsocketConnection,
  Internal, User,
}

@external(erlang, "mist_ffi", "rescue")
fn rescue(func: fn() -> return) -> Result(return, Nil)

/// Re-exported type that represents the default `Request` body type. See
/// `mist.read_body` to convert this type into a `BitString`. The `Connection`
/// also holds some additional information about the request. Currently, the
/// only useful field is `client_ip` which is a `Result` with a tuple of
/// integers representing the IPv4 address.
pub type Connection =
  InternalConnection

pub opaque type Next(state, user_message) {
  Continue(state, Option(Selector(user_message)))
  NormalStop
  AbnormalStop(reason: String)
}

pub fn continue(state: state) -> Next(state, user_message) {
  Continue(state, None)
}

pub fn with_selector(
  next: Next(state, user_message),
  selector: Selector(user_message),
) -> Next(state, user_message) {
  case next {
    Continue(state, _) -> Continue(state, Some(selector))
    _ -> next
  }
}

pub fn stop() -> Next(state, user_message) {
  NormalStop
}

pub fn stop_abnormal(reason: String) -> Next(state, user_message) {
  AbnormalStop(reason)
}

fn convert_next(
  next: Next(state, user_message),
) -> next.Next(state, user_message) {
  case next {
    Continue(state, selector) -> next.Continue(state, selector)
    NormalStop -> next.NormalStop
    AbnormalStop(reason) -> next.AbnormalStop(reason)
  }
}

/// When accessing client information, these are the possible shapes of the IP
/// addresses. A best effort will be made to determine whether IPv4 is most
/// relevant.
pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// Convenience function for printing the `IpAddress` type. It will convert the
/// IPv6 loopback to the short-hand `::1`.
pub fn ip_address_to_string(address: IpAddress) -> String {
  glisten.ip_address_to_string(to_glisten_ip_address(address))
}

fn to_mist_ip_address(ip: glisten.IpAddress) -> IpAddress {
  case ip {
    glisten.IpV4(a, b, c, d) -> IpV4(a, b, c, d)
    glisten.IpV6(a, b, c, d, e, f, g, h) -> IpV6(a, b, c, d, e, f, g, h)
  }
}

fn to_glisten_ip_address(ip: IpAddress) -> glisten.IpAddress {
  case ip {
    IpV4(a, b, c, d) -> glisten.IpV4(a, b, c, d)
    IpV6(a, b, c, d, e, f, g, h) -> glisten.IpV6(a, b, c, d, e, f, g, h)
  }
}

pub type ConnectionInfo {
  ConnectionInfo(port: Int, ip_address: IpAddress)
}

/// Tries to get the IP address and port of a connected client.
pub fn get_client_info(conn: Connection) -> Result(ConnectionInfo, Nil) {
  transport.peername(conn.transport, conn.socket)
  |> result.map(fn(pair) {
    ConnectionInfo(
      ip_address: pair.0
        |> glisten.convert_ip_address
        |> to_mist_ip_address,
      port: pair.1,
    )
  })
}

/// The response body type. This allows `mist` to handle these different cases
/// for you. `Bytes` is the regular data return. `Websocket` will upgrade the
/// socket to websockets, but should not be used directly. See the
/// `mist.upgrade` function for usage. `Chunked` will use
/// `Transfer-Encoding: chunked` to send an iterator in chunks. `File` will use
/// Erlang's `sendfile` to more efficiently return a file to the client.
pub type ResponseData {
  Websocket(Selector(Down))
  Bytes(BytesTree)
  Chunked(Yielder(BytesTree))
  /// See `mist.send_file` to use this response type.
  File(descriptor: file.FileDescriptor, offset: Int, length: Int)
  ServerSentEvents(Selector(Down))
}

/// Potential errors when opening a file to send. This list is
/// currently not exhaustive with POSIX errors.
pub type FileError {
  IsDir
  NoAccess
  NoEntry
  UnknownFileError
}

fn convert_file_errors(err: file.FileError) -> FileError {
  case err {
    file.IsDir -> IsDir
    file.NoAccess -> NoAccess
    file.NoEntry -> NoEntry
    file.UnknownFileError -> UnknownFileError
  }
}

/// To respond with a file using Erlang's `sendfile`, use this function
/// with the specified offset and limit (optional). It will attempt to open the
/// file for reading, get its file size, and then send the file.  If the read
/// errors, this will return the relevant `FileError`. Generally, this will be
/// more memory efficient than manually doing this process with `mist.Bytes`.
pub fn send_file(
  path: String,
  offset offset: Int,
  limit limit: Option(Int),
) -> Result(ResponseData, FileError) {
  path
  |> bit_array.from_string
  |> file.stat
  |> result.map_error(convert_file_errors)
  |> result.map(fn(stat) {
    File(
      descriptor: stat.descriptor,
      offset: offset,
      length: option.unwrap(limit, stat.file_size),
    )
  })
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
) -> Result(Request(BitArray), ReadError) {
  req
  |> request.get_header("content-length")
  |> result.try(int.parse)
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

/// The values returning from streaming the request body. The `Chunk`
/// variant gives back some data and the next token. `Done` signifies
/// that we have completed reading the body.
pub type Chunk {
  Chunk(data: BitArray, consume: fn(Int) -> Result(Chunk, ReadError))
  Done
}

fn do_stream(
  req: Request(Connection),
  buffer: Buffer,
) -> fn(Int) -> Result(Chunk, ReadError) {
  fn(size) {
    let socket = req.body.socket
    let transport = req.body.transport
    let byte_size = bit_array.byte_size(buffer.data)

    case buffer.remaining, byte_size {
      0, 0 -> Ok(Done)

      0, _buffer_size -> {
        let #(data, rest) = buffer.slice(buffer, size)
        Ok(Chunk(data, do_stream(req, buffer.new(rest))))
      }

      _, buffer_size if buffer_size >= size -> {
        let #(data, rest) = buffer.slice(buffer, size)
        let new_buffer = Buffer(..buffer, data: rest)
        Ok(Chunk(data, do_stream(req, new_buffer)))
      }

      _, _buffer_size -> {
        http.read_data(socket, transport, buffer.empty(), http.InvalidBody)
        |> result.replace_error(MalformedBody)
        |> result.map(fn(data) {
          let fetched_data = bit_array.byte_size(data)
          let new_buffer =
            Buffer(
              data: bit_array.append(buffer.data, data),
              remaining: int.max(0, buffer.remaining - fetched_data),
            )
          let #(new_data, rest) = buffer.slice(new_buffer, size)
          Chunk(new_data, do_stream(req, Buffer(..new_buffer, data: rest)))
        })
      }
    }
  }
}

type ChunkState {
  ChunkState(data_buffer: Buffer, chunk_buffer: Buffer, done: Bool)
}

fn do_stream_chunked(
  req: Request(Connection),
  state: ChunkState,
) -> fn(Int) -> Result(Chunk, ReadError) {
  let socket = req.body.socket
  let transport = req.body.transport

  fn(size) {
    case fetch_chunks_until(socket, transport, state, size) {
      Ok(#(data, ChunkState(done: True, ..))) -> {
        Ok(Chunk(data, fn(_size) { Ok(Done) }))
      }
      Ok(#(data, state)) -> {
        Ok(Chunk(data, do_stream_chunked(req, state)))
      }
      Error(_) -> Error(MalformedBody)
    }
  }
}

fn fetch_chunks_until(
  socket: glisten.Socket,
  transport: transport.Transport,
  state: ChunkState,
  byte_size: Int,
) -> Result(#(BitArray, ChunkState), ReadError) {
  let data_size = bit_array.byte_size(state.data_buffer.data)
  case state.done, data_size {
    _, size if size >= byte_size -> {
      let #(value, rest) = buffer.slice(state.data_buffer, byte_size)
      Ok(#(value, ChunkState(..state, data_buffer: buffer.new(rest))))
    }

    True, _ -> {
      Ok(#(state.data_buffer.data, ChunkState(..state, done: True)))
    }

    False, _ -> {
      case http.parse_chunk(state.chunk_buffer.data) {
        http.Complete -> {
          let updated_state =
            ChunkState(..state, chunk_buffer: buffer.empty(), done: True)
          fetch_chunks_until(socket, transport, updated_state, byte_size)
        }
        http.Chunk(<<>>, next_buffer) -> {
          http.read_data(socket, transport, next_buffer, http.InvalidBody)
          |> result.replace_error(MalformedBody)
          |> result.try(fn(new_data) {
            let updated_state =
              ChunkState(..state, chunk_buffer: buffer.new(new_data))
            fetch_chunks_until(socket, transport, updated_state, byte_size)
          })
        }
        http.Chunk(data, next_buffer) -> {
          let updated_state =
            ChunkState(
              ..state,
              data_buffer: buffer.append(state.data_buffer, data),
              chunk_buffer: next_buffer,
            )
          fetch_chunks_until(socket, transport, updated_state, byte_size)
        }
      }
    }
  }
}

/// Rather than explicitly reading either the whole body (optionally up to
/// `N` bytes), this function allows you to consume a stream of the request
/// body. Any errors reading the body will propagate out, or `Chunk`s will be
/// emitted. This provides a `consume` method to attempt to grab the next
/// `size` chunk from the socket.
pub fn stream(
  req: Request(Connection),
) -> Result(fn(Int) -> Result(Chunk, ReadError), ReadError) {
  let continue =
    req
    |> http.handle_continue
    |> result.replace_error(MalformedBody)

  use _nil <- result.map(continue)

  let is_chunked = case request.get_header(req, "transfer-encoding") {
    Ok("chunked") -> True
    _ -> False
  }

  let assert http.Initial(data) = req.body.body

  case is_chunked {
    True -> {
      let state = ChunkState(buffer.new(<<>>), buffer.new(data), False)
      do_stream_chunked(req, state)
    }
    False -> {
      let content_length =
        req
        |> request.get_header("content-length")
        |> result.try(int.parse)
        |> result.unwrap(0)

      let initial_size = bit_array.byte_size(data)

      let buffer =
        Buffer(data: data, remaining: int.max(0, content_length - initial_size))

      do_stream(req, buffer)
    }
  }
}

type TlsOptions {
  CertKeyFiles(certfile: String, keyfile: String)
}

pub opaque type Builder(request_body, response_body) {
  Builder(
    port: Int,
    handler: fn(Request(request_body)) -> Response(response_body),
    after_start: fn(Int, Scheme, IpAddress) -> Nil,
    interface: String,
    ipv6_support: Bool,
    tls_options: Option(TlsOptions),
  )
}

/// Create a new `mist` handler with a given function. The default port is
/// 4000.
pub fn new(handler: fn(Request(in)) -> Response(out)) -> Builder(in, out) {
  Builder(
    port: 4000,
    handler: handler,
    interface: "localhost",
    ipv6_support: False,
    after_start: fn(port, scheme, interface) {
      let address = case interface {
        IpV6(..) -> "[" <> ip_address_to_string(interface) <> "]"
        _ -> ip_address_to_string(interface)
      }
      let message =
        "Listening on "
        <> gleam_http.scheme_to_string(scheme)
        <> "://"
        <> address
        <> ":"
        <> int.to_string(port)
      io.println(message)
    },
    tls_options: None,
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
  builder: Builder(BitArray, out),
  bytes_limit bytes_limit: Int,
  failure_response failure_response: Response(out),
) -> Builder(Connection, out) {
  let handler = fn(request) {
    case read_body(request, bytes_limit) {
      Ok(request) -> builder.handler(request)
      Error(_) -> failure_response
    }
  }
  Builder(..builder, handler:)
}

/// Override the default function to be called after the service starts. The
/// default is to log a message with the listening port.
pub fn after_start(
  builder: Builder(in, out),
  after_start: fn(Int, Scheme, IpAddress) -> Nil,
) -> Builder(in, out) {
  Builder(..builder, after_start: after_start)
}

/// Specify an interface to listen on. This is a string that can have the
/// following values: "localhost", a valid IPv4 address (i.e. "127.0.0.1"), or
/// a valid IPv6 address (i.e. "::1"). An invalid value will cause the
/// application to crash.
pub fn bind(builder: Builder(in, out), interface: String) -> Builder(in, out) {
  Builder(..builder, interface: interface)
}

/// By default, `mist` will listen on `localhost` over IPv4. If you specify an
/// IPv4 address to bind to, it will still only serve over IPv4. Calling this
/// function will listen on both IPv4 and IPv6 for the given interface. If it is
/// not supported, your application will crash. If you provide an IPv6 address
/// to `mist.bind`, this function will have no effect.
pub fn with_ipv6(builder: Builder(in, out)) -> Builder(in, out) {
  Builder(..builder, ipv6_support: True)
}

/// Use HTTPS with the provided certificate and key files.
pub fn with_tls(
  builder: Builder(in, out),
  certfile cert: String,
  keyfile key: String,
) -> Builder(in, out) {
  let certfile = file.open(bit_array.from_string(cert))
  let keyfile = file.open(bit_array.from_string(key))

  let _ = case certfile, keyfile {
    Error(_), Error(_) -> panic as "Certificate and key file not found"
    Ok(_), Error(_) -> panic as "Key file not found"
    Error(_), Ok(_) -> panic as "Certificate file not found"
    Ok(_), Ok(_) -> Nil
  }

  Builder(..builder, tls_options: Some(CertKeyFiles(cert, key)))
}

fn convert_body_types(
  resp: Response(ResponseData),
) -> Response(InternalResponseData) {
  let new_body = case resp.body {
    Websocket(selector) -> InternalWebsocket(selector)
    Bytes(data) -> InternalBytes(data)
    File(descriptor, offset, length) -> InternalFile(descriptor, offset, length)
    Chunked(iter) -> InternalChunked(iter)
    ServerSentEvents(selector) -> InternalServerSentEvents(selector)
  }
  response.set_body(resp, new_body)
}

pub type Port {
  Assigned
  Provided(Int)
}

/// Start a `mist` service with the provided builder.
pub fn start(
  builder: Builder(Connection, ResponseData),
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  let listener_name = process.new_name("glisten_listener")
  fn(req) { convert_body_types(builder.handler(req)) }
  |> handler.with_func
  |> glisten.new(handler.init, _)
  |> glisten.bind(builder.interface)
  |> fn(handler) {
    case builder.ipv6_support {
      True -> glisten.with_ipv6(handler)
      False -> handler
    }
  }
  |> fn(handler) {
    case builder.tls_options {
      Some(CertKeyFiles(certfile, keyfile)) ->
        handler
        |> glisten.with_tls(certfile, keyfile)
      _ -> handler
    }
  }
  |> glisten.start_with_listener_name(builder.port, listener_name)
  |> result.map(fn(server) {
    let info = glisten.get_server_info(listener_name, 5000)
    let ip_address = to_mist_ip_address(info.ip_address)
    let scheme = case option.is_some(builder.tls_options) {
      True -> Https
      False -> Http
    }
    builder.after_start(info.port, scheme, ip_address)
    server
  })
}

/// These are the types of messages that a websocket handler may receive.
pub type WebsocketMessage(custom) {
  Text(String)
  Binary(BitArray)
  Closed
  Shutdown
  Custom(custom)
}

fn internal_to_public_ws_message(
  msg: HandlerMessage(custom),
) -> Result(WebsocketMessage(custom), Nil) {
  case msg {
    Internal(Data(TextFrame(_length, data))) -> {
      data
      |> bit_array.to_string
      |> result.map(Text)
    }
    Internal(Data(BinaryFrame(_length, data))) -> Ok(Binary(data))
    User(msg) -> Ok(Custom(msg))
    _ -> Error(Nil)
  }
}

/// Upgrade a request to handle websockets. If the request is
/// malformed, or the websocket process fails to initialize, an empty
/// 400 response will be sent to the client.
///
/// The `on_init` method will be called when the actual WebSocket process
/// is started, and the return value is the initial state and an optional
/// selector for receiving user messages.
///
/// The `on_close` method is called when the WebSocket process shuts down
/// for any reason, valid or otherwise.
pub fn websocket(
  request request: Request(Connection),
  handler handler: fn(state, WebsocketMessage(message), WebsocketConnection) ->
    Next(state, message),
  on_init on_init: fn(WebsocketConnection) ->
    #(state, Option(process.Selector(message))),
  on_close on_close: fn(state) -> Nil,
) -> Response(ResponseData) {
  let handler = fn(state, message, connection) {
    message
    |> internal_to_public_ws_message
    |> result.map(handler(state, _, connection))
    |> result.unwrap(continue(state))
    |> convert_next
  }
  let extensions =
    request
    |> request.get_header("sec-websocket-extensions")
    |> result.map(fn(header) { string.split(header, ";") })
    |> result.unwrap([])

  let socket = request.body.socket
  let transport = request.body.transport
  request
  |> http.upgrade(socket, transport, extensions, _)
  |> result.try(fn(_nil) {
    websocket.initialize_connection(
      on_init,
      on_close,
      handler,
      socket,
      transport,
      extensions,
    )
  })
  |> result.map(fn(subj) {
    let assert Ok(ws_process) = process.subject_owner(subj.data)
    let monitor = process.monitor(ws_process)
    let selector =
      process.new_selector()
      |> process.select_specific_monitor(monitor, function.identity)
    response.new(200)
    |> response.set_body(Websocket(selector))
  })
  |> result.lazy_unwrap(fn() {
    response.new(400)
    |> response.set_body(Bytes(bytes_tree.new()))
  })
}

pub type WebsocketConnection =
  InternalWebsocketConnection

/// Sends a binary frame across the websocket.
pub fn send_binary_frame(
  connection: WebsocketConnection,
  frame: BitArray,
) -> Result(Nil, glisten.SocketReason) {
  let binary_frame =
    rescue(fn() {
      gramps_websocket.to_binary_frame(frame, connection.deflate, None)
    })
  case binary_frame {
    Ok(binary_frame) -> {
      transport.send(connection.transport, connection.socket, binary_frame)
    }
    Error(reason) -> {
      logging.log(
        logging.Error,
        "Cannot send messages from a different process than the WebSocket: "
          <> string.inspect(reason),
      )
      panic as "Exiting due to sending WebSocket message from non-owning process"
    }
  }
}

/// Sends a text frame across the websocket.
pub fn send_text_frame(
  connection: WebsocketConnection,
  frame: String,
) -> Result(Nil, glisten.SocketReason) {
  let text_frame =
    rescue(fn() {
      gramps_websocket.to_text_frame(frame, connection.deflate, None)
    })
  case text_frame {
    Ok(text_frame) -> {
      transport.send(connection.transport, connection.socket, text_frame)
    }
    Error(reason) -> {
      logging.log(
        logging.Error,
        "Cannot send messages from a different process than the WebSocket: "
          <> string.inspect(reason),
      )
      panic as "Exiting due to sending WebSocket message from non-owning process"
    }
  }
}

// Returned by `init_server_sent_events`. This type must be passed to
// `send_event` since we need to enforce that the correct headers / data shapw
// is provided.
pub opaque type SSEConnection {
  SSEConnection(Connection)
}

// Represents each event.  Only `data` is required.  The `event` name will
// default to `message`.  If an `id` is provided, it will be included in the
// event received by the client. `retry` is the minimum time in milliseconds 
// the client needs to wait before trying to reestablish the connection.
pub opaque type SSEEvent {
  SSEEvent(
    id: Option(String),
    event: Option(String),
    retry: Option(Int),
    data: StringTree,
  )
}

// Builder for generating the base event
pub fn event(data: StringTree) -> SSEEvent {
  SSEEvent(id: None, event: None, retry: None, data: data)
}

// Adds an `id` to the event
pub fn event_id(event: SSEEvent, id: String) -> SSEEvent {
  SSEEvent(..event, id: Some(id))
}

// Sets the `event` name field
pub fn event_name(event: SSEEvent, name: String) -> SSEEvent {
  SSEEvent(..event, event: Some(name))
}

// Sets the `retry` reconnection time field in milliseconds
pub fn event_retry(event: SSEEvent, retry: Int) -> SSEEvent {
  SSEEvent(..event, retry: Some(retry))
}

/// Sets up the connection for server-sent events. The initial response provided
/// here will have its headers included in the SSE setup. The body is discarded.
/// The `init` and `loop` parameters follow the same shape as the
/// `gleam/otp/actor` module.
///
/// NOTE:  There is no proper way within the spec for the server to "close" the
/// SSE connection. There are ways around it.
///
/// See:  `examples/eventz` for a sample usage.
pub fn server_sent_events(
  request req: Request(Connection),
  initial_response resp: Response(discard),
  init init: fn(Subject(message)) ->
    Result(actor.Initialised(state, message, data), String),
  loop loop: fn(state, message, SSEConnection) -> actor.Next(state, message),
) -> Response(ResponseData) {
  let with_default_headers =
    resp
    |> response.set_header("content-type", "text/event-stream")
    |> response.set_header("cache-control", "no-cache")
    |> response.set_header("connection", "keep-alive")

  transport.send(
    req.body.transport,
    req.body.socket,
    encoder.response_builder(200, with_default_headers.headers, "1.1"),
  )
  |> result.replace_error(Nil)
  |> result.try(fn(_nil) {
    actor.new_with_initialiser(1000, fn(subj) {
      init(subj)
      |> result.map(fn(return) { actor.returning(return, subj) })
    })
    |> actor.on_message(fn(state, message) {
      loop(state, message, SSEConnection(req.body))
    })
    |> actor.start
    |> result.replace_error(Nil)
  })
  |> result.map(fn(subj) {
    let assert Ok(sse_process) = process.subject_owner(subj.data)
    let monitor = process.monitor(sse_process)
    let selector =
      process.new_selector()
      |> process.select_specific_monitor(monitor, function.identity)
    response.new(200)
    |> response.set_body(ServerSentEvents(selector))
  })
  |> result.lazy_unwrap(fn() {
    response.new(400)
    |> response.set_body(Bytes(bytes_tree.new()))
  })
}

// This constructs an event from the provided type.  If `id`, `event` or `retry` are
// provided, they are included in the message.  The data provided is split
// across newlines, which I think is per the spec? The `Result` returned here
// can be used to determine whether the event send has succeeded.
pub fn send_event(conn: SSEConnection, event: SSEEvent) -> Result(Nil, Nil) {
  let SSEConnection(conn) = conn
  let id =
    event.id
    |> option.map(fn(id) { "id: " <> id <> "\n" })
    |> option.unwrap("")
  let event_name =
    event.event
    |> option.map(fn(name) { "event: " <> name <> "\n" })
    |> option.unwrap("")
  let retry =
    event.retry
    |> option.map(fn(retry) { "retry: " <> int.to_string(retry) <> "\n" })
    |> option.unwrap("")
  let data =
    event.data
    |> string_tree.split("\n")
    |> list.map(fn(row) { string_tree.prepend(row, "data: ") })
    |> string_tree.join("\n")

  let message =
    data
    |> string_tree.prepend(event_name)
    |> string_tree.prepend(id)
    |> string_tree.prepend(retry)
    |> string_tree.append("\n\n")
    |> bytes_tree.from_string_tree

  transport.send(conn.transport, conn.socket, message)
  |> result.replace(Nil)
  |> result.replace_error(Nil)
}
