import gleam/erlang/atom.{Atom}
import glisten/socket.{Socket}

pub type FileDescriptor

@external(erlang, "filelib", "file_size")
pub fn size(path path: BitString) -> Int

@external(erlang, "file", "sendfile")
pub fn sendfile(
  file_descriptor file_descriptor: FileDescriptor,
  socket socket: Socket,
  offset offset: Int,
  bytes bytes: Int,
  options options: List(a),
) -> Result(Int, Atom)

pub type FileError {
  IsDir
  NoAccess
  NoEntry
  UnknownFileError
}

@external(erlang, "mist_ffi", "file_open")
pub fn open(file: BitString) -> Result(FileDescriptor, FileError)
