import gleam/erlang/atom.{Atom}
import gleam/result
import glisten/socket.{Socket}

pub type FileDescriptor

pub type FileError {
  IsDir
  NoAccess
  NoEntry
  UnknownFileError
}

pub type File {
  File(descriptor: FileDescriptor, file_size: Int)
}

pub fn stat(filename: BitString) -> Result(File, FileError) {
  filename
  |> open
  |> result.map(fn(fd) {
    let file_size = size(filename)
    File(fd, file_size)
  })
}

@external(erlang, "file", "sendfile")
pub fn sendfile(
  file_descriptor file_descriptor: FileDescriptor,
  socket socket: Socket,
  offset offset: Int,
  bytes bytes: Int,
  options options: List(a),
) -> Result(Int, Atom)

@external(erlang, "mist_ffi", "file_open")
fn open(file: BitString) -> Result(FileDescriptor, FileError)

@external(erlang, "filelib", "file_size")
fn size(path: BitString) -> Int
