import gleam/erlang/atom.{Atom}
import glisten/socket.{Socket}

pub type FileDescriptor

@external(erlang, "file", "sendfile")
pub fn sendfile(
  file_descriptor file_descriptor: FileDescriptor,
  socket socket: Socket,
  offset offset: Int,
  bytes bytes: Int,
  options options: List(a),
) -> Result(Int, Atom)
