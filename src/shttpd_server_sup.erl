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
-module(shttpd_server_sup).
-copyright('Jan Henry Nystrom <JanHenryNystrom@gmail.com>').

-behaviour(supervisor).

%% Master API
-export([conns/1]).

%% Management API
-export([start_link/1]).

%% supervisor callbacks
-export([init/1]).

%% ===================================================================
%% Master API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: conns(Pid) -> Pids
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec conns(pid()) -> [pid()].
%%--------------------------------------------------------------------
conns(Sup) ->
    [Sup1] = [C || {shttpd_server_conns_sup, C, _, _}
                       <- supervisor:which_children(Sup)],
    [C || {_, C, _, _} <- supervisor:which_children(Sup1), is_pid(C)].

%% ===================================================================
%% Management API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: start_link(Map) -> {ok, Pid}
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link(map()) -> {ok, pid()} | ignore | {error, _}.
%%--------------------------------------------------------------------
start_link(Server) -> supervisor:start_link(?MODULE, Server).

%% ===================================================================
%% supervisor callbacks
%% ===================================================================

%%--------------------------------------------------------------------
-spec init(map()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
%%--------------------------------------------------------------------
init(Server = #{name := Name, routes := Routes}) ->
    Prefix =
        <<"shttpd_server_", (atom_to_binary(Name, utf8))/binary, "_prefix">>,
    Server1 = server_ip(Server),
    PrefixName = binary_to_atom(Prefix, utf8),
    Server2 = Server1#{prefix_name => PrefixName},
    Server3 = Server1#{routes => routes(Routes), prefix_name => PrefixName},
    {ok, {{rest_for_one, 2, 3600},
          [child(shttpd_server_master, worker, [self(), Server2]),
           child(shttpd_server_conns_sup, supervisor, [Server3]),
           child(shttpd_server_workers_sup, supervisor, [Server3])
          ]}}.

%% ===================================================================
%% Internal functions.
%% ===================================================================

child(Module, worker, Args) ->
    {Module, {Module, start_link, Args}, permanent, 5000, worker, [Module]};
child(Module, supervisor, Args) ->
    {Module, {Module, start_link, Args},
     permanent, infinity, supervisor, [Module]}.

routes(Routes) ->
    [{Name, exports(Module)} || #{name := Name, module := Module} <- Routes].

exports(Module) ->
    Exports = Module:module_info(exports),
    #{methods => methods(Exports, [options, trace]),
      authentications => authentications(Exports, [])}.

methods([], Acc) -> Acc;
methods([{get, 1} | T], Acc) -> methods(T, [get | Acc]);
methods([{head, 1} | T], Acc) -> methods(T, [head | Acc]);
methods([{post, 1} | T], Acc) -> methods(T, [post | Acc]);
methods([{put, 1} | T], Acc) -> methods(T, [put | Acc]);
methods([{patch, 1} | T], Acc) -> methods(T, [patch | Acc]);
methods([{delete, 1} | T], Acc) -> methods(T, [delete | Acc]);
methods([{connect, 1} | T], Acc) -> methods(T, [connect | Acc]);
methods([{options, 1} | T], Acc) -> methods(T, [options | Acc]);
methods([{trace, 1} | T], Acc) -> methods(T, [trace | Acc]);
methods([_ | T], Acc) -> methods(T, Acc).

authentications([], Acc) -> Acc;
authentications([{basic, 3} | T], Acc) -> authentications(T, [basic | Acc]);
authentications([{anonymous, 0}|T],Acc) -> authentications(T,[anonymous|Acc]);
authentications([_ | T], Acc) -> authentications(T, Acc).

server_ip(Server = #{ip := {_, _, _, _}}) -> Server;
server_ip(Server = #{ip := {_, _, _, _, _, _, _, _}}) -> Server;
server_ip(Server = #{ip := IP}) -> Server#{ip => ip_addr:decode(IP, [tuple])};
server_ip(Server) -> Server#{ip => {127, 0, 0, 1}}.
