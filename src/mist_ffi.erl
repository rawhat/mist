-module(mist_ffi).

-export([binary_match/2, decode_packet/3, file_open/1, string_to_int/2, hpack_decode/2,
         hpack_encode/2, hpack_new_max_table_size/2, ets_lookup_element/3, get_path_and_query/1,
         file_close/1]).

decode_packet(Type, Packet, Opts) ->
  case erlang:decode_packet(Type, Packet, Opts) of
    {ok, http_eoh, Rest} ->
      {ok, {end_of_headers, Rest}};
    {ok, {http_request, <<"PRI">>, '*', {2, 0}}, Rest} ->
      {ok, {http2_upgrade, Rest}};
    {ok, Binary, Rest} ->
      {ok, {binary_data, Binary, Rest}};
    {more, undefined} ->
      {ok, {more_data, none}};
    {more, Length} ->
      {ok, {more_data, {some, Length}}};
    {error, Reason} ->
      {error, Reason}
  end.

binary_match(Source, Pattern) ->
  case binary:match(Source, Pattern) of
    {Before, After} ->
      {ok, {Before, After}};
    nomatch ->
      {error, nil}
  end.

string_to_int(String, Base) ->
  try
    {ok, erlang:list_to_integer(String, Base)}
  catch
    error:badarg ->
      {error, nil}
  end.

file_open(Path) ->
  case file:open(Path, [raw]) of
    {ok, Fd} ->
      {ok, Fd};
    {error, enoent} ->
      {error, no_entry};
    {error, eacces} ->
      {error, no_access};
    {error, eisdir} ->
      {error, is_dir};
    _ ->
      {error, unknown_file_error}
  end.

file_close(File) ->
  case file:close(File) of
    ok ->
      {ok, nil};
    {error, enoent} ->
      {error, no_entry};
    {error, eacces} ->
      {error, no_access};
    {error, eisdir} ->
      {error, is_dir};
    _ ->
      {error, unknown_file_error}
  end.

hpack_decode(Context, Bin) ->
  case hpack:decode(Bin, Context) of
    {ok, {Headers, NewContext}} ->
      {ok, {Headers, NewContext}};
    {error, compression_error} ->
      {error, {hpack_error, compression}};
    {error, {compression_error, {bad_header_packet, Binary}}} ->
      {error, {hpack_error, {bad_header_packet, Binary}}}
  end.

hpack_encode(Context, Headers) ->
  hpack:encode(Headers, Context).

hpack_new_max_table_size(Context, Size) ->
  hpack:new_max_table_size(Size, Context).

ets_lookup_element(Table, Key, Position) ->
  try
    {ok, ets:lookup_element(Table, Key, Position)}
  catch
    error:badarg ->
      {error, nil}
  end.

get_path_and_query(String) ->
  case uri_string:parse(String) of
    {error, Value, Term} ->
      {error, {Value, Term}};
    UriMap ->
      Query =
        case maps:find(query, UriMap) of
          {ok, Value} ->
            {ok, Value};
          error ->
            {error, nil}
        end,
      {ok, {maps:get(path, UriMap), Query}}
  end.
