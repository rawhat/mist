import gleam/bit_string
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/result

pub opaque type StreamIdentifier(phantom) {
  StreamIdentifier(Int)
}

pub fn stream_identifier(value: Int) -> StreamIdentifier(Frame) {
  StreamIdentifier(value)
}

pub type HeaderPriority {
  HeaderPriority(
    exclusive: Bool,
    stream_dependency: StreamIdentifier(Frame),
    weight: Int,
  )
}

pub type Data {
  Complete(BitArray)
  Continued(BitArray)
}

pub type PushState {
  Enabled
  Disabled
}

pub type Setting {
  HeaderTableSize(Int)
  ServerPush(PushState)
  MaxConcurrentStreams(Int)
  InitialWindowSize(Int)
  MaxFrameSize(Int)
  MaxHeaderListSize(Int)
}

pub type Frame {
  Data(data: BitArray, end_stream: Bool, identifier: StreamIdentifier(Frame))

  Header(
    data: Data,
    end_stream: Bool,
    identifier: StreamIdentifier(Frame),
    priority: Option(HeaderPriority),
  )

  Priority(
    exclusive: Bool,
    identifier: StreamIdentifier(Frame),
    stream_dependency: StreamIdentifier(Frame),
    weight: Int,
  )

  Termination(error: ConnectionError, identifier: StreamIdentifier(Frame))

  Settings(
    ack: Bool,
    // These are explicitly not sorted to match the order in the RFC
    settings: List(Setting),
  )

  PushPromise(
    data: Data,
    identifier: StreamIdentifier(Frame),
    promised_stream_id: StreamIdentifier(Frame),
  )

  Ping(ack: Bool, data: BitArray)

  GoAway(
    data: BitArray,
    error: ConnectionError,
    last_stream_id: StreamIdentifier(Frame),
  )

  WindowUpdate(amount: Int, identifier: StreamIdentifier(Frame))

  Continuation(data: Data, identifier: StreamIdentifier(Frame))
}

pub type ConnectionError {
  NoError
  ProtocolError
  InternalError
  FlowControlError
  SettingsTimeout
  StreamClosed
  FrameSizeError
  RefusedStream
  Cancel
  CompressionError
  ConnectError
  EnhanceYourCalm
  InadequateSecurity
  Http11Required
  Unsupported(Int)
}

pub fn decode(frame: BitArray) -> Result(Frame, ConnectionError) {
  io.debug(#("decoding", frame))
  case frame {
    <<length:int-size(24), 0:int-size(8), rest:bits>> ->
      parse_data(length, rest)
    <<length:int-size(24), 1:int-size(8), rest:bits>> ->
      parse_header(length, rest)
    <<length:int-size(24), 2:int-size(8), rest:bits>> ->
      parse_priority(length, rest)
    <<length:int-size(24), 3:int-size(8), rest:bits>> ->
      parse_termination(length, rest)
    <<length:int-size(24), 4:int-size(8), rest:bits>> ->
      parse_settings(length, rest)
    <<length:int-size(24), 5:int-size(8), rest:bits>> ->
      parse_push_promise(length, rest)
    <<length:int-size(24), 6:int-size(8), rest:bits>> ->
      parse_ping(length, rest)
    <<length:int-size(24), 7:int-size(8), rest:bits>> ->
      parse_go_away(length, rest)
    <<length:int-size(24), 8:int-size(8), rest:bits>> ->
      parse_window_update(length, rest)
    <<length:int-size(24), 9:int-size(8), rest:bits>> ->
      parse_continuation(length, rest)
  }
}

fn parse_data(length: Int, rest: BitArray) -> Result(Frame, ConnectionError) {
  io.println("parsing data")
  case rest {
    <<
      _unused:int-size(4),
      0:int-size(1),
      _unused:int-size(2),
      end_stream:int-size(1),
      _reserved:int-size(1),
      identifier:int-size(31),
      data:bytes-size(length),
    >> if identifier != 0 -> {
      Ok(Data(
        data: data,
        end_stream: end_stream
        == 1,
        identifier: stream_identifier(identifier),
      ))
    }
    <<
      _unused:int-size(4),
      1:int-size(1),
      _unused:int-size(2),
      end_stream:int-size(1),
      _reserved:int-size(1),
      identifier:int-size(31),
      pad_length:int-size(8),
      data:bytes-size(length),
      _padding:bytes-size(pad_length),
    >> if identifier != 0 && pad_length < length -> {
      Ok(Data(
        data: data,
        end_stream: end_stream
        == 1,
        identifier: stream_identifier(identifier),
      ))
    }
    _ -> Error(ProtocolError)
  }
}

fn parse_header(length: Int, rest: BitArray) -> Result(Frame, ConnectionError) {
  io.println("parsing header")
  case rest {
    <<
      _unused:int-size(2),
      priority:int-size(1),
      _unused:int-size(1),
      padded:int-size(1),
      end_headers:int-size(1),
      _unused:int-size(1),
      end_stream:int-size(1),
      _reserved:int-size(1),
      identifier:int-size(31),
      pad_length:int-size(padded)-unit(8),
      exclusive:int-size(priority),
      stream_dependency:int-size(priority)-unit(31),
      weight:int-size(priority)-unit(8),
      data:bytes-size(length),
      _padding:bytes-size(pad_length),
    >> if identifier != 0 && pad_length < length -> {
      Ok(
        Header(
          data: case end_headers {
            1 -> Complete(data)
            0 -> Continued(data)
          },
          end_stream: end_stream
          == 1,
          identifier: stream_identifier(identifier),
          priority: case priority == 1 {
            True ->
              Some(HeaderPriority(
                exclusive: exclusive
                == 1,
                stream_dependency: stream_identifier(stream_dependency),
                weight: weight,
              ))
            False -> None
          },
        ),
      )
    }
    _ -> Error(ProtocolError)
  }
}

fn parse_priority(length: Int, rest: BitArray) -> Result(Frame, ConnectionError) {
  io.println("parsing priority")
  case length, rest {
    5, <<
      _unused:int-size(8),
      _reserved:int-size(1),
      identifier:int-size(31),
      exclusive:int-size(1),
      dependency:int-size(31),
      weight:int-size(8),
    >> if identifier != 0 -> {
      Ok(Priority(
        exclusive: exclusive
        == 1,
        identifier: stream_identifier(identifier),
        stream_dependency: stream_identifier(dependency),
        weight: weight,
      ))
    }
    5, _ -> Error(ProtocolError)
    _, _ -> Error(FrameSizeError)
  }
}

fn parse_termination(
  length: Int,
  rest: BitArray,
) -> Result(Frame, ConnectionError) {
  io.println("parsing rst")
  case length, rest {
    4, <<
      _unused:int-size(8),
      _reserved:int-size(1),
      identifier:int-size(31),
      error:int-size(32),
    >> if identifier != 0 -> {
      Ok(Termination(
        error: get_error(error),
        identifier: stream_identifier(identifier),
      ))
    }
    4, _ -> Error(ProtocolError)
    _, _ -> Error(FrameSizeError)
  }
}

fn parse_settings(length: Int, rest: BitArray) -> Result(Frame, ConnectionError) {
  let assert <<
    _unused:int-size(7),
    ack:int-size(1),
    _reserved:int-size(1),
    identifier:int-size(31),
    rest:bits,
  >> = rest
  io.debug(#(
    "ack?",
    ack,
    "identifier?",
    identifier,
    "rest",
    rest,
    "length",
    length,
  ))
  case length % 6, rest {
    0, <<
      _unused:int-size(7),
      ack:int-size(1),
      _reserved:int-size(1),
      0:int-size(31),
      settings:bytes-size(length),
      _rest:bits,
    >> -> {
      io.println("hi mom")
      use settings <- result.try(get_settings(settings, []))
      Ok(Settings(ack: ack == 1, settings: settings))
    }

    0, _ -> Error(ProtocolError)
    _, _ -> Error(FrameSizeError)
  }
}

fn parse_push_promise(
  length: Int,
  rest: BitArray,
) -> Result(Frame, ConnectionError) {
  io.println("parsing push promise")
  case rest {
    <<
      _unused:int-size(4),
      padded:int-size(1),
      end_headers:int-size(1),
      _unused:int-size(2),
      _reserved:int-size(1),
      identifier:int-size(31),
      pad_length:int-size(padded)-unit(8),
      _reserved:int-size(1),
      promised_identifier:int-size(31),
      data:bytes-size(length),
      _padding:bytes-size(pad_length),
    >> if identifier != 0 -> {
      Ok(PushPromise(
        data: case end_headers == 1 {
          True -> Complete(data)
          False -> Continued(data)
        },
        identifier: stream_identifier(identifier),
        promised_stream_id: stream_identifier(promised_identifier),
      ))
    }
    _ -> Error(ProtocolError)
  }
}

fn parse_ping(length: Int, rest: BitArray) -> Result(Frame, ConnectionError) {
  io.println("parsing ping")
  case length, rest {
    8, <<
      _unused:int-size(7),
      ack:int-size(1),
      _reserved:int-size(1),
      0:int-size(31),
      data:bits-size(64),
    >> -> {
      Ok(Ping(ack: ack == 1, data: data))
    }
    8, _ -> Error(ProtocolError)
    _, _ -> Error(FrameSizeError)
  }
}

fn parse_go_away(length: Int, rest: BitArray) -> Result(Frame, ConnectionError) {
  io.println("parsing go away")
  case rest {
    <<
      _unused:int-size(8),
      _reserved:int-size(1),
      0:int-size(31),
      _reserved:int-size(1),
      last_stream_id:int-size(31),
      error:int-size(32),
      data:bytes-size(length),
    >> -> {
      Ok(GoAway(
        data: data,
        error: get_error(error),
        last_stream_id: stream_identifier(last_stream_id),
      ))
    }
    _ -> Error(ProtocolError)
  }
}

fn parse_window_update(
  length: Int,
  rest: BitArray,
) -> Result(Frame, ConnectionError) {
  io.println("parsing window update")
  case length, rest {
    4, <<
      _unused:int-size(8),
      _reserved:int-size(1),
      identifier:int-size(31),
      _reserved:int-size(1),
      window_size:int-size(31),
    >> if window_size != 0 -> {
      Ok(WindowUpdate(
        amount: window_size,
        identifier: stream_identifier(identifier),
      ))
    }
    4, _ -> Error(FrameSizeError)
    _, _ -> Error(ProtocolError)
  }
}

fn parse_continuation(
  length: Int,
  rest: BitArray,
) -> Result(Frame, ConnectionError) {
  io.println("parsing continuation")
  case rest {
    <<
      _unused:int-size(5),
      end_headers:int-size(1),
      _unused:int-size(2),
      _reserved:int-size(1),
      identifier:int-size(31),
      data:bytes-size(length),
    >> if identifier != 0 -> {
      Ok(Continuation(
        data: case end_headers == 1 {
          True -> Complete(data)
          False -> Continued(data)
        },
        identifier: stream_identifier(identifier),
      ))
    }
  }
}

pub fn encode(frame: Frame) -> BitArray {
  todo
}

fn get_error(value: Int) -> ConnectionError {
  case value {
    0 -> NoError
    1 -> ProtocolError
    2 -> InternalError
    3 -> FlowControlError
    4 -> SettingsTimeout
    5 -> StreamClosed
    6 -> FrameSizeError
    7 -> RefusedStream
    8 -> Cancel
    9 -> CompressionError
    10 -> ConnectError
    11 -> EnhanceYourCalm
    12 -> InadequateSecurity
    13 -> Http11Required
  }
}

fn get_settings(
  data: BitArray,
  acc: List(Setting),
) -> Result(List(Setting), ConnectionError) {
  case data {
    <<>> -> Ok(acc)
    <<identifier:int-size(16), value:int-size(32), rest:bits>> -> {
      case get_setting(identifier, value) {
        Ok(setting) -> get_settings(rest, [setting, ..acc])
        Error(err) -> Error(err)
      }
    }
  }
}

fn get_setting(identifier: Int, value: Int) -> Result(Setting, ConnectionError) {
  case identifier {
    1 -> Ok(HeaderTableSize(value))
    2 ->
      Ok(
        ServerPush(case value {
          0 -> Disabled
          1 -> Enabled
        }),
      )
    3 -> Ok(MaxConcurrentStreams(value))
    4 -> {
      case value {
        n if n > 2_147_483_647 -> Error(FlowControlError)
        _ -> Ok(InitialWindowSize(value))
      }
    }
    5 -> {
      case value {
        n if n > 16_777_215 -> Error(ProtocolError)
        _ -> Ok(MaxFrameSize(value))
      }
    }
    6 -> Ok(MaxHeaderListSize(value))
  }
}
