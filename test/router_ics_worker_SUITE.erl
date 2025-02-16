-module(router_ics_worker_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../src/grpc/autogen/server/iot_config_pb.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    main_test/1
]).

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
    [
        main_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    persistent_term:put(router_test_ics_service, self()),
    _ = application:ensure_all_started(grpcbox),
    Port = 8085,
    {ok, ServerPid} = grpcbox:start_server(#{
        grpc_opts => #{
            service_protos => [iot_config_pb],
            services => #{'helium.iot_config.route' => router_test_ics_service}
        },
        listen_opts => #{port => Port, ip => {0, 0, 0, 0}}
    }),
    ok = application:set_env(
        router,
        ics,
        #{host => "localhost", port => Port},
        [{persistent, true}]
    ),
    test_utils:init_per_testcase(TestCase, [{ics_server, ServerPid} | Config]).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config),
    gen_server:stop(proplists:get_value(ics_server, Config)),
    _ = application:stop(grpcbox),
    ok = application:set_env(
        router,
        ics,
        #{},
        [{persistent, true}]
    ),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

main_test(_Config) ->
    meck:new(router_console_api, [passthrough]),
    meck:new(router_device_cache, [passthrough]),

    ID1 = router_utils:uuid_v4(),
    Device1 = router_device:update(
        [
            {app_eui, <<1:64/integer-unsigned-big>>},
            {dev_eui, <<1:64/integer-unsigned-big>>}
        ],
        router_device:new(ID1)
    ),
    ID2 = router_utils:uuid_v4(),
    Device2 = router_device:update(
        [
            {app_eui, <<1:64/integer-unsigned-big>>},
            {dev_eui, <<2:64/integer-unsigned-big>>}
        ],
        router_device:new(ID2)
    ),
    Devices = #{
        ID1 => Device1,
        ID2 => Device2
    },

    meck:expect(router_console_api, get_device, fun(DeviceID) ->
        lager:notice("router_console_api:get_device(~p)", [DeviceID]),
        {ok, maps:get(DeviceID, Devices)}
    end),

    meck:expect(router_device_cache, get, fun(DeviceID) ->
        lager:notice("router_device_cache:get(~p)", [DeviceID]),
        {ok, maps:get(DeviceID, Devices)}
    end),

    [{Type1, Req1}, {Type0, _Req0}] = rcv_loop([]),
    ?assertEqual(list, Type0),
    ?assertEqual(euis, Type1),
    ?assertEqual(update_euis, Req1#route_euis_req_v1_pb.action),
    ?assertEqual([#eui_v1_pb{app_eui = 8589934593, dev_eui = 1}], Req1#route_euis_req_v1_pb.euis),

    ok = router_ics_worker:add([ID1]),

    [{Type2, Req2}] = rcv_loop([]),
    ?assertEqual(euis, Type2),
    ?assertEqual(add_euis, Req2#route_euis_req_v1_pb.action),
    ?assertEqual([#eui_v1_pb{app_eui = 1, dev_eui = 1}], Req2#route_euis_req_v1_pb.euis),

    ok = router_ics_worker:remove([ID2]),

    [{Type3, Req3}] = rcv_loop([]),
    ?assertEqual(euis, Type3),
    ?assertEqual(remove_euis, Req3#route_euis_req_v1_pb.action),
    ?assertEqual([#eui_v1_pb{app_eui = 1, dev_eui = 2}], Req3#route_euis_req_v1_pb.euis),

    meck:expect(router_console_api, get_device, fun(DeviceID) ->
        lager:notice("router_console_api:get_device(~p)", [DeviceID]),
        case DeviceID of
            ID1 -> {error, not_found};
            ID2 -> {ok, maps:get(ID2, Devices)}
        end
    end),

    meck:expect(router_device_cache, get, fun(DeviceID) ->
        lager:notice("router_console_api:get_device(~p)", [DeviceID]),
        case DeviceID of
            ID1 -> {ok, maps:get(ID1, Devices)};
            ID2 -> {error, not_found}
        end
    end),

    ok = router_ics_worker:update([ID1, ID2]),

    [{Type5, Req5}, {Type4, Req4}] = rcv_loop([]),
    ?assertEqual(euis, Type5),
    ?assertEqual(add_euis, Req5#route_euis_req_v1_pb.action),
    ?assertEqual([#eui_v1_pb{app_eui = 1, dev_eui = 2}], Req5#route_euis_req_v1_pb.euis),
    ?assertEqual(euis, Type4),
    ?assertEqual(remove_euis, Req4#route_euis_req_v1_pb.action),
    ?assertEqual([#eui_v1_pb{app_eui = 1, dev_eui = 1}], Req4#route_euis_req_v1_pb.euis),

    meck:unload(router_console_api),
    meck:unload(router_device_cache),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

rcv_loop(Acc) ->
    receive
        {router_test_ics_service, Type, Req} ->
            lager:notice("got router_test_ics_service ~p req ~p", [Type, Req]),
            rcv_loop([{Type, Req} | Acc])
    after timer:seconds(2) -> Acc
    end.
