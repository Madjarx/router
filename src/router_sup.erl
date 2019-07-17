%%%-------------------------------------------------------------------
%% @doc router top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(router_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SUP(I, Args), 
        #{
          id => I,
          start => {I, start_link, Args},
          restart => permanent,
          shutdown => 5000,
          type => supervisor,
          modules => [I]
         }).

-define(WORKER(I, Args), 
        #{
          id => I,
          start => {I, start_link, Args},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [I]
         }).

-define(WORKER(I, Mod, Args), 
        #{
          id => I,
          start => {Mod, start_link, Args},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [I]
         }).

-define(FLAGS, 
        #{
          strategy => one_for_all,
          intensity => 1,
          period => 5
         }).


-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    application:ensure_all_started(ranch),
    application:ensure_all_started(lager),
    P2PWorker = ?WORKER(router_p2p, [#{}]),
    {ok, { ?FLAGS, [P2PWorker]} }.

%%====================================================================
%% Internal functions
%%====================================================================
