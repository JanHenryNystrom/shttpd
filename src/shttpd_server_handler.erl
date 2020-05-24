%% -*-erlang-*-
%%==============================================================================
%% Copyright 2020 Jan Henry Nystrom <JanHenryNystrom@gmail.com>
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================

%%%-------------------------------------------------------------------
%%% @doc
%%%  
%%% @end
%%%
%% @author Jan Henry Nystrom <JanHenryNystrom@gmail.com>
%% @copyright (C) 2020, Jan Henry Nystrom <JanHenryNystrom@gmail.com>
%%%-------------------------------------------------------------------
-module(shttpd_server_handler).
-copyright('Jan Henry Nystrom <JanHenryNystrom@gmail.com>').

%% CONN API
-export([start/1]).

%% Worker API
-export([resume/2, continue/2]).

%% Includes
-include_lib("jhn_stdlib/include/uri.hrl").
-include_lib("shttpd/src/shttpd_server.hrl").
-include_lib("kernel/include/logger.hrl").

%% Defines
-define(TRANSFER_OPTS, [active, nodelay, keepalive, delay_send, priority, tos]).
-define(SSL_TIMEOUT, 1000).

-define(HEADERS_405,
        [{allowed,
          <<"GET, HEAD, POST, PUT, PATCH, DELETE, CONNECT, OPTIONS, TRACE">>}]).

-define(FORMAT,
        #{'cache-control' => <<"Cache-Control">>,
          connection => <<"Connection">>,
          date => <<"Date">>,
          pragma => <<"Pragma">>,
          'transfer-encoding' => <<"Transfer-Encoding">>,
          upgrade => <<"Upgrade">>,
          via => <<"Via">>,
          accept => <<"Accept">>,
          'accept-charset' => <<"Accept-Charset">>,
          'accept-encoding' =><<"Accept-Encoding">>,
          'accept-language' =><<"Accept-Language">>,
          authorization => <<"Authorization">>,
          from => <<"From">>,
          host => <<"Host">>,
          'if-modified-since' => <<"If-Modified-Since">>,
          'if-match' => <<"If-Match">>,
          'if-none-match' => <<"If-None-Match">>,
          'if-range' => <<"If-Range">>,
          'if-unmodified-since' => <<"If-Unmodified-Since">>,
          'max-forwards' => <<"Max-Forwards">>,
          'proxy-authorization' => <<"Proxy-Authorization">>,
          range => <<"Range">>,
          referer => <<"Referer">>,
          'user-agent' => <<"User-Agent">>,
          age => <<"Age">>,
          location => <<"Location">>,
          'proxy-authenticate' => <<"Proxy-Authenticate">>,
          public => <<"Public">>,
          'retry-after' => <<"Retry-After">>,
          server => <<"Server">>,
          vary => <<"Vary">>,
          warning => <<"Warning">>,
          'www-authenticate' => <<"Www-Authenticate">>,
          allow => <<"Allow">>,
          'content-base' => <<"Content-Base">>,
          'content-encoding' => <<"Content-Encoding">>,
          'content-language' => <<"Content-Language">>,
          'content-length' => <<"Content-Length">>,
          'content-location' => <<"Content-Location">>,
          'content-md5' => <<"Content-Md5">>,
          'content-range' => <<"Content-Range">>,
          'content-type' => <<"Content-Type">>,
          etag => <<"Etag">>,
          expires => <<"Expires">>,
          'last-modified' => <<"Last-Modified">>,
          'accept-ranges' => <<"Accept-Ranges">>,
          'set-cookie' => <<"Set-Cookie">>,
          'set-cookie2' => <<"Set-Cookie2">>,
          'x-forwarded-for' => <<"X-Forwarded-For">>,
          cookie => <<"Cookie">>,
          'keep-alive' => <<"Keep-Alive">>,
          'proxy-connection' => <<"Proxy-Connection">>,
          'accept-patch' => <<"Accept-Patch">>,
          %% CORS support
          'access-control-allow-origin' => <<"Access-Control-Allow-Origin">>,
          'access-control-allow-methods' => <<"Access-Control-Allow-Methods">>,
          'access-control-max-age' => <<"Access-Control-Max-Age">>,
          'access-control-allow-headers' => <<"Access-Control-Allow-Headers">>
         }).

-define(MAX_METHOD, 8).
-define(MAX_TARGET, 512).
-define(MAX_VERSION, 4).
-define(MAX_HEADERS, 2048).

-define(MAX_BODY, 4194304). %% 4MB

-define(MAX_LOG_BODY, 512).

-define(X_ID, <<"x-correlation-id">>).

%% Records

%% Types

%% ===================================================================
%% CONN API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: handle(State) -> ok.
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec start(#state{}) -> ok.
%%--------------------------------------------------------------------
start(State = #state{protocol = tcp, socket = Sock}) ->
    try handle_packet(State)
    catch
        error:timeout ->
            {PeerIP, _} = inet:peername(Sock),
            ?LOG_WARNING("timeout from ~w", [PeerIP]);
        error:closed ->
            {PeerIP, _} = inet:peername(Sock),
            ?LOG_WARNING("closed from ~w", [PeerIP]);
        Class:Error:Trace ->
            ?LOG_ERROR("~s:~w trace: ~w", [Class, Error, Trace]),
            gen_tcp:close(Sock)
    end;
start(State = #state{protocol = ssl, ssl_options = Opts, socket = Sock}) ->
    case ssl:handshake(Sock, Opts, limit(State)) of
        {ok, SSLSock} ->
            try handle_packet(State#state{socket = SSLSock})
            catch
                error:timeout ->
                    {PeerIP, _} = inet:peername(SSLSock),
                    ?LOG_WARNING("timeout from ~w", [PeerIP]);
                error:closed ->
                    {PeerIP, _} = inet:peername(Sock),
                    ?LOG_WARNING("closed from ~w", [PeerIP]);
                Class:Error:Trace ->
                    ?LOG_ERROR("~s:~w trace: ~2", [Class, Error, Trace]),
                    ssl:close(SSLSock)
            end;
        {error, Error} ->
            gen_tcp:close(Sock),
            ?LOG_INFO("SSL accept failed due to: ~w", [Error])
    end.

%%--------------------------------------------------------------------
%% Function: resume(Data, State) -> ok.
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec resume(binary(), #state{}) -> ok.
%%--------------------------------------------------------------------
resume(Data, State) -> get_body(Data, State).

%% ===================================================================
%% Worker API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: handle(State) -> ok.
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec continue(binary(), #state{}) -> ok.
%%--------------------------------------------------------------------
continue(Data, State) -> get_method(Data, ?MAX_METHOD, State, <<>>).

%% ===================================================================
%% Internal functions.
%% ===================================================================

handle_packet(State) -> get_method(more(State), ?MAX_METHOD, State, <<>>).

%% -------------------------------------------------------------------
%% Method
%% -------------------------------------------------------------------

get_method(<<>>, N, State, Acc) -> get_method(more(State), N, State, Acc);
get_method(_, 0, State, Acc) ->
    response(413, ?HEADERS_405, <<>>, closing(State#state{method = Acc}));
get_method(<<$\s, T/binary>>, _, State, Acc) ->
    case normalize_method(bstring:to_lower(Acc)) of
        error ->
            response(405, ?HEADERS_405,<<>>,closing(State#state{method = Acc}));
        Method ->
            get_target(T, ?MAX_TARGET, State#state{method = Method}, <<>>)
    end;
get_method(<<H, T/binary>>, N, State, Acc) ->
    get_method(T, N - 1, State, <<Acc/binary, H>>).

normalize_method(<<"get">>) -> get;
normalize_method(<<"head">>) -> head;
normalize_method(<<"post">>) -> post;
normalize_method(<<"put">>) -> put;
normalize_method(<<"patch">>) ->  patch;
normalize_method(<<"delete">>) -> delete;
normalize_method(<<"connect">>) -> connect;
normalize_method(<<"options">>) -> options;
normalize_method(<<"trace">>) -> trace;
normalize_method(_) -> error.

%% -------------------------------------------------------------------
%% Target
%% -------------------------------------------------------------------

get_target(<<>>, N, State, Acc) -> get_target(more(State), N, State, Acc);
get_target(_,  0, State, Acc) ->
    response(414, closing(State#state{url = Acc}));
get_target(<<$\s, T/binary>>, _, State = #state{prefix_name = Prefix}, Acc) ->
    State1 = State#state{url = Acc},
    try uri:decode(Acc) of
        #uri{path = Path, query = Query, fragment = Frag} ->
            State2 = State1#state{query = Query, fragment = Frag},
            case Prefix:lookup(Path) of
                undefined -> response(404, closing(State2));
                R = #{module := Module,
                      name := Route,
                      bindings := Bindings,
                      extra := Extra,
                      log := Log} ->
                    #state{method = Method, routes = Routes} = State2,
                    #{methods := Methods} = plist:find(Route, Routes),
                    Allowed = maps:get(methods, R, Methods),
                    State3 = State2#state{route = Route,
                                          module = Module,
                                          allowed = Allowed,
                                          bindings = Bindings,
                                          extra = Extra,
                                          log = Log},
                    case lists:member(Method, Allowed) of
                        true -> get_version(T, ?MAX_VERSION, State3, <<>>);
                        false ->
                            Denorm = [denormalize_method(M) || M <- Allowed],
                            Headers = [{allowed,bstring:join(Denorm,<<", ">>)}],
                            response(405, Headers, <<>>, closing(State3))
                    end
            end
    catch _:_ ->
            response(400, closing(State1))
    end;
get_target(<<H, T/binary>>, N, State, Acc) ->
    get_target(T, N - 1, State, <<Acc/binary, H>>).

%% -------------------------------------------------------------------
%% Version
%% -------------------------------------------------------------------

get_version(<<>>, N, State, Acc) -> get_version(more(State), N, State, Acc);
get_version(_, 0, State, _) -> response(413, closing(State));
get_version(<<"HTTP/", T/binary>>, N, State, _) ->
    get_version(T, N, State, <<>>);
get_version(<<"\r\n", T/binary>>, _, State, <<"1.1">>) ->
    get_header(T, ?MAX_HEADERS, State, [], <<>>);
get_version(<<"\r\n", _/binary>>, _, State, _) ->
    response(505, closing(State));
get_version(<<H, T/binary>>, N, State, Acc) ->
    get_version(T, N - 1, State, <<Acc/binary, H>>).

%% -------------------------------------------------------------------
%% Headers
%% -------------------------------------------------------------------

get_header(<<>>, N, State, Headers, Acc) ->
    get_header(more(State), N, State, Headers, Acc);
get_header(_, 0, State, Headers, _) ->
    response(413, closing(State#state{headers = Headers}));
get_header(<<$:, T/binary>>, N, State, Headers, Acc) ->
    Name = bstring:to_lower(Acc),
    get_header_value(skip_ws(T, State), N - 1, State, Headers, Name, <<>>,<<>>);
get_header(<<"\r\n", T/binary>>, _, State, Headers, <<>>) ->
    State1 = case State#state.x_correlation_id of
                 undefined ->
                     State#state{headers = Headers,
                                 x_correlation_id = uuid_v4()};
                 _ ->
                     State#state{headers = Headers}
             end,
    authenticate(State1, T);
get_header(<<H, T/binary>>, N, State, Headers, Acc) ->
    get_header(T, N - 1, State, Headers, <<Acc/binary, H>>).

skip_ws(<<>>, State) -> skip_ws(more(State), State);
skip_ws(<<$\s, T/binary>>, State) -> skip_ws(T, State);
skip_ws(<<$\t, T/binary>>, State) -> skip_ws(T, State);
skip_ws(T, _) -> T.

get_header_value(<<>>, N, State, Headers, Name, Acc, TWS) ->
    get_header_value(more(State), N, State, Headers, Name, Acc, TWS);
get_header_value(_, 0, State, Headers, _, _, _) ->
    response(413, closing(State#state{headers = Headers}));
get_header_value(<<"\r\n", T/binary>>, N, State, Headers, Name, Acc, _) ->
    check_header(Name, Acc, T, N + 2, State, [{Name, Acc} | Headers]);
get_header_value(<<$\s, T/binary>>, N, State, Headers, Name, Acc, TWS) ->
    get_header_value(T, N - 1, State, Headers, Name, Acc, <<TWS/binary, $\s>>);
get_header_value(<<$\t, T/binary>>, N, State, Headers, Name, Acc, TWS) ->
    get_header_value(T, N - 1, State, Headers, Name, Acc, <<TWS/binary, $\t>>);
get_header_value(<<H, T/binary>>, N, State, Headers, Name, Acc, <<>>) ->
    get_header_value(T, N - 1, State, Headers, Name, <<Acc/binary, H>>, <<>>);
get_header_value(<<H, T/binary>>, N, State, Headers, Name, Acc, TWS) ->
    get_header_value(T,N-1,State,Headers,Name,<<Acc/binary,TWS/binary,H>>,<<>>).

check_header(<<"accept">>, Media, T, N, State, Headers) ->
    case media_type(Media, <<>>) of
        true -> get_header(T, N, State, Headers, <<>>);
        false -> response(406, closing(State#state{headers = Headers}))
    end;
check_header(<<"accept-charset">>, Sets, T, N, State, Headers) ->
    case charset(Sets, <<>>) of
        true -> get_header(T, N, State, Headers, <<>>);
        false -> response(406, closing(State#state{headers = Headers}))
    end;
check_header(<<"accept-encoding">>, Encs, T, N, State, Headers) ->
    case encoding(Encs, false, <<>>) of
        false -> response(406, closing(State#state{headers = Headers}));
        Enc -> get_header(T, N, State#state{accept_encoding=Enc}, Headers,<<>>)
    end;
check_header(<<"accept-language">>, Langs, T, N, State, Headers) ->
    case language(Langs, <<>>) of
        true -> get_header(T, N, State, Headers, <<>>);
        false -> response(406, closing(State#state{headers = Headers}))
    end;
check_header(<<"authorization">>, Auth, T, N, State, Headers) ->
    get_header(T, N, State#state{authorization = Auth}, Headers, <<>>);
check_header(<<"content-encoding">>, <<"identity">>,T,N,State,Headers) ->
    get_header(T, N, State#state{content_encoding = identity}, Headers,<<>>);
check_header(<<"content-encoding">>, <<"gzip">>, T,N,State,Headers) ->
    get_header(T, N, State#state{content_encoding = gzip}, Headers, <<>>);
check_header(<<"content-encoding">>, _, _, _, State, Headers) ->
    response(400, closing(State#state{headers = Headers}));
check_header(<<"content-language">>, <<"en">>, T, N, State, Headers) ->
    get_header(T, N, State, Headers,<<>>);
check_header(<<"content-language">>, _, _, _, State, Headers) ->
    response(400, closing(State#state{headers = Headers}));
check_header(<<"content-length">>, Length, T, N, State, Headers) ->
    try binary_to_integer(Length) of
        L when L > ?MAX_BODY ->
            response(413, closing(State#state{headers = Headers}));
        L ->
            get_header(T, N, State#state{content_length = L}, Headers, <<>>)
    catch
        _:_ ->
            response(400, closing(State#state{headers = Headers}))
    end;
check_header(<<"content-type">>,<<"application/json">>, T, N,State,Headers) ->
    get_header(T, N, State, Headers, <<>>);
check_header(<<"content-type">>, _, _, _, State, Headers) ->
    response(400, closing(State#state{headers = Headers}));
check_header(<<"connection">>, Connection, T, N, State, Headers) ->
    State1 = case bstring:to_lower(Connection) of
                 <<"close">> -> closing(State);
                 _ -> State
             end,
    get_header(T, N, State1, Headers, <<>>);
check_header(?X_ID, Id, T, N, State, Headers) ->
    get_header(T, N, State#state{x_correlation_id = Id}, Headers, <<>>);
check_header(_, _, T, N, State, Headers) ->
    get_header(T, N, State, Headers, <<>>).

%% -------------------------------------------------------------------
%% Accept Headers
%% -------------------------------------------------------------------

media_type(<<>>, _) -> false;
media_type(<<$/, T/binary>>, Acc) -> media_subtype(T, Acc, <<>>);
media_type(<<H, T/binary>>, Acc) -> media_type(T, <<Acc/binary, H>>).

media_subtype(<<>>, Type, Acc) -> accept_type(Type, Acc, <<>>);
media_subtype(<<$\s, T/binary>>, Type, Acc) -> accept_type(Type, Acc, T);
media_subtype(<<$\t, T/binary>>, Type, Acc) -> accept_type(Type, Acc, T);
media_subtype(<<$;, T/binary>>, Type, Acc) -> accept_type(Type, Acc, T);
media_subtype(<<H, T/binary>>, Type, Acc) ->
    media_subtype(T, Type, <<Acc/binary, H>>).

accept_type(<<$*>>, <<$*>>, _) -> true;
accept_type(<<"application">>, <<$*>>, _) -> true;
accept_type(<<"application">>, <<"json">>, _) -> true;
accept_type(_, _, T) -> media_type(next_accept(T), <<>>).

next_accept(<<>>) -> <<>>;
next_accept(<<$,, T/binary>>) -> skip_ws(T);
next_accept(<<_, T/binary>>) -> next_accept(T).

skip_ws(<<$\s, T/binary>>) -> skip_ws(T);
skip_ws(<<$\t, T/binary>>) -> skip_ws(T);
skip_ws(T) -> T.

charset(<<>>, Acc) -> accept_charset(Acc, <<>>);
charset(<<$\s, T/binary>>, Acc) -> accept_charset(Acc, T);
charset(<<$\t, T/binary>>, Acc) -> accept_charset(Acc, T);
charset(<<$;, T/binary>>, Acc) -> accept_charset(Acc, T);
charset(<<H, T/binary>>, Acc) -> charset(T, <<Acc/binary, H>>).

accept_charset(<<>>, _) -> false;
accept_charset(<<$*>>, _) -> true;
accept_charset(Charset, T) ->
    case bstring:to_lower(Charset) of
        <<"utf-8">> -> true;
        _ -> charset(next_accept(T), <<>>)
    end.

encoding(<<>>, Enc, Acc) -> accept_encoding(Acc, Enc, <<>>);
encoding(<<$\s, T/binary>>, Enc, Acc) -> accept_encoding(Acc, Enc, T);
encoding(<<$\t, T/binary>>, Enc, Acc) -> accept_encoding(Acc, Enc, T);
encoding(<<$;, T/binary>>, Enc, Acc) -> accept_encoding(Acc, Enc, T);
encoding(<<H, T/binary>>, Enc, Acc) -> encoding(T, Enc, <<Acc/binary, H>>).

accept_encoding(<<>>, Enc, _) -> Enc;
accept_encoding(<<"gzip">>, _, _) -> gzip;
accept_encoding(<<"identity">>, _, T) -> encoding(next_accept(T),identity,<<>>);
accept_encoding(<<$*>>, _, T) -> encoding(next_accept(T),identity, <<>>);
accept_encoding(_, Enc, T) -> encoding(next_accept(T), Enc, <<>>).

language(<<>>, Acc) -> accept_language(Acc, <<>>);
language(<<$\s, T/binary>>, Acc) -> accept_language(Acc, T);
language(<<$\t, T/binary>>, Acc) -> accept_language(Acc, T);
language(<<$;, T/binary>>, Acc) -> accept_language(Acc, T);
language(<<H, T/binary>>, Acc) -> language(T, <<Acc/binary, H>>).

accept_language(<<>>, _) -> false;
accept_language(<<"en">>, _) -> true;
accept_language(<<"*">>, _) -> true;
accept_language(_, T) -> language(next_accept(T), <<>>).

%% -------------------------------------------------------------------
%% Authentication
%% -------------------------------------------------------------------

authenticate(State = #state{method = options, close=false, worker=false}, T) ->
    transfer_worker(State#state.name, T, State);
authenticate(State = #state{method = options}, T) ->
    get_body(T, State);
authenticate(State = #state{headers = Headers}, T) ->
    case auth_method(State) of
        anonymous ->
            #state{routes = Routes, route = Route} = State,
            #{authentications := Authentications} = plist:find(Route, Routes),
            case lists:member(anonymous, Authentications) of
                true -> switch(State, T);
                _ -> response(401, [], <<>>, closing(State))
            end;
        {Method, Payload} ->
            #state{routes = Routes, route = Route} = State,
            #{authentications := Authentications} = plist:find(Route, Routes),
            case lists:member(Method, Authentications) of
                false -> response(401, [], <<>>, closing(State));
                true ->
                    #state{module = Module, bindings = Bindings} = State,
                    try Module:Method(Payload, Headers, Bindings) of
                        ok -> switch(State, T);
                        Realm ->
                            RespHeaders =
                                [{'www-authenticate',
                                  <<"Basic realm=\"", Realm/binary, "\"">>}],
                            response(401, RespHeaders, <<>>, closing(State))
                    catch
                        _:_ -> response(500, [], <<>>, closing(State))
                    end
            end;
        _ ->
            response(401, [], <<>>,closing(State))
    end.

auth_method(#state{authorization = <<"Basic ", Base64/binary>>}) ->
    case basic_split(base64:decode(Base64), <<>>) of
        fail -> fail;
        UserPass -> {basic, UserPass}
    end;
auth_method(_) ->
    anonymous.

basic_split(<<>>, _) -> fail;
basic_split(<<$:, Pass/binary>>, User) -> #{user => User, password => Pass};
basic_split(<<H, T/binary>>, Acc) -> basic_split(T, <<Acc/binary, H>>).

switch(State = #state{close = true}, T) -> get_body(T, State);
switch(State = #state{close = false, worker = true}, T) -> get_body(T, State);
switch(State = #state{close = false, worker = false, name = Name}, T) ->
    transfer_worker(Name,T,State).

%% -------------------------------------------------------------------
%% Body
%% -------------------------------------------------------------------

get_body(_, State = #state{method=options, headers=Headers, allowed=Allowed}) ->
    Denorm = bstring:join([denormalize_method(M) || M <- Allowed], <<", ">>),
    case plist:find(<<"access-control-request-method">>, Headers) of
        undefined -> response(200, [{allowed, Denorm}],<<>>,State);
        _ ->
            Origin = plist:find(<<"origin">>, Headers),
            ReqHeaders =
                plist:find(<<"access-control-request-headers">>, Headers),
            RespHeaders = [{allowed, Denorm},
                           {'access-control-allow-origin', Origin},
                           {'access-control-allow-methods', Denorm},
                           {'access-control-allow-headers', ReqHeaders},
                           {'access-control-max-age', <<"86400">>}],
            response(200, RespHeaders, <<>>, State)
    end;
get_body(T, State) ->
    #state{module = Module,
           method = Method,
           query = Query,
           fragment = Frag,
           bindings = Bindings,
           extra = Extra,
           content_length = Len,
           x_correlation_id = XId} = State,
    Query1 = [bstring:tokens(Token, <<"=">>) ||
                 Token <- bstring:tokens(Query, <<"&">>)],
    Args = #{bindings => Bindings,
             extra => Extra,
             query => Query1,
             fragment => Frag,
             id => XId},
    case lists:member(Method, ?HAS_BODY) of
        false -> result(Module, Method, Args, State);
        true ->
            case Len of
                0 ->
                    Args1 = Args#{body => <<>>, json => #{}},
                    result(Module, Method, Args1, State);
                undefined -> response(411, closing(State));
                _ ->
                    State1 = extend_limit(State, Len),
                    Body = case byte_size(T) >= Len of
                               true -> T;
                               false -> more(State1, T, Len - byte_size(T))
                           end,
                    State2 = State1#state{body = Body},
                    case unpack(State2) of
                        error -> response(400, closing(State2));
                        {JSON, State3} ->
                            Args1 = Args#{body => Body, json => JSON},
                            result(Module, Method, Args1, State3)
                    end
            end
    end.

unpack(State = #state{content_encoding = identity, body = Body}) ->
    try jstream:decode(Body) of
        {JSON, <<>>} -> {JSON, State};
        _ -> error
    catch
        _:_ -> error
    end;
unpack(State = #state{content_encoding = gzip, body = Body}) ->
    try zlib:gunzip(Body) of
        Body1 -> unpack(State#state{content_encoding = identity, body = Body1})
    catch
        _:_ -> error
    end.

%% -------------------------------------------------------------------
%% Invoking callback
%% -------------------------------------------------------------------

result(_, trace, _, State) ->
    #state{x_correlation_id = Id, headers = Headers} = State,
    Id1 = case Id of
              undefined -> uuid_v4();
              _ -> Id
          end,
    Headers1 = [{'content-length', 0},
                {'content-type',<<"message/http">>},
                {'x-correlation-id', Id1},
                {date, shttpd_date:get()},
                {server, <<"SHTTPD/1.1 v1">>} | Headers],
    log(Id1, 200, Headers1, <<>>, State),
    Message = [<<"HTTP/1.1 ">>, code_text(200), <<"\r\n">>,
               format_headers(Headers1), <<"\r\n">>],
    send(Message, extend_limit(State, 0));
result(Module, Method, Args, State) ->
    try Module:Method(Args) of
        Result = #{code := Code, body := Body} ->
            response(Code, maps:get(headers, Result, []), Body, State);
        Result = #{code := Code, json := JSON} ->
            response(Code,
                     maps:get(headers, Result, []),
                     jstream:encode(JSON), State);
        #{code := Code, headers := Headers} ->
            response(Code, Headers, <<>>, State);
        Code ->
            response(Code, [], <<>>, State)
    catch
        Class:Error:Trace ->
            ?LOG_ERROR("~s:~w trace: ~s", [Class, Error, Trace]),
            response(500, State)
    end.

%% -------------------------------------------------------------------
%% Response
%% -------------------------------------------------------------------

response(Code, State) -> response(Code, [], <<>>, State).

response(Code, Headers, Body, State) ->
    {Id, Headers1, Body1, Sz1} =
        response_prep(Headers, iolist_size(Body), Body, State),
    log(Id, Code, Headers1, Body, State),
    Message = [<<"HTTP/1.1 ">>, code_text(Code), <<"\r\n">>,
               format_headers(Headers1), <<"\r\n">>,
               Body1],
    send(Message, extend_limit(State, Sz1)).

response_prep(Headers, Sz, Body, State) ->
    #state{close = Close, x_correlation_id = Id, accept_encoding = Enc} =
        State,
    Headers1 = case Close of
                   true -> [{connection, <<"Close">>} | Headers];
                   false -> Headers
               end,
    Id1 = case Id of
              undefined -> uuid_v4();
              _ -> Id
          end,
    {Headers2, Body1, Sz1} =
        case {Sz, Enc} of
            {0, _} -> {[{'content-length', 0} | Headers1], Body, Sz};
            {_, gzip} ->
                Body0 = zlib:gzip(Body),
                {[{'content-length', byte_size(Body0)},
                  {'content-type', <<"application/json">>},
                  {'content-encoding', <<"gzip">>},
                  {'content-language', <<"en">>} | Headers1],
                 Body0,
                 byte_size(Body0)};
            {_, identity} ->
                {[{'content-length', Sz},
                  {'content-type', <<"application/json">>},
                  {'content-encoding', <<"identity">>},
                  {'content-language', <<"en">>} | Headers1],
                 Body,
                 Sz}
        end,
    Headers3 = [{'x-correlation-id', Id1},
                {date, shttpd_date:get()},
                {server, <<"SHTTPD/1.1 v1">>} | Headers2],
    {Id1, plist:compact(Headers3), Body1, Sz1}.

format_headers(Headers) ->
    Fun = fun(H, V) -> [format_header(H, V), <<"\r\n">>] end,
    [Fun(Key, Value) || {Key, Value} <- Headers].

format_header(allowed, Methods) -> [<<"Allowed: ">>, Methods];
format_header(connection, Conn) -> [<<"Connection: ">>, Conn];
format_header('content-encoding', Enc) -> [<<"Content-Encoding: ">>, Enc];
format_header('content-language', Lang) -> [<<"Content-Language: ">>, Lang];
format_header('content-length', L) ->
    [<<"Content-Length: ">>, integer_to_binary(L)];
format_header('content-type', Type) ->
    [<<"Content-Type: ">>, Type];
format_header('date', Date) ->
    [<<"Date: ">>, Date];
format_header('server', Server) ->
    [<<"Server: ">>, Server];
format_header('x-correlation-id', Id) ->
    [<<"X-Correlation-ID: ">>, Id];
format_header(Header, Value) ->
    [maps:get(Header, ?FORMAT, Header), $:, $\s, Value].

%% Informational
code_text(100) -> <<"100 Continue">>;
code_text(101) -> <<"101 Switching Protocols">>;
%% Successful
code_text(200) -> <<"200 OK">>;
code_text(201) -> <<"201 Created">>;
code_text(202) -> <<"202 Accepted">>;
code_text(203) -> <<"203 Non-Authoritative Information">>;
code_text(204) -> <<"204 No Content">>;
code_text(205) -> <<"205 Reset Content">>;
code_text(206) -> <<"206 Partial Content">>;
code_text(207) -> <<"207 Multi-Status">>;
code_text(208) -> <<"208 Already Reported">>;
code_text(226) -> <<"226 IM Used">>;
%% Redirection
code_text(300) -> <<"300 Multiple Choices">>;
code_text(301) -> <<"301 Moved Permanently">>;
code_text(302) -> <<"302 Found">>;
code_text(303) -> <<"303 See Other">>;
code_text(304) -> <<"304 Not Modified">>;
code_text(305) -> <<"305 Use Proxy">>;
code_text(307) -> <<"307 Temporary Redirect">>;
code_text(308) -> <<"308 Permanent Redirect">>;
%% Client error
code_text(400) -> <<"400 Bad Request">>;
code_text(401) -> <<"401 Unauthorized">>;
code_text(402) -> <<"402 Payment Required">>;
code_text(403) -> <<"403 Forbidden">>;
code_text(404) -> <<"404 Not Found">>;
code_text(405) -> <<"405 Method Not Allowed">>;
code_text(406) -> <<"406 Not Acceptable">>;
code_text(407) -> <<"407 Proxy Authentication Required">>;
code_text(408) -> <<"408 Request Timeout">>;
code_text(409) -> <<"409 Conflict">>;
code_text(410) -> <<"410 Gone">>;
code_text(411) -> <<"411 Length Required">>;
code_text(412) -> <<"412 Precondition Failed">>;
code_text(413) -> <<"413 Payload Too Large">>;
code_text(414) -> <<"414 Request-URI Too Long">>;
code_text(415) -> <<"415 Unsupported Media Type">>;
code_text(416) -> <<"416 Requested Range Not Satisfiable">>;
code_text(417) -> <<"417 Expectation Failed">>;
code_text(418) -> <<"418 I'm a teapot">>;
code_text(421) -> <<"421 Misdirected Request">>;
code_text(422) -> <<"422 Unprocessable Entity">>;
code_text(423) -> <<"423 Locked">>;
code_text(424) -> <<"424 Failed Dependency">>;
code_text(428) -> <<"428 Precondition Required">>;
code_text(429) -> <<"429 Too Many Requests ">>;
code_text(431) -> <<"431 Request Header Fields Too Large">>;
code_text(451) -> <<"451 Unavailable For Legal Reasons">>;
%% Server error
code_text(500) -> <<"500 Internal Server Error">>;
code_text(501) -> <<"501 Not Implemented">>;
code_text(502) -> <<"502 Bad Gateway">>;
code_text(503) -> <<"503 Service Unavailable">>;
code_text(504) -> <<"504 Gateway Timeout">>;
code_text(505) -> <<"505 HTTP Version Not Supported">>;
code_text(506) -> <<"506 Variant Also Negotiates">>;
code_text(507) -> <<"507 Insufficient Storage">>;
code_text(508) -> <<"508 Loop Detected">>;
code_text(510) -> <<"510 Not Extended">>;
code_text(511) -> <<"511 Network Authentication Required">>.

log(_, _, _, _, #state{log = false}) -> ok;
log(XId, Status, RespHeaders, RespBody, State)  ->
    #state{system = System,
           method = Method,
           start = Start,
           url = URL,
           headers = Headers,
           body = Body} = State,
    Method1 = denormalize_method(Method),
    Duration = os:system_time(milli_seconds) - Start,
    Entry = case iolist_size(RespBody) of
                 0 -> #{};
                 Size when Size =< ?MAX_LOG_BODY -> #{resp_body => RespBody};
                 _ -> #{resp_body => binary:part(RespBody, {0,?MAX_LOG_BODY})}
            end,
    Entry1 = case byte_size(Body) of
                 0 -> Entry;
                 Size1 when Size1 =< ?MAX_LOG_BODY -> Entry#{body =>  Body};
                 _ -> Entry#{body => binary:part(Body, {0, ?MAX_LOG_BODY})}
              end,
    Entry2 = Entry1#{system => System,
                     status => Status,
                     duration => Duration,
                     ?X_ID => XId,
                     method => Method1,
                     url => URL,
                     headers  => maps:from_list(Headers),
                     resp_headers => maps:from_list(RespHeaders)},
    statsd(Method1, Status, Duration, State),
    ?LOG_NOTICE(jstream:encode(Entry2, binary)).

denormalize_method(get) -> <<"GET">>;
denormalize_method(head) -> <<"HEAD">>;
denormalize_method(post) -> <<"POST">>;
denormalize_method(put) -> <<"PUT">>;
denormalize_method(patch) ->  <<"PATCH">>;
denormalize_method(delete) -> <<"DELETE">>;
denormalize_method(connect) -> <<"CONNECT">>;
denormalize_method(options) -> <<"OPTIONS">>;
denormalize_method(trace) -> <<"TRACE">>;
denormalize_method(X) -> X.

%% -------------------------------------------------------------------
%% Socket handling
%% -------------------------------------------------------------------

more(State) -> more(State, 0).

more(State, Len) ->
    case recv(State, Len, limit(State)) of
        {ok, More} -> More;
        {error, Error} ->
            close(State),
            erlang:error(Error)
    end.

more(State, Sofar, Len) ->
    case recv(State, Len, limit(State)) of
        {ok, More} -> <<Sofar/binary, More/binary>>;
        {error, Error} ->
            close(State),
            erlang:error(Error)
    end.

setopts(#state{protocol = tcp, socket=Sock}, Opts) -> inet:setopts(Sock, Opts);
setopts(#state{protocol = ssl, socket = Sock}, Opts) -> ssl:setopts(Sock, Opts).

close(#state{protocol = tcp, socket = Sock}) -> gen_tcp:close(Sock);
close(#state{protocol = ssl, socket = Sock}) -> ssl:close(Sock).

send(Message, State = #state{protocol = tcp}) -> send(Message, gen_tcp, State);
send(Message, State = #state{protocol = ssl}) -> send(Message, ssl, State).

send(Message, Module, State = #state{socket = Sock}) ->
    setopts(State, [{send_timeout, limit(State)}]),
    State1 = case Module:send(Sock, Message) of
                 ok -> State;
                 {error, Error} ->
                     close(State),
                     erlang:error(Error)
             end,
    case State1#state.close of
        true -> close(State1);
        false -> ok
    end,
    State1.

recv(#state{protocol = tcp, socket = Sock}, Len, Timeout) ->
    gen_tcp:recv(Sock, Len, Timeout);
recv(#state{protocol = ssl, socket = Sock}, Len, Timeout) ->
    ssl:recv(Sock, Len, Timeout).

controlling_process(Pid, #state{protocol = tcp, socket = Sock}) ->
    gen_tcp:controlling_process(Sock, Pid);
controlling_process(Pid, #state{protocol = ssl, socket = Sock}) ->
    ssl:controlling_process(Sock, Pid).

%% -------------------------------------------------------------------
%% Worker
%% -------------------------------------------------------------------
transfer_worker(Name, T, State) ->
    case shttpd_server_master:transfer(Name, T, State#state{worker = true}) of
        false -> get_body(T, closing(State));
        {ok, Pid} ->
            controlling_process(Pid, State),
            shttpd_server_worker:resume(Pid)
    end.

%% -------------------------------------------------------------------
%% Misc
%% -------------------------------------------------------------------
closing(State) -> State#state{close = true}.

limit(#state{limit = Limit}) ->
    case Limit - erlang:system_time(milli_seconds) of
        Time when Time =< 0 -> 0;
        Time -> Time
    end.

%% Assuming slightly less than 20kB
extend_limit(State = #state{limit = Limit}, Len) ->
    State#state{limit = Limit + (Len * 1000 div 256)}.

uuid_v4() ->
    <<A:48, _:4, B:12, _:2, C:62>> = crypto:strong_rand_bytes(16),
    UUID = <<A:48, 0:1, 1:1, 0:1, 0:1, B:12, 1:1, 0:1, C:62>>,
    iolist_to_binary(io_lib:format(
                       "~2.16.0b~2.16.0b~2.16.0b~2.16.0b-"
                       "~2.16.0b~2.16.0b-"
                       "~2.16.0b~2.16.0b-"
                       "~2.16.0b~2.16.0b-"
                       "~2.16.0b~2.16.0b~2.16.0b~2.16.0b~2.16.0b~2.16.0b",
                       [D || <<D>> <= UUID])).

statsd(_, _, _, #state{statsd_server = false}) -> ok;
statsd(Method, Status, Duration, #state{module = Mod, system = System}) ->
    Bucket = [System, ".", Mod, ".", Method],
    shttpd_statsd:timer(Bucket, Duration),
    shttpd_statsd:increment([Bucket, integer_to_binary(Status)]).
