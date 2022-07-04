-module(hackney_ffi).

-export([stream_request/4]).

stream_request(Method, Path, Headers, Body) ->
  try
    {ok, ClientRef} = hackney:request(Method, Path, Headers, stream, []),
    ok = hackney:send_body(ClientRef, Body),
    {ok, Status, RespHeaders, ClientRef} = hackney:start_response(ClientRef),
    {ok, RespBody} = hackney:body(ClientRef),
    {ok, {Status, RespHeaders, RespBody}}
  catch
    _ -> {error, nil}
  end.
