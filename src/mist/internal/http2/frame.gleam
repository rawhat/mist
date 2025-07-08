import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import logging

pub opaque type StreamIdentifier(phantom) {
  StreamIdentifier(Int)
}

pub fn stream_identifier(value: Int) -> StreamIdentifier(Frame) {
  StreamIdentifier(value)
}

pub fn get_stream_identifier(identifier: StreamIdentifier(phantom)) -> Int {
  let StreamIdentifier(value) = identifier
  value
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

  Settings(ack: Bool, settings: List(Setting))

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

pub fn decode(frame: BitArray) -> Result(#(Frame, BitArray), ConnectionError) {
  case frame {
    <<
      length:size(24),
      frame_type:size(8),
      flags:bits-size(8),
      _reserved:size(1),
      identifier:size(31),
      payload:bytes-size(length),
      rest:bits,
    >> -> {
      case frame_type {
        0 -> parse_data(identifier, flags, length, payload)
        1 -> parse_header(identifier, flags, length, payload)
        2 -> parse_priority(identifier, flags, length, payload)
        3 -> parse_termination(identifier, flags, length, payload)
        4 -> parse_settings(identifier, flags, length, payload)
        5 -> parse_push_promise(identifier, flags, length, payload)
        6 -> parse_ping(identifier, flags, length, payload)
        7 -> parse_go_away(identifier, flags, length, payload)
        8 -> parse_window_update(identifier, flags, length, payload)
        9 -> parse_continuation(identifier, flags, length, payload)
        _ -> Error(ProtocolError)
      }
      |> result.map(fn(frame) { #(frame, rest) })
    }
    <<
      length:size(24),
      _frame_type:size(8),
      _flags:size(8),
      _reserved:size(1),
      _identifier:size(31),
      rest:bits,
    >> -> {
      case bit_array.byte_size(rest) < length {
        True -> Error(NoError)
        False -> Error(ProtocolError)
      }
    }
    _ -> Error(ProtocolError)
  }
}

fn parse_data(
  identifier: Int,
  flags: BitArray,
  length: Int,
  payload: BitArray,
) -> Result(Frame, ConnectionError) {
  case <<flags:bits, payload:bits>> {
    <<
      _unused:size(4),
      padding:size(1),
      _unused:size(2),
      end_stream:size(1),
      pad_length:size(padding)-unit(8),
      data_and_padding:bits,
    >>
      if identifier != 0
    -> {
      let data_length = case padding {
        1 -> length - pad_length
        0 -> length
        _ -> panic as "Somehow a bit was neither 0 nor 1"
      }
      case data_and_padding {
        <<data:bytes-size(data_length), _padding:bits>> -> {
          Ok(Data(
            data: data,
            end_stream: end_stream == 1,
            identifier: stream_identifier(identifier),
          ))
        }
        _ -> Error(ProtocolError)
      }
    }
    _ -> Error(ProtocolError)
  }
}

fn parse_header(
  identifier: Int,
  flags: BitArray,
  length: Int,
  payload: BitArray,
) -> Result(Frame, ConnectionError) {
  case <<flags:bits, payload:bits>> {
    <<
      _unused:size(2),
      priority:size(1),
      _unused:size(1),
      padded:size(1),
      end_headers:size(1),
      _unused:size(1),
      end_stream:size(1),
      pad_length:size(padded)-unit(8),
      exclusive:size(priority),
      stream_dependency:size(priority)-unit(31),
      weight:size(priority)-unit(8),
      data_and_padding:bits,
    >>
      if identifier != 0 && pad_length < length
    -> {
      let data_length = case padded, priority {
        1, 1 -> length - pad_length - 6
        1, 0 -> length - pad_length - 1
        0, 1 -> length - 5
        0, 0 -> length
        _, _ -> panic as "Somehow a bit was set to neither 0 nor 1"
      }

      case data_and_padding {
        <<data:bytes-size(data_length), _padding:bits>> -> {
          Ok(
            Header(
              data: case end_headers {
                1 -> Complete(data)
                0 -> Continued(data)
                _ -> panic as "Somehow a bit was set to neither 0 nor 1"
              },
              end_stream: { end_stream == 1 },
              identifier: stream_identifier(identifier),
              priority: case priority == 1 {
                True ->
                  Some(HeaderPriority(
                    exclusive: { exclusive == 1 },
                    stream_dependency: stream_identifier(stream_dependency),
                    weight: weight,
                  ))
                False -> None
              },
            ),
          )
        }
        _ -> {
          logging.log(logging.Debug, "oh noes!")
          Error(ProtocolError)
        }
      }
    }
    _ -> {
      Error(ProtocolError)
    }
  }
}

fn parse_priority(
  identifier: Int,
  flags: BitArray,
  length: Int,
  payload: BitArray,
) -> Result(Frame, ConnectionError) {
  case length, <<flags:bits, payload:bits>> {
    5,
      <<
        _unused:size(8),
        exclusive:size(1),
        dependency:size(31),
        weight:size(8),
      >>
      if identifier != 0
    -> {
      Ok(Priority(
        exclusive: exclusive == 1,
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
  identifier: Int,
  flags: BitArray,
  length: Int,
  payload: BitArray,
) -> Result(Frame, ConnectionError) {
  case length, <<flags:bits, payload:bits>> {
    4, <<_unused:size(8), error:size(32)>> if identifier != 0 -> {
      Ok(Termination(
        error: get_error(error),
        identifier: stream_identifier(identifier),
      ))
    }
    4, _ -> Error(ProtocolError)
    _, _ -> Error(FrameSizeError)
  }
}

fn parse_settings(
  identifier: Int,
  flags: BitArray,
  length: Int,
  payload: BitArray,
) -> Result(Frame, ConnectionError) {
  case length % 6, <<flags:bits, payload:bits>> {
    0, <<_unused:size(7), ack:size(1), settings:bytes-size(length)>>
      if identifier == 0
    -> {
      use settings <- result.try(get_settings(settings, []))
      Ok(Settings(ack: ack == 1, settings: settings))
    }

    0, _ -> Error(ProtocolError)
    _, _ -> Error(FrameSizeError)
  }
}

fn parse_push_promise(
  identifier: Int,
  flags: BitArray,
  length: Int,
  payload: BitArray,
) -> Result(Frame, ConnectionError) {
  case <<flags:bits, payload:bits>> {
    <<
      _unused:size(4),
      padded:size(1),
      end_headers:size(1),
      _unused:size(2),
      pad_length:size(padded)-unit(8),
      _reserved:size(1),
      promised_identifier:size(31),
      data:bytes-size(length),
      _padding:bytes-size(pad_length),
    >>
      if identifier != 0
    -> {
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

fn parse_ping(
  identifier: Int,
  flags: BitArray,
  length: Int,
  payload: BitArray,
) -> Result(Frame, ConnectionError) {
  case length, <<flags:bits, payload:bits>> {
    8, <<_unused:size(7), ack:size(1), data:bits-size(64)>> if identifier == 0 -> {
      Ok(Ping(ack: ack == 1, data: data))
    }
    8, _ -> Error(ProtocolError)
    _, _ -> Error(FrameSizeError)
  }
}

fn parse_go_away(
  identifier: Int,
  flags: BitArray,
  length: Int,
  payload: BitArray,
) -> Result(Frame, ConnectionError) {
  case <<flags:bits, payload:bits>> {
    <<
      _unused:size(8),
      _reserved:size(1),
      last_stream_id:size(31),
      error:size(32),
      data:bytes-size(length),
    >>
      if identifier == 0
    -> {
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
  identifier: Int,
  flags: BitArray,
  length: Int,
  payload: BitArray,
) -> Result(Frame, ConnectionError) {
  case length, <<flags:bits, payload:bits>> {
    4, <<_unused:size(8), _reserved:size(1), window_size:size(31)>>
      if window_size != 0
    -> {
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
  identifier: Int,
  flags: BitArray,
  length: Int,
  payload: BitArray,
) -> Result(Frame, ConnectionError) {
  case <<flags:bits, payload:bits>> {
    <<
      _unused:size(5),
      end_headers:size(1),
      _unused:size(2),
      data:bytes-size(length),
    >>
      if identifier != 0
    -> {
      Ok(Continuation(
        data: case end_headers == 1 {
          True -> Complete(data)
          False -> Continued(data)
        },
        identifier: stream_identifier(identifier),
      ))
    }
    _ -> Error(ProtocolError)
  }
}

pub fn encode(frame: Frame) -> BitArray {
  case frame {
    Data(data, end_stream, StreamIdentifier(identifier)) -> {
      let length = bit_array.byte_size(data)
      let end = from_bool(end_stream)
      <<
        length:size(24),
        0:size(8),
        0:size(4),
        0:size(1),
        0:size(2),
        end:size(1),
        0:size(1),
        identifier:size(31),
        data:bits,
      >>
    }
    Header(data, end_stream, StreamIdentifier(identifier), priority) -> {
      let #(end_header, data) = encode_data(data)
      let length = bit_array.byte_size(data)
      let end = from_bool(end_stream)
      let priority_flags = encode_priority(priority)
      let has_priority = from_bool(option.is_some(priority))
      <<
        length:size(24),
        1:size(8),
        0:size(2),
        has_priority:size(1),
        0:size(1),
        0:size(1),
        end_header:size(1),
        0:size(1),
        end:size(1),
        0:size(1),
        identifier:size(31),
        priority_flags:bits,
        data:bits,
      >>
    }
    Priority(
      exclusive,
      StreamIdentifier(identifier),
      StreamIdentifier(dependency),
      weight,
    ) -> {
      let exclusive = from_bool(exclusive)
      <<
        5:size(24),
        2:size(2),
        0:size(8),
        0:size(1),
        identifier:size(31),
        exclusive:size(1),
        dependency:size(31),
        weight:size(8),
      >>
    }
    Termination(error, StreamIdentifier(identifier)) -> {
      let error_code = encode_error(error)
      <<
        4:size(24),
        3:size(8),
        0:size(8),
        0:size(1),
        identifier:size(31),
        error_code:size(32),
      >>
    }
    Settings(ack, settings) -> {
      let ack = from_bool(ack)
      let settings = encode_settings(settings)
      let length = bit_array.byte_size(settings)
      <<
        length:size(24),
        4:size(8),
        0:size(7),
        ack:size(1),
        0:size(1),
        0:size(31),
        settings:bits,
      >>
    }
    PushPromise(
      data,
      StreamIdentifier(identifier),
      StreamIdentifier(promised_identifier),
    ) -> {
      let #(end_headers, data) = encode_data(data)
      <<
        0:size(24),
        5:size(8),
        0:size(4),
        0:size(0),
        end_headers:size(1),
        0:size(2),
        0:size(1),
        identifier:size(31),
        0:size(1),
        promised_identifier:size(31),
        data:bits,
      >>
    }
    Ping(ack, data) -> {
      let ack = from_bool(ack)
      <<
        0:size(24),
        6:size(8),
        0:size(7),
        ack:size(1),
        0:size(1),
        0:size(31),
        data:bits,
      >>
    }
    GoAway(data, error, StreamIdentifier(last_stream_id)) -> {
      let error = encode_error(error)
      let payload_size = bit_array.byte_size(data)
      <<
        payload_size:size(24),
        7:size(8),
        0:size(8),
        0:size(1),
        0:size(31),
        0:size(1),
        last_stream_id:size(31),
        error:size(32),
        data:bits,
      >>
    }
    WindowUpdate(amount, StreamIdentifier(identifier)) -> {
      <<
        4:size(24),
        8:size(8),
        0:size(8),
        0:size(1),
        identifier:size(31),
        0:size(1),
        amount:size(31),
      >>
    }
    Continuation(data, StreamIdentifier(identifier)) -> {
      let #(end_headers, data) = encode_data(data)
      let payload_size = bit_array.byte_size(data)
      <<
        payload_size:size(24),
        9:size(8),
        0:size(5),
        end_headers:size(1),
        0:size(2),
        0:size(1),
        identifier:size(31),
        data:bits,
      >>
    }
  }
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
    n -> Unsupported(n)
  }
}

fn get_settings(
  data: BitArray,
  acc: List(Setting),
) -> Result(List(Setting), ConnectionError) {
  case data {
    <<>> -> Ok(acc)
    <<identifier:size(16), value:size(32), rest:bits>> -> {
      case get_setting(identifier, value) {
        Ok(setting) -> get_settings(rest, [setting, ..acc])
        Error(err) -> Error(err)
      }
    }
    _ -> Error(ProtocolError)
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
          _ -> panic as "Somehow a bit was neither 0 nor 1"
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
    _ -> Error(ProtocolError)
  }
}

fn from_bool(bool: Bool) -> Int {
  case bool {
    True -> 1
    False -> 0
  }
}

fn encode_priority(priority: Option(HeaderPriority)) -> BitArray {
  case priority {
    Some(HeaderPriority(exclusive, StreamIdentifier(dependency), weight)) -> {
      let exclusive = from_bool(exclusive)
      <<exclusive:size(1), dependency:size(31), weight:size(8)>>
    }
    None -> <<>>
  }
}

fn encode_data(data: Data) -> #(Int, BitArray) {
  case data {
    Complete(data) -> #(1, data)
    Continued(data) -> #(0, data)
  }
}

fn encode_error(error: ConnectionError) -> Int {
  case error {
    NoError -> 0
    ProtocolError -> 1
    InternalError -> 2
    FlowControlError -> 3
    SettingsTimeout -> 4
    StreamClosed -> 5
    FrameSizeError -> 6
    RefusedStream -> 7
    Cancel -> 8
    CompressionError -> 9
    ConnectError -> 10
    EnhanceYourCalm -> 11
    InadequateSecurity -> 12
    Http11Required -> 13
    // TODO
    Unsupported(..) -> 69
  }
}

fn encode_settings(settings: List(Setting)) -> BitArray {
  list.fold(settings, <<>>, fn(acc, setting) {
    case setting {
      HeaderTableSize(value) ->
        bit_array.append(acc, <<1:size(16), value:size(32)>>)
      ServerPush(Enabled) -> bit_array.append(acc, <<2:size(16), 1:size(32)>>)
      ServerPush(Disabled) -> bit_array.append(acc, <<2:size(16), 0:size(32)>>)
      MaxConcurrentStreams(value) ->
        bit_array.append(acc, <<3:size(16), value:size(32)>>)
      InitialWindowSize(value) ->
        bit_array.append(acc, <<4:size(16), value:size(32)>>)
      MaxFrameSize(value) ->
        bit_array.append(acc, <<5:size(16), value:size(32)>>)
      MaxHeaderListSize(value) ->
        bit_array.append(acc, <<6:size(16), value:size(32)>>)
    }
  })
}

pub fn settings_ack() -> Frame {
  Settings(ack: True, settings: [])
}
