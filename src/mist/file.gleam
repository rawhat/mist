import mist/internal/file.{FileDescriptor}

/// Get the file size from a path. Returns `0` if the path
/// does not exist.
@external(erlang, "filelib", "file_size")
pub fn size(path: BitString) -> Int

/// Errors returned from attempting to open a file.
pub type FileError {
  IsDir
  NoAccess
  NoEntry
  UnknownFileError
}

/// Attemps to open a file at the given path. Returns a `FileDescriptor`
/// to use with the `mist.File` response type.
@external(erlang, "mist_ffi", "file_open")
pub fn open(file: BitString) -> Result(FileDescriptor, FileError)
