-module(router_channel_http_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([http_test/1, http_update_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-define(CONSOLE_URL, <<"http://localhost:3000">>).
-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).
-define(ETS, ?MODULE).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [http_test, http_update_test].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

http_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(Swarm,
                                                   Address,
                                                   router_handler_test:version(),
                                                   router_handler_test,
                                                   [self()]),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, JoinNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for console repor status sent
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"activation">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    %% Waiting for reply resp form router
    test_utils:wait_state_channel_message(250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),
    %% Send CONFIRMED_UP frame packet needing an ack back
    Stream ! {send, test_utils:frame_packet(?CONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 0,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),
    test_utils:wait_state_channel_message(?REPLY_DELAY + 250),

    %% Adding a message to queue
    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    Msg = {false, 1, <<"somepayload">>},
    router_device_worker:queue_message(WorkerPid, Msg),
    timer:sleep(200),
    {ok, Device1} = router_device:get(DB, CF, WorkerID),
    ?assertEqual([Msg], router_device:queue(Device1)),

    %% Sending UNCONFIRMED_UP frame packet and then we should get back message that was in queue
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 1,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"ack">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 1,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 1,
                                            <<"frame_down">> => 1,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),
    {ok, _} = test_utils:wait_state_channel_message(Msg, Device0, erlang:element(3, Msg), ?UNCONFIRMED_DOWN, 0, 0, 1, 1),

    {ok, Device2} = router_device:get(DB, CF, WorkerID),
    ?assertEqual([], router_device:queue(Device2)),

    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 2, #{body => <<1:8/integer, "reply">>})},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"payload">> => base64:encode(<<"reply">>),
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 2,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"down">>,
                                           <<"frame_up">> => 1,
                                           <<"frame_down">> => 2,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 2,
                                            <<"frame_down">> => 2,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 5,
                                            <<"payload">> => base64:encode(<<"reply">>),
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),
    %% Message shoud come in fast as it is already in the queue no neeed to wait
    {ok, _Reply1} = test_utils:wait_state_channel_message({true, 1, <<"ack">>}, Device0, <<"ack">>, ?CONFIRMED_DOWN, 0, 0, 1, 2),
    ok.

http_update_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    Swarm = proplists:get_value(swarm, Config),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(Swarm,
                                                   Address,
                                                   router_handler_test:version(),
                                                   router_handler_test,
                                                   [self()]),
    PubKeyBin = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin)),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin, AppKey, JoinNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for console repor status sent
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"activation">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),
    %% Waiting for reply resp form router
    test_utils:wait_state_channel_message(250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),
    %% Send UNCONFIRMED_UP frame packet
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 0,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),

    Tab = proplists:get_value(ets, Config),
    HTTPChannel = #{<<"type">> => <<"http">>,
                     <<"credentials">> => #{<<"headers">> => #{},
                                            <<"endpoint">> => <<"http://localhost:3000/BAD">>,
                                            <<"method">> => <<"PUT">>},
                     <<"show_dupes">> => false,
                     <<"id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                     <<"name">> => ?CONSOLE_HTTP_CHANNEL_NAME},
    ets:insert(Tab, {channels, [HTTPChannel]}),
    {ok, WorkerPid} = router_devices_sup:maybe_start_worker(WorkerID, #{}),
    WorkerPid ! refresh_channels,
    timer:sleep(250),

    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => <<"Correcting channel mask in response to 0">>,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"down">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 1,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName)}),

    %% Send UNCONFIRMED_UP frame packet
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},
    test_utils:wait_report_channel_status(#{<<"status">> => <<"failure">>,
                                            <<"description">> => <<"ResponseCode: 404 Body Not Found">>,
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 1,
                                            <<"frame_down">> => 1,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
