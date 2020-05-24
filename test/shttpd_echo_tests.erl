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
-module(shttpd_echo_tests).
-copyright('Jan Henry Nystrom <JanHenryNystrom@gmail.com>').

-include_lib("eunit/include/eunit.hrl").

-define(SYSLOG_PORT, 9999).

-define(MURL, "http://foo:bar@127.0.0.1:8080/echo").
-define(MOK, #{status := {200, _}, body := <<"\"Echo\"">>}).


-define(SURL, "https://foo:bar@127.0.0.1:8080/echo").
-define(SOK, #{status := {200, _}, body := <<"\"Echo\"">>}).
-define(SOPTS, [{verify, 0},
                {keyfile, "../test/key.pem"},
                {certfile, "../test/crt.pem"}]).

%% ===================================================================
%% Simple test
%% ===================================================================
simple_test_() ->
    {setup,
     fun setup_simple/0,
     fun cleanup_simple/1,
     {inorder,
      [{timeout, 120, {"HEAD", ?_test(run_head())}},
       {timeout, 120, {"GET(none)", ?_test(run_get(none))}},
       {timeout, 120, {"GET(first)", ?_test(run_get(first))}},
       {timeout, 120, {"GET(second)", ?_test(run_get(second))}},
       {timeout, 120, {"GET(third)", ?_test(run_get(third))}},
       {timeout, 120, {"PUT", ?_test(run_put())}},
       {timeout, 120, {"POST", ?_test(run_post())}},
       {timeout, 120, {"OPTIONS", ?_test(run_options(no_auth))}},
       {timeout, 120, {"OPTIONS auth provided", ?_test(run_options(auth))}},
       {timeout, 120, {"OPTIONS CORS", ?_test(run_options(cors))}},
       {timeout, 120, {"TRACE", ?_test(run_trace())}},
       {timeout, 120, {"400(Target)", ?_test(run_400(target))}},
       {timeout, 120, {"404", ?_test(run_404())}},
       {timeout, 120, {"Unsupported(GET, restricted)", ?_test(run_405(get))}},
       {timeout, 120, {"Unsupported(PATCH)", ?_test(run_405(patch))}},
       {timeout, 120, {"Unsupported(CONNECT)", ?_test(run_405(connect))}},
       {timeout, 120, {"Unsupported(DELETE)", ?_test(run_405(delete))}},
       {timeout, 120, {"Unsupported(OPTIONS)", ?_test(run_405(options))}},
       {timeout, 120, {"Unsupported(TRACE)", ?_test(run_405(trace))}},
       {timeout, 120, {"Unsupported(WHAT)", ?_test(run_405(what))}},
       {timeout, 120, {"406", ?_test(run_406(accept))}},
       {timeout, 120, {"413(Method)", ?_test(run_413(method))}},
       {timeout, 120, {"413(Version)", ?_test(run_413(version))}},
       {timeout, 120, {"414", ?_test(run_414())}},
       {timeout, 120, {"505", ?_test(run_505())}}
      ]
     }
    }.

setup_simple() ->
    application:load(shttpd),
    log_stup(),
    SYSLOG = spawn_link(fun syslog/0),
    Echo1 = #{name => echo1,
              ip => {127, 0, 0, 1},
              port => 8080,
              listeners => 2,
              workers => 1,
              routes => [#{name => none,
                           path => <<"echo">>,
                           module => echo},
                         #{name => first,
                           path => <<"first/echo">>,
                           extra => <<"first">>,
                           module => echo},
                         #{name => second,
                           path => <<"echo/second">>,
                           extra => <<"second">>,
                           module => echo},
                         #{name => third,
                           path => <<"echo/second/third">>,
                           extra => <<"third">>,
                           module => echo}
                        ]},
    Echo2 = #{name => echo2,
              ip => "127.0.0.1",
              port => 8081,
              listeners => 1,
              routes => [#{name => none,
                           path => <<"echo">>,
                           module => echo,
                           log => false}
                        ]},
    Echo3 = #{name => echo3,
              port => 8082,
              routes => [#{name => none,
                           path => <<"echo">>,
                           module => echo,
                           methods => [head]}
                        ]},
    application:set_env(shttpd, servers, [Echo1, Echo2, Echo3]),
    application:set_env(shttpd, system, <<"foo server">>),
    application:ensure_all_started(shttpd),
    SYSLOG.

cleanup_simple(SYSLOG) ->
    ok = application:stop(shttpd),
    ok = application:unload(shttpd),
    SYSLOG ! stop,
    ok.

run_head() ->
    ?assertMatch(#{status := {204, _}},
                 shttpc:head("http://foo:bar@127.0.0.1:8080/echo",
                             #{close => true})).

run_get(none) ->
    ?assertMatch(#{status := {200, _}, body := <<"\"Echo\"">>},
                 shttpc:get("http://foo:bar@127.0.0.1:8080/echo",
                            #{close => true}));
run_get(first) ->
    ?assertMatch(#{status := {200, _}, body := <<"\"Echo:first\"">>},
                 shttpc:get("http://foo:bar@127.0.0.1:8080/first/echo",
                            #{close => true}));
run_get(second) ->
    ?assertMatch(#{status := {200, _}, body := <<"\"Echo:second\"">>},
                 shttpc:get("http://foo:bar@127.0.0.1:8080/echo/second",
                            #{close => true}));
run_get(third) ->
    ?assertMatch(#{status := {200, _}, body := <<"\"Echo:third\"">>},
                 shttpc:get("http://foo:bar@127.0.0.1:8080/echo/second/third",
                            #{close => true})).

run_put() ->
    ?assertMatch(#{status := {201, _}, body := <<>>},
                 shttpc:put("http://foo:bar@127.0.0.1:8080/echo",
                            <<>>,
                            #{close => true})).

run_post() ->
    ?assertMatch(#{status := {200, <<"OK">>}, body := <<"{\"bar\":8}">>},
                 shttpc:post("http://foo:bar@127.0.0.1:8080/echo",
                             <<"{\"bar\":7}">>,
                             #{headers => #{accept => <<"application/json">>},
                               close => true})).

run_options(no_auth) ->
    #{status := {Code, _}, headers := #{<<"allowed">> := Allowed}} =
        shttpc:options("http://127.0.0.1:8080/echo"),
    ?assertEqual(200, Code),
    ?assertEqual(<<"POST, PUT, GET, HEAD, OPTIONS, TRACE">>, Allowed);
run_options(auth) ->
    #{status := {Code, _}, headers := #{<<"allowed">> := Allowed}} =
        shttpc:options("http://foo:bar@127.0.0.1:8080/echo"),
    ?assertEqual(200, Code),
    ?assertEqual(<<"POST, PUT, GET, HEAD, OPTIONS, TRACE">>, Allowed);
run_options(cors) ->
    ReqHeaders = <<"origin, x-requested-with">>,
    Origin = <<"http://127.0.0.1">>,
    Opts = #{headers =>
                 #{<<"Access-Control-Request-Method">> => <<"GET">>,
                   <<"Access-Control-Request-Headers">> => ReqHeaders,
                   <<"Origin">> => Origin}},
    #{status := {Code, _},
      headers := #{<<"allowed">> := Allowed,
                   <<"access-control-allow-origin">> := Origin,
                   <<"access-control-allow-methods">> := Allowed,
                   <<"access-control-allow-headers">> := ReqHeaders,
                   <<"access-control-max-age">> := <<"86400">>}} =
        shttpc:options("http://127.0.0.1:8080/echo", Opts),
    ?assertEqual(200, Code),
    ?assertEqual(<<"POST, PUT, GET, HEAD, OPTIONS, TRACE">>, Allowed).

run_trace() ->
    ?assertMatch(#{status := {200,_},headers := #{<<"a_trace">> := <<"true">>}},
                 shttpc:trace("http://foo:bar@127.0.0.1:8080/echo",
                              #{headers => #{a_trace => true}})).

run_400(target) ->
    ?assertMatch({ok, <<"HTTP/1.1 400", _/binary>>},
                 send_recv("127.0.0.1",
                           8080,
                           <<"GET http# HTTP/1.1">>)).

run_404() ->
    ?assertMatch(#{status := {404, _}},
                 shttpc:get("http://foo:bar@127.0.0.1:8080/not_there")).

run_405(get) ->
    #{status := {Code, _}, headers := #{<<"allowed">> := Allowed}} =
        shttpc:patch("http://foo:bar@127.0.0.1:8082/echo", <<>>),
    ?assertEqual(405, Code),
    ?assertEqual(<<"HEAD">>, Allowed);
run_405(patch) ->
    #{status := {Code, _}, headers := #{<<"allowed">> := Allowed}} =
        shttpc:patch("http://foo:bar@127.0.0.1:8080/echo", <<>>),
    ?assertEqual(405, Code),
    ?assertEqual(<<"POST, PUT, GET, HEAD, OPTIONS, TRACE">>, Allowed);
run_405(options) ->
    #{status := {Code, _}, headers := #{<<"allowed">> := Allowed}} =
        shttpc:options("http://foo:bar@127.0.0.1:8082/echo"),
    ?assertEqual(405, Code),
    ?assertEqual(<<"HEAD">>, Allowed);
run_405(trace) ->
    #{status := {Code, _}, headers := #{<<"allowed">> := Allowed}} =
        shttpc:trace("http://foo:bar@127.0.0.1:8082/echo"),
    ?assertEqual(405, Code),
    ?assertEqual(<<"HEAD">>, Allowed);
run_405(what) ->
    ?assertMatch({ok, <<"HTTP/1.1 405", _/binary>>},
                 send_recv("127.0.0.1", 8080, <<"WHAT /echo HTTP/1.1">>));
run_405(Method) ->
    #{status := {Code, _}, headers := #{<<"allowed">> := Allowed}} =
        shttpc:Method("http://foo:bar@127.0.0.1:8080/echo"),
    ?assertEqual(405, Code),
    ?assertEqual(<<"POST, PUT, GET, HEAD, OPTIONS, TRACE">>, Allowed).

run_406(accept) ->
    ?assertMatch(#{status := {406, _}},
                 shttpc:get("http://foo:bar@127.0.0.1:8080/echo",
                            #{headers => #{accept => <<"text/html">>}})).

run_413(method) ->
    ?assertMatch({ok, <<"HTTP/1.1 413", _/binary>>},
                 send_recv("127.0.0.1",
                           8080,
                           <<"SUPERCALIFRAGILISTICEXPIALIDOCIOUS ">>));
run_413(version) ->
    ?assertMatch({ok, <<"HTTP/1.1 413", _/binary>>},
                 send_recv("127.0.0.1",
                           8080,
                           <<"GET /echo HTTP/4711.1\r\n">>)).

run_414() ->
    ?assertMatch({ok, <<"HTTP/1.1 414", _/binary>>},
                 send_recv("127.0.0.1",
                           8080,
                           <<"GET ",
                             (blist:duplicate(513, $A))/binary,
                             " HTTP/1.1">>)).

run_505() ->
    ?assertMatch({ok, <<"HTTP/1.1 505", _/binary>>},
                 send_recv("127.0.0.1",
                           8080,
                           <<"GET /echo HTTP/2.0\r\n">>)).


syslog() ->
    Transport = syslog:open([server, {port, ?SYSLOG_PORT}]),
    syslog_loop(Transport).

syslog_loop(Transport) ->
    receive
        stop -> syslog:close(Transport);
        {udp, _, _, _, Message} ->
            case syslog:decode(Message) of
                #{header := #{severity := err}, msg := #{content := Cont}} ->
                    ?debugFmt("~n~nSYSLOG: ~s~n", [Cont]),
                    ok;
                #{header := #{severity := warning}, msg := #{content:=Cont}} ->
                    ?debugFmt("~n~nSYSLOG: ~s~n", [Cont]),
                    ok;
                _ ->
                    ok
                %% #{msg := #{content:=Cont}} ->
                %%     ?debugFmt("~n~nSYSLOG: ~s~n", [Cont]),
                %%     ok
            end,
            syslog_loop(Transport)
    end.

send_recv(Server, Port, Msg) ->
    Opts = [binary, {packet, raw}, {active, false}],
    case gen_tcp:connect(Server, Port, Opts) of
        {ok, Sock} ->
            ok = gen_tcp:send(Sock, Msg),
            Result = gen_tcp:recv(Sock, 0),
            gen_tcp:close(Sock),
            Result;
        Error ->
            Error
    end.

%% ===================================================================
%% Worker test
%% ===================================================================
worker_test_() ->
    {setup,
     fun setup_worker/0,
     fun cleanup_worker/1,
     {inorder,
      [{timeout, 120, {"Serial 2", ?_test(run_serial(2, true))}},
       {timeout, 120, {"Serial 10", ?_test(run_serial(10, true))}},
       {timeout, 120, {"Multiple", ?_test(run_multiple())}}
      ]
     }
    }.

setup_worker() ->
    application:load(shttpd),
    log_stup(),
    SYSLOG = spawn_link(fun syslog/0),
    Echo = #{name => echo,
             ip => {127, 0, 0, 1},
             port => 8080,
             listeners => 2,
             workers => 2,
             routes => [#{name => echo, path => <<"echo">>, module => echo}]},
    application:set_env(shttpd, servers, [Echo]),
    application:set_env(shttpd, system, <<"Worker test">>),
    application:ensure_all_started(shttpd),
    SYSLOG.

cleanup_worker(SYSLOG) ->
    ok = application:stop(shttpd),
    ok = application:unload(shttpd),
    SYSLOG ! stop,
    ok.

run_serial(N, Close) ->
    Result = #{connection := Con} = shttpc:get(?MURL),
    ?assertMatch(?MOK, Result),
    run_serial(N - 1, Con, Close).

run_serial(1, Con, true) ->
    ?assertMatch(?MOK, shttpc:get(?MURL, #{close => true, connection => Con}));
run_serial(1, Con, false) ->
    ?assertMatch(?MOK, shttpc:get(?MURL, #{connection => Con})),
    Con;
run_serial(N, Con, Close) ->
    ?assertMatch(?MOK, shttpc:get(?MURL, #{connection => Con})),
    run_serial(N - 1, Con, Close).

run_multiple() ->
    Con1 = run_serial(4, false),
    Con2 = run_serial(4, false),
    Result = shttpc:get(?MURL),
    ?assertMatch(?MOK, Result),
    ?assertMatch(undefined, maps:get(connection, Result, undefined)),
    run_serial(4, Con1, true),
    run_serial(4, true),
    shttpc:close(Con2).


%% ===================================================================
%% Ssl test
%% ===================================================================
ssl_test_() ->
    {setup,
     fun setup_ssl/0,
     fun cleanup_ssl/1,
     {inorder,
      [{timeout, 120, {"GET", ?_test(run_ssl())}}
      ]
     }
    }.

setup_ssl() ->
    application:load(shttpd),
    log_stup(),
    SYSLOG = spawn_link(fun syslog/0),
    Echo = #{name => echo,
             ip => {127, 0, 0, 1},
             port => 8080,
             protocol => ssl,
             ssl_options => ?SOPTS,
             listeners => 2,
             workers => 2,
             routes => [#{name => echo, path => <<"echo">>, module => echo}]},
    application:set_env(shttpd, servers, [Echo]),
    application:set_env(shttpd, system, <<"Ssl test">>),
    application:ensure_all_started(shttpd),
    SYSLOG.

cleanup_ssl(SYSLOG) ->
    ok = application:stop(shttpd),
    ok = application:unload(shttpd),
    SYSLOG ! stop,
    ok.

run_ssl() -> ?assertMatch(?SOK, shttpc:get(?SURL)).

%% ===================================================================
%% Misc
%% ===================================================================

log_stup() ->
    ok.
