import gleam/bytes_builder.{type BytesBuilder}
import gleam/bit_array
import gleam/erlang/process.{type ProcessDown, type Selector, type Subject}
import gleam/function
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/http.{type Scheme, Http, Https} as gleam_http
import gleam/int
import gleam/io
import gleam/iterator.{type Iterator}
import gleam/option.{type Option, None}
import gleam/otp/actor
import gleam/otp/supervisor
import gleam/result
import glisten
import glisten/socket
import glisten/socket/transport
import mist/internal/buffer.{type Buffer, Buffer}
import mist/internal/file
import mist/internal/handler.{
  type ResponseData as InternalResponseData, Bytes as InternalBytes,
  Chunked as InternalChunked, File as InternalFile,
  Websocket as InternalWebsocket,
}
import mist/internal/http.{type Connection as InternalConnection}
import mist/internal/websocket.{
  type HandlerMessage, type WebsocketConnection as InternalWebsocketConnection,
  BinaryFrame, Data, Internal, TextFrame, User,
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
/// Erlang's `sendfile` to more efficiently return a file to the client.
pub type ResponseData {
  Websocket(Selector(ProcessDown))
  Bytes(BytesBuilder)
  Chunked(Iterator(BytesBuilder))
  /// See `mist.send_file` to use this response type.
  File(descriptor: file.FileDescriptor, offset: Int, length: Int)
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
  socket: socket.Socket,
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
          |> result.then(fn(new_data) {
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
        |> result.then(int.parse)
        |> result.unwrap(0)

      let initial_size = bit_array.byte_size(data)

      let buffer =
        Buffer(data: data, remaining: int.max(0, content_length - initial_size))

      do_stream(req, buffer)
    }
  }
}

pub opaque type Builder(request_body, response_body) {
  Builder(
    port: Int,
    handler: fn(Request(request_body)) -> Response(response_body),
    after_start: fn(Int, Scheme) -> Nil,
  )
}

/// Create a new `mist` handler with a given function. The default port is
/// 4000.
pub fn new(handler: fn(Request(in)) -> Response(out)) -> Builder(in, out) {
  Builder(port: 4000, handler: handler, after_start: fn(port, scheme) {
    let message =
      "Listening on "
      <> gleam_http.scheme_to_string(scheme)
      <> "://localhost:"
      <> int.to_string(port)
    io.println(message)
  })
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
  Builder(builder.port, handler, builder.after_start)
}

/// Override the default function to be called after the service starts. The
/// default is to log a message with the listening port.
pub fn after_start(
  builder: Builder(in, out),
  after_start: fn(Int, Scheme) -> Nil,
) -> Builder(in, out) {
  Builder(..builder, after_start: after_start)
}

fn convert_body_types(
  resp: Response(ResponseData),
) -> Response(InternalResponseData) {
  let new_body = case resp.body {
    Websocket(selector) -> InternalWebsocket(selector)
    Bytes(data) -> InternalBytes(data)
    File(descriptor, offset, length) -> InternalFile(descriptor, offset, length)
    Chunked(iter) -> InternalChunked(iter)
  }
  response.set_body(resp, new_body)
}

/// Start a `mist` service over HTTP with the provided builder.
pub fn start_http(
  builder: Builder(Connection, ResponseData),
) -> Result(Subject(supervisor.Message), glisten.StartError) {
  builder.handler
  fn(req) { convert_body_types(builder.handler(req)) }
  |> handler.with_func
  |> glisten.handler(fn() { #(handler.new_state(), None) }, _)
  |> glisten.serve(builder.port)
  |> result.map(fn(subj) {
    builder.after_start(builder.port, Http)
    subj
  })
}

/// Start a `mist` service over HTTPS with the provided builder. This method
/// requires both a certificate file and a key file. The library will attempt
/// to read these files off of the disk.
pub fn start_https(
  builder: Builder(Connection, ResponseData),
  certfile certfile: String,
  keyfile keyfile: String,
) -> Result(Subject(supervisor.Message), glisten.StartError) {
  fn(req) { convert_body_types(builder.handler(req)) }
  |> handler.with_func
  |> glisten.handler(fn() { #(handler.new_state(), None) }, _)
  |> glisten.serve_ssl(builder.port, certfile, keyfile)
  |> result.map(fn(subj) {
    builder.after_start(builder.port, Https)
    subj
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
  handler handler: fn(state, WebsocketConnection, WebsocketMessage(message)) ->
    actor.Next(message, state),
  on_init on_init: fn(WebsocketConnection) ->
    #(state, Option(process.Selector(message))),
  on_close on_close: fn(state) -> Nil,
) -> Response(ResponseData) {
  let handler = fn(state, connection, message) {
    message
    |> internal_to_public_ws_message
    |> result.map(handler(state, connection, _))
    |> result.unwrap(actor.continue(state))
  }
  let socket = request.body.socket
  let transport = request.body.transport
  request
  |> http.upgrade(socket, transport, _)
  |> result.then(fn(_nil) {
    websocket.initialize_connection(
      on_init,
      on_close,
      handler,
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
    |> response.set_body(Bytes(bytes_builder.new()))
  })
}

pub type WebsocketConnection =
  InternalWebsocketConnection

/// Sends a binary frame across the websocket.
pub fn send_binary_frame(
  connection: WebsocketConnection,
  frame: BitArray,
) -> Result(Nil, socket.SocketReason) {
  frame
  |> websocket.to_binary_frame
  |> connection.transport.send(connection.socket, _)
}

/// Sends a text frame across the websocket.
pub fn send_text_frame(
  connection: WebsocketConnection,
  frame: String,
) -> Result(Nil, socket.SocketReason) {
  frame
  |> websocket.to_text_frame
  |> connection.transport.send(connection.socket, _)
}
