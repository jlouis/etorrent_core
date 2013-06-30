%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a torrent file.
%% <p>This supervisor controls a single torrent download. It sits at
%% the top of the supervisor tree for a torrent.</p>
%% @end
-module(etorrent_magnet_sup).
-behaviour(supervisor).

%% API
-export([start_link/5]).

%% Supervisor callbacks
-export([init/1]).


%% =======================================================================

%% @doc Start up the supervisor
%% @end
-spec start_link(binary(), binary(), integer(), [[string()]], list()) ->
                {ok, pid()} | ignore | {error, term()}.
start_link(TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options)
        when is_binary(TorrentIH), is_binary(LocalPeerID), is_integer(TorrentID) ->
    supervisor:start_link(?MODULE, [TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options]).

    
%% ====================================================================

%% @private
init([<<IntIH:160>> = BinIH, LocalPeerID, TorrentID, UrlTiers, Options]) ->
    lager:debug("Init torrent magnet supervisor #~p.", [TorrentID]),
    etorrent_tracker:register_torrent(TorrentID, UrlTiers, self()),
    Control =
        {control,
            {etorrent_magnet_ctl, start_link,
             [BinIH, LocalPeerID, TorrentID, UrlTiers, Options]},
            permanent, 5000, worker, [etorrent_magnet_ctl]},
    PeerPool =
        {peer_pool_sup,
            {etorrent_magnet_peer_pool, start_link, [TorrentID]},
            transient, 5000, supervisor, [etorrent_magnet_peer_pool]},
    Tracker =
        [{tracker_communication,
         {etorrent_tracker_communication, start_link,
            [BinIH, LocalPeerID, TorrentID, Options]},
         transient, 15000, worker, [etorrent_tracker_communication]}
         || not etorrent_tracker:is_trackerless(TorrentID)],
    DhtEnabled = etorrent_config:dht(),
    AzDhtEnabled = etorrent_config:azdht(),
    MdnsEnabled = etorrent_config:mdns(),
    lager:info("DHT is ~s.", [case DhtEnabled of true -> "enabled";
                                                false -> "disabled" end]),
    DhtTracker = [{dht_tracker,
                {etorrent_dht_tracker, start_link, [IntIH, TorrentID]},
                transient, 5000, worker, dynamic} || DhtEnabled],
    AzDhtTracker = [{azdht_tracker,
            {etorrent_azdht_tracker, start_link, [BinIH, TorrentID]},
                transient, 5000, worker, dynamic} || AzDhtEnabled],
    MdnsTracker = [{mdns_tracker,
                {etorrent_mdns_tracker, start_link, [BinIH, TorrentID]},
                transient, 5000, worker, dynamic} || MdnsEnabled],
    Children = [Control, PeerPool]
               ++ Tracker
               ++ DhtTracker
               ++ AzDhtTracker
               ++ MdnsTracker,
    {ok, {{one_for_all, 1, 60}, Children}}.

