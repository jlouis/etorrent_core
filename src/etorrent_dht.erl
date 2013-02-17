%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc This module provides few helpers and supervise the DHT processes.
%% Starts two workers: {@link etorrent_dht_state} and {@link etorrent_dht_net}.
%% @end
-module(etorrent_dht).
-behaviour(supervisor).
-export([start_link/0,
         start_link/1,
         start_link/2,
         add_torrent/2,
         integer_id/1,
         list_id/1,
         random_id/0,
         closest_to/3,
         distance/2,
         find_self/0]).

-type nodeinfo() :: etorrent_types:nodeinfo().
-type nodeid() :: etorrent_types:nodeid().
% supervisor callbacks
-export([init/1]).

start_link() ->
    Port = etorrent_config:dht_port(),
    start_link(Port).

start_link(DHTPort) ->
    StateFile = etorrent_config:dht_state_file(),
    start_link(DHTPort, StateFile).



start_link(DHTPort, StateFile) ->
    _ = etorrent_dht_tracker:start_link(),
    SupName = {local, etorrent_dht_sup},
    SupArgs = [{port, DHTPort}, {file, StateFile}],
    supervisor:start_link(SupName, ?MODULE, SupArgs).


init(Args) ->
    Port = proplists:get_value(port, Args),
    File = proplists:get_value(file, Args),
    {ok, {{one_for_one, 1, 60}, [
        {dht_state_srv,
            {etorrent_dht_state, start_link, [File]},
            permanent, 2000, worker, dynamic},
        {dht_socket_srv,
            {etorrent_dht_net, start_link, [Port]},
            permanent, 1000, worker, dynamic}]}}.


%% @doc Announce yourself as a peer for this torrent.
add_torrent(InfoHash, TorrentID) ->
    case etorrent_config:dht() of
        false -> ok;
        true ->
            Info = integer_id(InfoHash),
            SupName = etorrent_dht_sup,
            supervisor:start_child(SupName,
                {{tracker, Info},
                    {etorrent_dht_tracker, start_link, [Info, TorrentID]},
                    permanent, 5000, worker, dynamic})
    end.

find_self() ->
    Self = etorrent_dht_state:node_id(),
    etorrent_dht_net:find_node_search(Self).

-spec integer_id(list(byte()) | binary()) -> nodeid().
integer_id(<<ID:160>>) ->
    ID;
integer_id(StrID) when is_list(StrID) ->
    integer_id(list_to_binary(StrID)).

-spec list_id(nodeid()) -> list(byte()).
list_id(ID) when is_integer(ID) ->
    binary_to_list(<<ID:160>>).

-spec random_id() -> nodeid().
random_id() ->
    Byte  = fun() -> random:uniform(256) - 1 end,
    Bytes = [Byte() || _ <- lists:seq(1, 20)],
    integer_id(Bytes).

-spec closest_to(nodeid(), list(nodeinfo()), integer()) ->
    list(nodeinfo()).
closest_to(InfoHash, NodeList, NumNodes) ->
    WithDist = [{distance(ID, InfoHash), ID, IP, Port}
               || {ID, IP, Port} <- NodeList],
    Sorted = lists:sort(WithDist),
    Limited = if
    (length(Sorted) =< NumNodes) -> Sorted;
    (length(Sorted) >  NumNodes)  ->
        {Head, _Tail} = lists:split(NumNodes, Sorted),
        Head
    end,
    [{NID, NIP, NPort} || {_, NID, NIP, NPort} <- Limited].

-spec distance(nodeid(), nodeid()) -> nodeid().
distance(BID0, BID1) when is_binary(BID0), is_binary(BID1) ->
    <<ID0:160>> = BID0,
    <<ID1:160>> = BID1,
    ID0 bxor ID1;
distance(ID0, ID1) when is_integer(ID0), is_integer(ID1) ->
    ID0 bxor ID1.
