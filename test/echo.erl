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
-module(echo).
-copyright('Jan Henry Nystrom <JanHenryNystrom@gmail.com>').

%% Authorization
-export([basic/3]).

%% Methods
-export([head/1, get/1, put/1, post/1]).

%% ===================================================================
%% Authorization
%% ===================================================================

basic(#{user := <<"foo">>, password := <<"bar">>}, _, _) -> ok;
basic(_, _, _) -> <<"Echo">>.

%% ===================================================================
%% Methods
%% ===================================================================

head(_) -> 204.

get(#{extra := undefined}) -> #{code => 200, body => <<"\"Echo\"">>};
get(#{extra := Extra}) -> #{code => 200, json => <<"Echo:", Extra/binary>>}.

put(_) -> 201.

post(#{json := JSON}) ->
    #{code => 200,
      json => maps:fold(fun(K, V, Acc) -> Acc#{K => V + 1} end, #{}, JSON)}.
