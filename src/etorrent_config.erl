%% @author  : Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%% @doc A Gen server for the configuration in Etorrent
%% @todo Much of this code is currently in a dead state and not used.
%% There are hooks in here for runtime-configuration of Etorrent, but
%% currently it is not used: Application configuration is set via the
%% application framework of OTP.
%% @end
-module(etorrent_config).
-behaviour(gen_server).

-export([dht/0,
	 dht_port/0,
	 dht_state_file/0,
         dotdir/0,
	 dirwatch_interval/0,
	 download_dir/0,
	 fast_resume_file/0,
	 listen_port/0,
	 listen_ip/0,
	 logger_dir/0,
	 logger_file/0,
	 log_settings/0,
	 max_files/0,
	 max_peers/0,
	 max_upload_rate/0,
	 max_download_rate/0,
	 max_upload_slots/0,
	 optimistic_slots/0,
	 profiling/0,
	 udp_port/0,
	 webui/0,
	 webui_address/0,
	 webui_log_dir/0,
	 webui_port/0,
         use_upnp/0,
	 work_dir/0]).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-type file_path() :: etorrent_types:file_path().
-record(state, { conf :: [{atom(), term()}]}).

configuration_specification() ->
    [required(dir),
     optional(download_dir, required(dir)),
     optional(dirwatch_interval, 20),
     required(fast_resume_file),
     required(udp_port),
     optional(max_peers, 40),
     required(webui),
     required(webui_port),
     required(webui_bind_address),
     required(webui_logger_dir),
     optional(fs_watermark_high, 128),
     optional(max_upload_slots, auto),
     required(min_upload),
     optional(max_upload_rate, infinity),
     optional(max_download_rate, infinity),
     required(port),
     required(logger_dir),
     required(logger_fname),
     optional(listen_ip, all),
     optional(dht_port, 6882),
     optional(dht_state, "etorrent_dht_state"),
     optional(log_settings, [])].

%%====================================================================

%% @doc Start up the configuration server
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


call(Key) ->
    case gen_server:call(?MODULE, {get_param, Key}) of
	undefined ->
	   exit(no_such_application_config_value);
	V -> V
    end.

-spec work_dir() -> file_path().
work_dir() -> call(dir).

-spec dotdir() -> file_path().
dotdir() ->
    call(dotdir).

-spec download_dir() -> file_path().
download_dir() -> call(download_dir).

-spec dirwatch_interval() -> pos_integer().
dirwatch_interval() -> call(dirwatch_interval).

-spec fast_resume_file() -> file_path().
fast_resume_file() -> call(fast_resume_file).

-spec udp_port() -> pos_integer().
udp_port() -> call(udp_port).

-spec max_peers() -> pos_integer().
max_peers() -> call(max_peers).

-spec webui() -> boolean().
webui() -> call(webui).

-spec use_upnp() -> boolean().
use_upnp() -> element(2, (required(use_upnp))([])).

%% This function is calling directly, so it can be called outside the
%% start of the application. In the longer run, we should probably
%% Push profiling to be a startup option on the top-level supervisor.
-spec profiling() -> boolean().
profiling() -> element(2, (required(profiling))([])).

-spec webui_port() -> pos_integer().
webui_port() -> call(webui_port).

-spec webui_address() -> inet:ip_address().
webui_address() -> call(webui_bind_address).

-spec webui_log_dir() -> file_path().
webui_log_dir() -> call(webui_logger_dir).

-spec max_files() -> pos_integer().
max_files() -> call(fs_watermark_high).

-spec max_upload_slots() -> auto | pos_integer().
max_upload_slots() -> call(max_upload_slots).

-spec optimistic_slots() -> pos_integer().
optimistic_slots() -> call(min_upload).

-spec max_upload_rate() -> pos_integer() | infinity.
max_upload_rate() -> call(max_upload_rate).

-spec max_download_rate() -> pos_integer() | infinity.
max_download_rate() -> call(max_download_rate).

-spec listen_port() -> pos_integer().
listen_port() -> call(port).

-spec listen_ip() -> inet:ip_address().
listen_ip() -> call(listen_ip).

-spec logger_dir() -> file_path().
logger_dir() -> call(logger_dir).

-spec logger_file() -> file_path().
logger_file() -> call(logger_fname).

%% Called outside of the configuration server for now
%% @todo move inside configuration server
-spec dht() -> boolean().
dht() -> element(2, (required(dht))([])).

-spec dht_port() -> pos_integer().
dht_port() -> call(dht_port).

-spec dht_state_file() -> file_path().
dht_state_file() -> call(dht_state).

-spec log_settings() -> list().
% @todo fix this return value
log_settings() -> call(log_settings).

%%====================================================================

%% @private
init([]) ->
    {ok, #state{ conf = read_config([]) }}.

%% @private
handle_call({get_param, P}, _From, #state { conf = Conf } = State) ->
    Reply = proplists:get_value(P, Conf),
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------

%% Search the configuation and if does not have a value, search the key
required(Key) ->
    fun(Config) ->
	    case proplists:get_value(Key, Config) of
		    undefined ->
			case application:get_env(etorrent_core, Key) of
			    {ok, Value} -> {Key, Value};
			    undefined -> {Key, undefined}
			end;
		    Value ->
			{Key, Value}
		end
    end.

optional(Key, Default) ->
    fun(Config) ->
	    case proplists:get_value(Key, Config) of
		    undefined ->
			case application:get_env(etorrent_core, Key) of
			    {ok, Value} ->
				{Key, Value};
			    undefined when is_function(Default) ->
				{_, Value} = Default(Config),
                {Key, Value};
			    undefined ->
				{Key, Default}
			end;
		    Value ->
			{Key, Value}
		end
    end.


read_config(Config) ->
    [F(Config) || F <- configuration_specification()].











