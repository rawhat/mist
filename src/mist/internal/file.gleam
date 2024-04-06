import gleam/bytes_builder
import gleam/result
import glisten.{type Socket, type SocketReason}
import glisten/transport.{type Transport, Ssl, Tcp}

pub type FileDescriptor

pub type FileError {
  IsDir
  NoAccess
  NoEntry
  UnknownFileError
}

pub type SendError {
  FileErr(FileError)
  SocketErr(SocketReason)
}

pub type File {
  File(descriptor: FileDescriptor, file_size: Int)
}

pub fn stat(filename: BitArray) -> Result(File, FileError) {
  filename
  |> open
  |> result.map(fn(fd) {
    let file_size = size(filename)
    File(fd, file_size)
  })
}

pub fn sendfile(
  transport: Transport,
  file_descriptor file_descriptor: FileDescriptor,
  socket socket: Socket,
  offset offset: Int,
  bytes bytes: Int,
  options options: List(a),
) -> Result(Nil, SendError) {
  case transport {
    Tcp(..) -> {
      send_file(file_descriptor, socket, offset, bytes, options)
      |> result.map_error(SocketErr)
      |> result.replace(Nil)
    }
    Ssl(..) as transport -> {
      pread(file_descriptor, offset, bytes)
      |> result.map_error(FileErr)
      |> result.then(fn(bits) {
        transport.send(transport, socket, bytes_builder.from_bit_array(bits))
        |> result.map_error(SocketErr)
      })
    }
  }
}

@external(erlang, "file", "sendfile")
fn send_file(
  file_descriptor file_descriptor: FileDescriptor,
  socket socket: Socket,
  offset offset: Int,
  bytes bytes: Int,
  options options: List(a),
) -> Result(Nil, SocketReason)

@external(erlang, "file", "pread")
fn pread(
  fd: FileDescriptor,
  location: Int,
  bytes: Int,
) -> Result(BitArray, FileError)

@external(erlang, "mist_ffi", "file_open")
pub fn open(file: BitArray) -> Result(FileDescriptor, FileError)

@external(erlang, "filelib", "file_size")
fn size(path: BitArray) -> Int

@external(erlang, "mist_ffi", "file_close")
pub fn close(file: FileDescriptor) -> Result(Nil, FileError)
