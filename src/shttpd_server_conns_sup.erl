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
-module(shttpd_server_conns_sup).
-copyright('Jan Henry Nystrom <JanHenryNystrom@gmail.com>').

-behaviour(supervisor).

%% Management API
-export([start_link/1]).

%% supervisor callbacks
-export([init/1]).

%% ===================================================================
%% Management API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: start_link(Server) -> {ok, Pid}
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
init(Server) -> {ok, {{one_for_one, 2, 3600}, listeners(Server)}}.

%% ===================================================================
%% Internal functions.
%% ===================================================================

listeners(Server = #{listeners := Conns}) ->
    [conn(Id, Server) || Id <- lists:seq(1, Conns)];
listeners(Server) ->
    [conn(1, Server)].

conn(Id, Server) ->
    {Id, {shttpd_server_conn, start_link, [Server]},
     permanent, 5000, worker, [shttpd_server_conn]}.
