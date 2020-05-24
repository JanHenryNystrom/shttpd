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

%% Defines
-define(HAS_BODY, [post, put, patch]).

%% Records
-record(state, {name :: atom(),
                system :: binary(),
                worker = false :: boolean(),
                protocol :: tcp | ssl,
                ip :: string(),
                port :: integer(),
                ssl_options :: _,
                timeout :: integer(),
                routes :: [{atom(), [method()]}],
                prefix_name :: atom(),
                %% StatsD
                statsd_server :: boolean(),
                %% Sockets
                listen_socket :: gen_tcp:socket() | ssl:socket(),
                ref :: reference(),
                socket :: gen_tcp:socket() | ssl:socket(),
                accept_timer :: reference(),
                %% Request
                start :: integer(),
                limit :: integer(),
                method :: atom(),
                headers = [] :: plist:plist(),
                url :: binary(),
                query :: binary(),
                fragment :: binary(),
                body = <<>> :: binary(),
                %% Header
                authorization,
                content_length = 0 :: integer(),
                content_encoding = identity :: atom(),
                accept_encoding = identity :: atom(),
                x_correlation_id :: binary(),
                close = false :: boolean(),
                %% Routing
                route :: atom(),
                module :: atom(),
                allowed :: [atom()],
                bindings :: [{atom(), _}],
                extra :: _,
                log = true :: boolean()
               }).

%% Types
-type method() :: atom().
