%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Supervise a peer
%% <p>This module represents a peer. It spawns a supervisor, which in
%% turn spawns 3 gen_servers: one for sending, one for receiving and
%% one for control.</p>
%% <p>The supervisor has a very aggressive termination policy. Any
%% error will terminate the peer totally. This is deliberate: we have
%% other peers we could try, so if there is an error with this peer,
%% it shouldn't really try to keep it around. We'll just try another.</p>
%% <p>Exit of any child with any reason (even `normal') will cause the death
%% of this supervisor with reason `reached_max_restart_intensity'.</p>
%% @end
-module(etorrent_peer_sup).
-behaviour(supervisor).

%% API
-export([start_link/8]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().
-type capabilities() :: etorrent_types:capabilities().

%% ====================================================================

%% @doc Start the peer
%% <p>A peer is fed with quite a lot of data. It gets tracker url, our
%% local `PeerId', it gets the `InfoHash', the Torrents `TorrentId', the pair
%% `{IP, Port}' of the remote peer, what `Capabilities' the peer supports
%% and a `Socket' for communication.</p>
%% <p>From that a supervisor for the peer and accompanying processes
%% are spawned.</p>
%% @end
-spec start_link(string(), binary(), binary(),
                 binary(), integer(), {ipaddr(), portnum()},
                 [capabilities()], port()) ->
            {ok, pid()} | ignore | {error, term()}.
start_link(TrackerUrl, LocalPeerId, RemotePeerId, InfoHash,
           TorrentId, {IP, Port}, Capabilities, Socket) ->
    Params = [TrackerUrl, LocalPeerId, RemotePeerId, InfoHash, TorrentId,
              {IP, Port}, Capabilities, Socket],
    supervisor:start_link(?MODULE, Params).

%% ====================================================================

%% @private
init([TrackerUrl, LocalPeerId, RemotePeerId, InfoHash,
      TorrentId, {IP, Port}, Caps, Socket]) ->
    Control = {control, {etorrent_peer_control, start_link,
                          [TrackerUrl, LocalPeerId, RemotePeerId,
                           InfoHash, TorrentId, {IP, Port}, Caps, Socket]},
                permanent, 5000, worker, [etorrent_peer_control]},
    Receiver = {receiver, {etorrent_peer_recv, start_link,
                          [TorrentId, Socket]},
                permanent, 5000, worker, [etorrent_peer_recv]},
    Sender   = {sender,   {etorrent_peer_send, start_link,
                          [Socket, TorrentId, false]},
                permanent, 5000, worker, [etorrent_peer_send]},
    {ok, {{one_for_all, 0, 1}, [Control, Sender, Receiver]}}.
