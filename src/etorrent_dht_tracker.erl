%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc TODO
%% @end
-module(etorrent_dht_tracker).
-behaviour(gen_server).
-define(dht_net, etorrent_dht_net).
-define(dht_state, etorrent_dht_state).

%% API.
-export([create_common_resources/0,
         start_link/2,
         announce/1,
         tab_name/0,
         announce/3,
         get_peers/1,
         update_tracker/1,
         trigger_announce/0]).

%% gproc registry entries
-export([register_server/1,
         lookup_server/1,
         await_server/1]).


-type ipaddr() :: etorrent_types:ipaddr().
-type peerinfo() :: etorrent_types:peerinfo().
-type infohash() :: etorrent_types:infohash().
-type portnum() :: etorrent_types:portnum().
-type nodeinfo() :: etorrent_types:nodeinfo().
-type torrent_id() :: etorrent_types:torrent_id().

-record(state, {
    infohash  :: infohash(),
    torrent_id :: torrent_id(),
    btport=0  :: portnum(),
    interval=10*60*1000 :: integer(),
    timer_ref :: reference(),
    nodes=[]  :: list(nodeinfo())}).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


%% ------------------------------------------------------------------------
%% Gproc helpers

-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).

server_name(TorrentID) ->
    {etorrent, TorrentID, dht_tracker}.

%% Gproc helpers
%% ------------------------------------------------------------------------



tab_name() ->
    etorrent_dht_tracker_tab.

max_per_torrent() ->
    32.

create_common_resources() ->
    _ = case ets:info(tab_name()) of
        undefined -> ets:new(tab_name(), [named_table, public, bag]);
        _ -> ok
    end.

-spec start_link(infohash(), integer()) -> {'ok', pid()}.
start_link(InfoHash, TorrentID) when is_integer(InfoHash) ->
    Args = [{infohash, InfoHash}, {torrent_id, TorrentID}],
    gen_server:start_link(?MODULE, Args, []).

-spec announce(pid()) -> 'ok'.
announce(TrackerPid) ->
    gen_server:cast(TrackerPid, announce).


%
% Register a peer as a member of a swarm. If the maximum number of
% registered peers for a torrent is exceeded, one or more peers are
% deleted.
%
-spec announce(infohash(), ipaddr(), portnum()) -> 'true'.
announce(InfoHash, {_,_,_,_}=IP, Port)
    when is_integer(InfoHash), is_integer(Port) ->
    % Always delete a random peer when inserting a new
    % peer into the table. If limit is not reached yet, the
    % chances of deleting a peer for no good reason are lower.
    %% Do not let add duplicates.
    case ets:match(tab_name(), {InfoHash, IP, '_', '_'}) of
        [[]] ->
            lager:info("Enforce one-peer-per-IP restriction for IP=~p, IH=~p.", [IP, InfoHash]),
            true;
        [] ->
            RandPeerNum = random_peer(),
            DelSpec  = [{{InfoHash,'$1','$2',RandPeerNum},[],[true]}],
            _ = ets:select_delete(tab_name(), DelSpec),
            lager:debug("Register ~p:~p as a peer for ~s.",
                        [IP, Port, integer_hash_to_literal(InfoHash)]),
            ets:insert(tab_name(), {InfoHash, IP, Port, RandPeerNum})
    end.

%
% Get the peers that are registered as members of this swarm.
%
-spec get_peers(infohash()) -> list(peerinfo()).
get_peers(InfoHash) when is_integer(InfoHash) ->
    GetSpec = [{{InfoHash,'$1','$2','_'},[],[{{'$1','$2'}}]}],
    case ets:select(tab_name(), GetSpec, max_per_torrent()) of
        {PeerInfos, _} -> PeerInfos;
        '$end_of_table' -> []
    end.

%
% Notify all DHT-pollers that an announce should be performed
% now regardless of when the last poll was performed.
%
trigger_announce() ->
    gproc:send(poller_key(), {timeout, now, announce}),
    ok.

%% @doc Announce the torrent, controlled by the server, immediately.
update_tracker(Pid) when is_pid(Pid) ->
    Pid ! {timeout, now, announce},
    ok.


poller_key() ->
    {p, l, {etorrent, dht, poller}}.


random_peer() ->
    etorrent_utils:init_random_generator(),
    random:uniform(max_per_torrent()).

init(Args) ->
    InfoHash  = proplists:get_value(infohash, Args),
    TorrentID = proplists:get_value(torrent_id, Args),
    BTPortNum = etorrent_config:listen_port(),
    lager:debug("Starting DHT tracker for ~p (~p).", [TorrentID, InfoHash]),
    true = gproc:reg(poller_key(), TorrentID),
    register_server(TorrentID),
    %% Fetch a node-list for 30 seconds and announce for 10 seconds after it.
    %% It will decrease load during starting.
    T1 = random:uniform(30000),
    T2 = random:uniform(10000),
    erlang:send_after(T1, self(), init_nodes),
    erlang:send_after(T1+T2, self(), {timeout, undefined, announce}),
    InitState = #state{
        infohash=InfoHash,
        torrent_id=TorrentID,
        btport=BTPortNum},
    {ok, InitState}.

handle_call(_, _, State) ->
    {reply, not_implemented, State}.

handle_cast(init_timer, State) ->
    #state{interval=Interval} = State,
    TRef = erlang:start_timer(Interval, self(), announce),
    NewState = State#state{timer_ref=TRef},
    {noreply, NewState}.
%
% Initialize a small table of node table with the nodes that
% are the closest to the info-hash of this torrent. The routing
% table cannot be used because it keeps a list of the nodes that
% are close to the id of this node.
%
handle_info(init_nodes, State) ->
    #state{infohash=InfoHash} = State,
%   Nodes = ?dht_net:find_node_search(TorrentID),
    Nodes = ?dht_net:find_node_search(InfoHash),
    InitNodes = cut_list(16, Nodes),
    NewState = State#state{nodes=InitNodes},
    {noreply, NewState};

%
% Send announce messages to the nodes that are the closest to the info-hash
% of this torrent. Always perform an iterative search to find nodes acting
% as trackers for this torrent (this might not be such a good idea though)
% and add the peers that were found to the local list of peers for this torrent.
%
handle_info({timeout, _, announce}, State) ->
    #state{
        infohash=InfoHash,
        torrent_id=TorrentID,
        btport=BTPort,
        nodes=InitNodes} = State,
    lager:debug("Handle DHT timeout for ~p.", [TorrentID]),
    % If the list of nodes contains less than 16 nodes, complete the list of
    % nodes to base the get_peers search on with nodes from the routing table.
    Nodes = case length(InitNodes) < 16 of
        false ->
            InitNodes;
        true ->
            Additional = ?dht_state:closest_to(InfoHash, 16),
            cut_list(16, InitNodes ++ Additional)
    end,


    % Schedule a timer reset later
    _ = gen_server:cast(self(), init_timer),
    _ = lager:info("Sending DHT announce (to ~w nodes)", [length(Nodes)]),
    {Trackers, Peers, AllNodes} = ?dht_net:get_peers_search(InfoHash, Nodes),
    _ = lager:info("Sent DHT announce (found ~w peers)", [length(Peers)]),
    _ = lager:info("Number of DHT nodes with peers: ~w", [length(Trackers)]),


    % Send an announce to all nodes that were already acting as trackers for this node
    _ = [?dht_net:announce(IP, Port, InfoHash, Token, BTPort)
        || {_, IP, Port, Token} <- Trackers],

    % Keep the 16 nodes that are the cloesest to the info-hash of this torrent
    % and use them as the root of the next announce. If any of the nodes were
    % not tracker nodes, make an announce immidiately. Since the token that was
    % returned in the previous get_peers'response was not saved, request a new one.
    TrackerAddrs = [{IP, Port} || {_, IP, Port, _} <- Trackers],
    NextTrackers = cut_list(16, AllNodes),
    NewTrackers  = [{IP, Port} || {_, IP, Port} <- NextTrackers,
                    not lists:member({IP, Port}, TrackerAddrs)],
    [case ?dht_net:get_peers(IP, Port, InfoHash) of
         {error, timeout} -> ok;
         {_, Token, _, _} ->
            ?dht_net:announce(IP, Port, InfoHash, Token, BTPort)
     end || {IP, Port} <- NewTrackers],

    lager:debug("Adding peers ~p.", [Peers]),
    ok = etorrent_peer_mgr:add_peers(TorrentID, Peers),
    NewState = State#state{nodes=NextTrackers},
    {noreply, NewState}.


terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

cut_list(N, List) ->
    lists:sublist(List, N).


integer_hash_to_literal(InfoHashInt) when is_integer(InfoHashInt) ->
    io_lib:format("~40.16.0B", [InfoHashInt]).

