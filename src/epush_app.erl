%%%-------------------------------------------------------------------
%% @doc epush public API
%% @end
%%%-------------------------------------------------------------------

-module(epush_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("apns/include/apns.hrl").
-include_lib("eutil/include/eutil.hrl").

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    case epush_sup:start_link() of
        {error, _} = E ->
            E;
        R ->
            init(),
            R
    end.

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
init() ->
    ets:new(epush_confs, [named_table, public, set, {read_concurrency,true}]),
    epush_statistics:start_link(),
    start_workers(),
    start_websvr(),
    ?INFO_MSG("epush app start's init done"),
    ok.

start_websvr() ->
    {ok, HttpPort} = application:get_env(epush, http_port),
    Dispatch = cowboy_router:compile([
                                      {'_', [{"/push", epush_websvr, []}]}
                                     ]),
    {ok, _} = cowboy:start_http(http, 100, [{port, HttpPort}],
                                [{env, [{dispatch, Dispatch}]},
                                 {timeout, 30000}
                                ]
                               ),
    ok.

start_workers() ->
    {ok, PushConfs} = application:get_env(epush, push_confs),
    [start_worker(Conf) || Conf <- PushConfs],
    ok.

start_worker(#{id:=Id, type:=apns, pool_size:=PoolSize, cert_file:=CertFile,
               is_sandbox_env:=IsSandbox}=Conf) ->
    {AppleHost, FeedbackHost} = case IsSandbox of
                                    true -> {"gateway.sandbox.push.apple.com", "feedback.sandbox.push.apple.com"};
                                    false -> {"gateway.push.apple.com", "feedback.push.apple.com"}
                                end,
    DefConn = apns:default_connection(),
    ApnsConn = DefConn#apns_connection{cert_file = CertFile, apple_host = AppleHost,
                                       feedback_host = FeedbackHost,
                                       error_fun = fun epush_apns:handle_apns_error/2,
                                       feedback_fun = fun epush_apns:handle_apns_delete_subscription/1
                                      },
    apns:connect(eutil:to_atom(Id), ApnsConn),
    put_push_conf(Id, Conf);
start_worker(#{id:=Id, type:=xiaomi, pkg_name:=PkgName, app_secret:=AppSecret,
               pool_size:=PoolSize}=Conf) ->
    State = #{type=>xiaomi, pkg_name=>PkgName, app_secret=>AppSecret},
    put_push_conf(Id, Conf);
start_worker(#{id:=Id, type:=huawei, app_id:=AppId, app_secret:=AppSecret,
               pool_size:=PoolSize}=Conf) ->
    State = #{type=>huawei, app_id=>AppId, app_secret=>AppSecret},
    put_push_conf(Id, Conf);
start_worker(#{id:=Id, type:=fcm, api_key:=ApiKey, proxy:=Proxy,
               pool_size:=PoolSize}=Conf) ->
    State = #{type=>fcm, api_key=>eutil:to_binary(ApiKey), proxy=>Proxy},
    put_push_conf(Id, Conf);
start_worker(#{id:=Id, type:=flyme, app_id:=AppId, app_secret:=AppSecret,
               pool_size:=PoolSize}=Conf) ->
    State = #{type=>flyme, app_id=>AppId, app_secret=>AppSecret},
    put_push_conf(Id, Conf);
start_worker(#{id:=Id, type:=yunpian, apikey:=Apikey, pool_size:=PoolSize}=Conf) ->
    State = #{type=>yunpian, apikey=>Apikey},
    put_push_conf(Id, Conf),
    ok.

put_push_conf(Id, Conf) ->
    eutil:put_ets(epush_confs, {push_confs, eutil:to_binary(Id)}, Conf).
