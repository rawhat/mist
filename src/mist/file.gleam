import gleam/erlang/atom.{Atom}
import glisten/tcp.{Socket}

pub external type FileDescriptor

pub type FileMode {
  Raw
}

external fn file_open(
  file: BitString,
  modes: List(FileMode),
) -> Result(FileDescriptor, Atom) =
  "file" "open"

pub external fn size(path: BitString) -> Int =
  "filelib" "file_size"

pub external fn uri_unquote(uri: String) -> String =
  "uri_string" "unquote"

pub external fn sendfile(
  file_descriptor: FileDescriptor,
  socket: Socket,
  offset: Int,
  bytes: Int,
  options: List(a),
) -> Result(Int, Atom) =
  "file" "sendfile"

pub fn open(file: BitString) -> Result(FileDescriptor, Atom) {
  file_open(file, [Raw])
}
