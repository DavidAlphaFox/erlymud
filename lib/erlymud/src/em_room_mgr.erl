%%% =========================================================================
%%% @author Johan Warlander <johan@snowflake.nu>
%%% @copyright 2010-2011 Johan Warlander
%%% @doc Manage the room database.
%%% Handle room lookups, loading/instantiation, deletion etc.
%%% @end
%%% =========================================================================
-module(em_room_mgr).

-behaviour(gen_server).

-export([start_link/0, get_room/1, new_room/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TABLE_ID, ?MODULE).

-record(state, {}).

%% API

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% Concurrent lookup if room is loaded; call to em_room_mgr otherwise.
get_room(Name) ->
  case ets:lookup(?TABLE_ID, Name) of
    [{Name, Room}] ->
      case is_process_alive(Room) of
        true ->
          {ok, Room};
        false ->
          gen_server:call(?SERVER, {get_room, Name})
      end;
    [] ->
      gen_server:call(?SERVER, {get_room, Name})
  end.

new_room(Name) ->
  gen_server:call(?SERVER, {new_room, Name}).

%% gen_server callbacks

init([]) ->
  ets:new(?TABLE_ID, [protected, named_table]),
  refresh(em_room_pool_sup:which_children()),
  {ok, #state{}}.

handle_call({get_room, Name}, _From, State) ->
  case try_load_room(Name) of
    {ok, Room} ->
      {reply, {ok, Room}, State};
    {error, not_found} ->
      {reply, {error, not_found}, State}
  end;
handle_call({new_room, Name}, _From, State) ->
  Result = do_new_room(Name),
  {reply, Result, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% Internal functions

do_new_room(Name) ->
  case ets:lookup(?TABLE_ID, Name) of
    [{_Name, _Room}] ->
      {error, room_exists};
    [] ->
      case try_load_room(Name) of
        {ok, _Room} ->
          {error, room_exists};
        {error, not_found} ->
          make_new_room(Name)
      end
  end.

make_new_room(Name) ->
  Title = "A non-descript room",
  Brief = "This is a rather boring room, someone should fix that.",
  {ok, Room} = em_room_pool_sup:start_child(Name, Title, Brief),
  ets:insert(?TABLE_ID, {Name, Room}),
  {ok, Room}.

refresh([]) ->
  ok;
refresh([{_, undefined, _, _}|Children]) ->
  refresh(Children);
refresh([{_, Room, worker, [em_room]}|Children]) ->
  Name = em_room:get_name(Room),
  ets:insert(?TABLE_ID, {Name, Room}),
  refresh(Children).

try_load_room(Name) ->
  RoomFile = filename:join([em_game:data_dir(), "rooms", 
                            Name ++ ".dat"]),
  load_room(RoomFile).

load_room(Filename) ->
  io:format("loading: ~s~n", [Filename]),
  case file:consult(Filename) of
    {ok, Data} ->
      {Name, Room} = make_room(Filename, Data),
      ets:insert(?TABLE_ID, {Name, Room}),
      {ok, Room};
    {error, _Reason} ->
      {error, not_found}
  end.
 
make_room(Filename, Data) ->
  Name = extract_name(string:tokens(Filename, "/")),
  {title, Title} = lists:keyfind(title, 1, Data),
  {desc, Desc} = lists:keyfind(desc, 1, Data),
  {exits, Exits} = lists:keyfind(exits, 1, Data),
  Long = case lists:keyfind(long, 1, Data) of
           {long, What} -> What;
           false -> undefined
         end,
  Resets = proplists:get_value(objects, Data, []),
  Obs = em_object:load_obs(Resets),
  {ok, Room} = em_room_pool_sup:start_child(Name, Title, Desc),
  em_room:set_long(Room, Long),
  add_exits(Room, Exits),
  add_objects(Room, Obs),
  add_resets(Room, Resets),
  {Name, Room}.

add_objects(Room, []) ->
  Room;
add_objects(Room, [Ob|Obs]) ->
  em_room:add_object(Room, Ob),
  add_objects(Room, Obs).

add_exits(Room, []) ->
  Room;
add_exits(Room, [{Dir, Dest}|Exits]) ->
  em_room:add_exit(Room, Dir, Dest),
  add_exits(Room, Exits).

add_resets(Room, []) ->
  Room;
add_resets(Room, [Reset|Resets]) ->
  em_room:add_reset(Room, Reset),
  add_resets(Room, Resets).

extract_name([Basename]) ->
  re:replace(Basename, "\.dat$", "", [{return, list}]);
extract_name([_|T]) ->
  extract_name(T).
