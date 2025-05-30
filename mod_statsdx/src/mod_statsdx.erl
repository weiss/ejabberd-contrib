%%%----------------------------------------------------------------------
%%% File    : mod_statsdx.erl
%%% Author  : Badlop <badlop@ono.com>
%%% Purpose : Calculates and gathers statistics actively
%%% Created :
%%% Id      : $Id: mod_statsdx.erl 1118 2011-07-11 17:16:30Z badlop $
%%%----------------------------------------------------------------------

%%%% Definitions

-module(mod_statsdx).
-author('badlop@ono.com').

-behaviour(gen_mod).

-export([start/2, stop/1, depends/2, mod_opt_type/1, mod_options/1, mod_doc/0, mod_status/0]).
-export([loop/1, get_statistic/2,
	 pre_uninstall/0,
	 received_response/3, received_response/7,
	 %% Commands
	 getstatsdx/1, getstatsdx/2,
	 get_top_users/2,
	 %% WebAdmin
	 web_menu_main/2, web_page_main/2,
	 web_menu_node/3, web_page_node/3,
         web_page_node/5, % ejabberd 24.02 or older
	 web_menu_host/3, web_page_host/3,
	 web_user/4,
	 %% Hooks
	 register_user/2, remove_user/2, %user_send_packet/1,
         user_send_packet_traffic/1, user_receive_packet_traffic/1,
	 %%user_logout_sm/3,
	 request_iqversion/4,
	 user_login/1, user_logout/2]).

-include("ejabberd_commands.hrl").
-include_lib("xmpp/include/xmpp.hrl").
-include("logger.hrl").
-include("mod_roster.hrl").
-include("ejabberd_http.hrl").
-include("ejabberd_web_admin.hrl").
-include("translate.hrl").

-define(XCTB(Name, Text), ?XCT(list_to_binary(Name), list_to_binary(Text))).

-define(PROCNAME, ejabberd_mod_statsdx).

%% Copied from ejabberd_s2s.erl Used in function get_s2sconnections/1
-record(s2s, {fromto :: {binary(), binary()},
              pid    :: pid()}).

%%%==================================
%%%% Module control

start(Host, Opts) ->
    Hooks = gen_mod:get_opt(hooks, Opts),
    %% Default value for the counters
    CD = case Hooks of
	     true -> 0;
	     traffic -> 0;
	     false -> "disabled"
	 end,
    case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
        false ->
            ejabberd_commands:register_commands(?MODULE, commands());
        true ->
            ok
    end,
    %% If the process that handles statistics for the server is not started yet,
    %% start it now
    case whereis(?PROCNAME) of
	undefined ->
	    application:start(os_mon),
	    initialize_stats_server();
	_ ->
	    ok
    end,
    ?PROCNAME ! {initialize_stats, Host, Hooks, CD},
    ok.

stop(Host) ->
    finish_stats(Host),
    case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
        false ->
            ejabberd_commands:unregister_commands(commands());
        true ->
            ok
    end,
    case whereis(?PROCNAME) of
	undefined -> ok;
	_ -> ?PROCNAME ! {stop, Host}
    end.

pre_uninstall() ->
    [{code:purge(M), code:delete(M)}
     || M <- [mod_stats2file]].

depends(_Host, _Opts) ->
    [].

mod_opt_type(hooks) ->
    econf:enum([false, true, traffic]);
mod_opt_type(sessionlog) ->
    econf:string().

mod_options(_Host) ->
    [{hooks, false},
     {sessionlog, "/tmp/ejabberd_logsession_@HOST@.log"}].

mod_doc() -> #{}.

mod_status() ->
    "Pages 'Statistics Dx' available in WebAdmin, your Virtual Hosts and your Nodes".

%%%==================================
%%%% Stats Server

%%% +++ TODO: why server and "server"
table_name(server) -> gen_mod:get_module_proc(<<"server">>, mod_statsdx);
table_name("server") -> gen_mod:get_module_proc(<<"server">>, mod_statsdx);
table_name(Host) -> gen_mod:get_module_proc(tob(Host), mod_statsdx).

tob(A) when is_atom(A) -> A;
tob(B) when is_binary(B) -> B;
tob(L) when is_list(L) -> list_to_binary(L).

initialize_stats_server() ->
    register(?PROCNAME, spawn(?MODULE, loop, [[]])).

loop(Hosts) ->
    receive
	{initialize_stats, Host, Hooks, CD} ->
	    case Hosts of
		[] -> prepare_stats_server(CD);
		_ -> ok
	    end,
	    prepare_stats_host(Host, Hooks, CD),
	    loop([Host | Hosts]);
	{stop, Host} ->
	    case Hosts -- [Host] of
		[] ->
                    finish_stats();
		RemainingHosts ->
		    loop(RemainingHosts)
	    end
    end.

%% Si no existe una tabla de stats del server, crearla.
%% Deberia ser creada por un proceso que solo muera cuando se detenga el ultimo mod_statsdx del servidor
prepare_stats_server(CD) ->
    Table = table_name(server),
    ets:new(Table, [named_table, public]),
    ets:insert(Table, {{user_login, server}, CD}),
    ets:insert(Table, {{user_logout, server}, CD}),
    ets:insert(Table, {{register_user, server}, CD}),
    ets:insert(Table, {{remove_user, server}, CD}),
    lists:foreach(
      fun(E) -> ets:insert(Table, {{client, server, E}, CD}) end,
      list_elem(clients, id)
     ),
    lists:foreach(
      fun(E) -> ets:insert(Table, {{conntype, server, E}, CD}) end,
      list_elem(conntypes, id)
     ),
    lists:foreach(
      fun(E) -> ets:insert(Table, {{os, server, E}, CD}) end,
      list_elem(oss, id)
     ),
    ejabberd_hooks:add(webadmin_menu_main, ?MODULE, web_menu_main, 50),
    ejabberd_hooks:add(webadmin_menu_node, ?MODULE, web_menu_node, 50),
    ejabberd_hooks:add(webadmin_page_main, ?MODULE, web_page_main, 50),
    ejabberd_hooks:add(webadmin_page_node, ?MODULE, web_page_node, 50).

prepare_stats_host(Host, Hooks, CD) ->
    Table = table_name(Host),
    ets:new(Table, [named_table, public]),
    ets:insert(Table, {{user_login, Host}, CD}),
    ets:insert(Table, {{user_logout, Host}, CD}),
    ets:insert(Table, {{register_user, Host}, CD}),
    ets:insert(Table, {{remove_user, Host}, CD}),
    ets:insert(Table, {{send, Host, iq, in}, CD}),
    ets:insert(Table, {{send, Host, iq, out}, CD}),
    ets:insert(Table, {{send, Host, message, in}, CD}),
    ets:insert(Table, {{send, Host, message, out}, CD}),
    ets:insert(Table, {{send, Host, presence, in}, CD}),
    ets:insert(Table, {{send, Host, presence, out}, CD}),
    ets:insert(Table, {{recv, Host, iq, in}, CD}),
    ets:insert(Table, {{recv, Host, iq, out}, CD}),
    ets:insert(Table, {{recv, Host, message, in}, CD}),
    ets:insert(Table, {{recv, Host, message, out}, CD}),
    ets:insert(Table, {{recv, Host, presence, in}, CD}),
    ets:insert(Table, {{recv, Host, presence, out}, CD}),
    lists:foreach(
      fun(E) -> ets:insert(Table, {{client, Host, E}, CD}) end,
      list_elem(clients, id)
     ),
    lists:foreach(
      fun(E) -> ets:insert(Table, {{conntype, Host, E}, CD}) end,
      list_elem(conntypes, id)
     ),
    lists:foreach(
      fun(E) -> ets:insert(Table, {{os, Host, E}, CD}) end,
      list_elem(oss, id)
     ),
    case Hooks of
	true ->
	    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 90),
	    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 90),
	    ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, user_login, 90),
	    ejabberd_hooks:add(c2s_closed, Host, ?MODULE, user_logout, 40);
	    %%ejabberd_hooks:add(sm_remove_connection_hook, Host, ?MODULE, user_logout_sm, 90),
	    %ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 90);
	traffic ->
	    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet_traffic, 92),
	    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet_traffic, 92),
	    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 90),
	    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 90),
	    ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, user_login, 90),
	    ejabberd_hooks:add(c2s_closed, Host, ?MODULE, user_logout, 40);
	    %%ejabberd_hooks:add(sm_remove_connection_hook, Host, ?MODULE, user_logout_sm, 90),
	    %ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 90);
	false ->
	    ok
    end,
    ejabberd_hooks:add(webadmin_user, Host, ?MODULE, web_user, 50),
    ejabberd_hooks:add(webadmin_menu_host, Host, ?MODULE, web_menu_host, 50),
    ejabberd_hooks:add(webadmin_page_host, Host, ?MODULE, web_page_host, 50).

finish_stats() ->
    ejabberd_hooks:delete(webadmin_menu_main, ?MODULE, web_menu_main, 50),
    ejabberd_hooks:delete(webadmin_menu_node, ?MODULE, web_menu_node, 50),
    ejabberd_hooks:delete(webadmin_page_main, ?MODULE, web_page_main, 50),
    ejabberd_hooks:delete(webadmin_page_node, ?MODULE, web_page_node, 50),
    Table = table_name(server),
    catch ets:delete(Table).

finish_stats(Host) ->
    ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, user_login, 90),
    ejabberd_hooks:delete(c2s_closed, Host, ?MODULE, user_logout, 40),
    %%ejabberd_hooks:delete(sm_remove_connection_hook, Host, ?MODULE, user_logout_sm, 90),
    %ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 90),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet_traffic, 92),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet_traffic, 92),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 90),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 90),
    ejabberd_hooks:delete(webadmin_user, Host, ?MODULE, web_user, 50),
    ejabberd_hooks:delete(webadmin_menu_host, Host, ?MODULE, web_menu_host, 50),
    ejabberd_hooks:delete(webadmin_page_host, Host, ?MODULE, web_page_host, 50),
    Table = table_name(Host),
    catch ets:delete(Table).


%%%==================================
%%%% Hooks Handlers

register_user(_User, Host) ->
    TableHost = table_name(Host),
    TableServer = table_name(server),
    ets:update_counter(TableHost, {register_user, Host}, 1),
    ets:update_counter(TableServer, {register_user, server}, 1).

remove_user(_User, Host) ->
    TableHost = table_name(Host),
    TableServer = table_name(server),
    ets:update_counter(TableHost, {remove_user, Host}, 1),
    ets:update_counter(TableServer, {remove_user, server}, 1).

%%user_send_packet({NewEl, C2SState}) ->
%%    FromJID = xmpp:get_from(NewEl),
%%    ToJID = xmpp:get_from(NewEl),
%%    %% Registrarse para tramitar Host/mod_stats2file
%%    case catch binary_to_existing_atom(ToJID#jid.lresource, utf8) of
%%	?MODULE ->
%%            ok; %received_response(FromJID, ToJID, NewEl);
%%	_ ->
%%            ok
%%    end,
%%    {NewEl, C2SState}.

%% Only required for traffic stats
user_send_packet_traffic({NewEl, _C2SState} = Acc) ->
    From = xmpp:get_from(NewEl),
    To = xmpp:get_to(NewEl),
    Host = From#jid.lserver,
    HostTo = To#jid.lserver,
    Type2 = case NewEl of
		#iq{} -> iq;
		#message{} -> message;
		#presence{} -> presence
	    end,
    Dest = case is_host(HostTo, Host) of
    	       true -> in;
    	       false -> out
    	   end,
    Table = table_name(Host),
    ets:update_counter(Table, {send, tob(Host), Type2, Dest}, 1),
    Acc.

%% Only required for traffic stats
user_receive_packet_traffic({NewEl, _C2SState} = Acc) ->
    From = xmpp:get_from(NewEl),
    To = xmpp:get_to(NewEl),
    HostFrom = From#jid.lserver,
    Host = To#jid.lserver,
    Type2 = case NewEl of
		#iq{} -> iq;
		#message{} -> message;
		#presence{} -> presence
	    end,
    Dest = case is_host(HostFrom, Host) of
	       true -> in;
	       false -> out
	   end,
    Table = table_name(Host),
    ets:update_counter(Table, {recv, tob(Host), Type2, Dest}, 1),
    Acc.


%%%==================================
%%%% get(*

%%gett(Arg) -> get(node(), [Arg, title]).
getl(Args) -> get(node(), [Args]).
getl(Args, Host) -> get(node(), [Args, Host]).

%%get(_Node, ["", title]) -> "";

get_statistic(N, A) ->
    case catch get(N, A) of
	{'EXIT', R} ->
	    ?ERROR_MSG("get_statistic error for N: ~p, A: ~p~n~p", [N, A, R]),
	    unknown;
	Res -> Res
    end.

get(global, A) -> get(node(), A);

get(_, [{"reductions", _}, title]) -> "Reductions (per minute)";
get(_, [{"reductions", I}]) -> calc_avg(element(2, statistics(reductions)), I); %+++

get(_, ["cpu_avg1", title]) -> "Average system load (1 min)";
get(N, ["cpu_avg1"]) -> rpc:call(N, cpu_sup, avg1, [])/256;
get(_, ["cpu_avg5", title]) -> "Average system load (5 min)";
get(N, ["cpu_avg5"]) -> rpc:call(N, cpu_sup, avg1, [])/256;
get(_, ["cpu_avg15", title]) -> "Average system load (15 min)";
get(N, ["cpu_avg15"]) -> rpc:call(N, cpu_sup, avg15, [])/256;
get(_, ["cpu_nprocs", title]) -> "Number of UNIX processes running on this machine";
get(N, ["cpu_nprocs"]) -> rpc:call(N, cpu_sup, nprocs, []);
get(_, ["cpu_util", title]) -> "CPU utilization";
get(N, ["cpu_util"]) -> rpc:call(N, cpu_sup, util, []);

get(_, [{"cpu_util_user", _}, title]) -> "CPU utilization - user";
get(_, [{"cpu_util_nice_user", _}, title]) -> "CPU utilization - nice_user";
get(_, [{"cpu_util_kernel", _}, title]) -> "CPU utilization - kernel";
get(_, [{"cpu_util_wait", _}, title]) -> "CPU utilization - wait";
get(_, [{"cpu_util_idle", _}, title]) -> "CPU utilization - idle";
get(_, [{"cpu_util_user", U}]) -> U;
get(_, [{"cpu_util_nice_user", U}]) -> U;
get(_, [{"cpu_util_kernel", U}]) -> U;
get(_, [{"cpu_util_wait", U}]) -> U;
get(_, [{"cpu_util_idle", U}]) -> U;

get(_, [{"client", Id}, title]) -> atom_to_list(Id);
get(_, [{"client", Id}, Host]) ->
    Table = table_name(Host),
    case ets:lookup(Table, {client, tob(Host), Id}) of
	[{_, C}] -> C;
	[] -> 0
    end;
get(_, ["client", title]) -> "Client";
get(N, ["client", Host]) ->
    lists:map(
      fun(Id) ->
	      [Id_string] = io_lib:format("~p", [Id]),
	      {Id_string, get(N, [{"client", Id}, Host])}
      end,
      lists:usort(list_elem(clients, id))
     );

get(_, [{"os", Id}, title]) -> atom_to_list(Id);
get(_, [{"os", _Id}, list]) -> lists:usort(list_elem(oss, id));
get(_, [{"os", Id}, Host]) -> [{_, C}] = ets:lookup(table_name(Host), {os, tob(Host), Id}), C;
get(_, ["os", title]) -> "Operating System";
get(N, ["os", Host]) ->
    lists:map(
      fun(Id) ->
	      [Id_string] = io_lib:format("~p", [Id]),
	      {Id_string, get(N, [{"os", Id}, Host])}
      end,
      lists:usort(list_elem(oss, id))
     );

get(_, [{"conntype", Id}, title]) -> atom_to_list(Id);
get(_, [{"conntype", _Id}, list]) -> lists:usort(list_elem(conntypes, id));
get(_, [{"conntype", Id}, Host]) -> [{_, C}] = ets:lookup(table_name(Host), {conntype, Host, Id}), C;
get(_, ["conntype", title]) -> "Connection Type";
get(N, ["conntype", Host]) ->
    lists:map(
      fun(Id) ->
	      [Id_string] = io_lib:format("~p", [Id]),
	      {Id_string, get(N, [{"conntype", Id}, Host])}
      end,
      lists:usort(list_elem(conntypes, id))
     );

get(_, [{"memsup_system", _}, title]) -> "Memory physical (bytes)";
get(_, [{"memsup_system", M}]) -> proplists:get_value(system_total_memory, M, -1);
get(_, [{"memsup_free", _}, title]) -> "Memory free (bytes)";
get(_, [{"memsup_free", M}]) -> proplists:get_value(free_memory, M, -1);

get(_, [{"user_login", _}, title]) -> "Logins (per minute)";
get(_, [{"user_login", I}, Host]) -> get_stat({user_login, tob(Host)}, I);
get(_, [{"user_logout", _}, title]) -> "Logouts (per minute)";
get(_, [{"user_logout", I}, Host]) -> get_stat({user_logout, tob(Host)}, I);
get(_, [{"register_user", _}, title]) -> "Accounts registered (per minute)";
get(_, [{"register_user", I}, Host]) -> get_stat({register_user, tob(Host)}, I);
get(_, [{"remove_user", _}, title]) -> "Accounts deleted (per minute)";
get(_, [{"remove_user", I}, Host]) -> get_stat({remove_user, tob(Host)}, I);
get(_, [{Table, Type, Dest, _}, title]) -> filename:flatten([Table, Type, Dest]);
get(_, [{Table, Type, Dest, I}, Host]) -> get_stat({Table, tob(Host), Type, Dest}, I);

get(_, ["user_login", title]) -> "Logins";
get(_, ["user_login", Host]) -> get_stat({user_login, Host});
get(_, ["user_logout", title]) -> "Logouts";
get(_, ["user_logout", Host]) -> get_stat({user_logout, Host});
get(_, ["register_user", title]) -> "Accounts registered";
get(_, ["register_user", Host]) -> get_stat({register_user, Host});
get(_, ["remove_user", title]) -> "Accounts deleted";
get(_, ["remove_user", Host]) -> get_stat({remove_user, Host});
get(_, [{Table, Type, Dest}, title]) -> filename:flatten([Table, Type, Dest]);
get(_, [{Table, Type, Dest}, Host]) -> get_stat({Table, tob(Host), Type, Dest});

get(_, ["localtime", title]) -> "Local time";
get(N, ["localtime"]) ->
    localtime_to_string(rpc:call(N, erlang, localtime, []));

get(_, ["memory_total", title]) -> "Memory total allocated: processes and system";
get(N, ["memory_total"]) -> rpc:call(N, erlang, memory, [total]);
get(_, ["memory_processes", title]) -> "Memory allocated by Erlang processes";
get(N, ["memory_processes"]) -> rpc:call(N, erlang, memory, [processes]);
get(_, ["memory_processes_used", title]) -> "Memory used by Erlang processes";
get(N, ["memory_processes_used"]) -> rpc:call(N, erlang, memory, [processes_used]);
get(_, ["memory_system", title]) -> "Memory allocated by Erlang emulator but not associated to processes";
get(N, ["memory_system"]) -> rpc:call(N, erlang, memory, [system]);
get(_, ["memory_atom", title]) -> "Memory allocated for atoms";
get(N, ["memory_atom"]) -> rpc:call(N, erlang, memory, [atom]);
get(_, ["memory_atom_used", title]) -> "Memory used for atoms";
get(N, ["memory_atom_used"]) -> rpc:call(N, erlang, memory, [atom_used]);
get(_, ["memory_binary", title]) -> "Memory allocated for binaries";
get(N, ["memory_binary"]) -> rpc:call(N, erlang, memory, [binary]);
get(_, ["memory_code", title]) -> "Memory allocated for Erlang code";
get(N, ["memory_code"]) -> rpc:call(N, erlang, memory, [code]);
get(_, ["memory_ets", title]) -> "Memory allocated for ETS tables";
get(N, ["memory_ets"]) -> rpc:call(N, erlang, memory, [ets]);

get(_, ["vhost", title]) -> "Virtual host";
get(_, ["vhost", Host]) -> Host;

get(_, ["ejabberdversion", title]) -> "ejabberd version";
get(N, ["ejabberdversion"]) -> element(2, rpc:call(N, application, get_key, [ejabberd, vsn]));

get(_, ["totalerlproc", title]) -> "Total Erlang processes running";
get(N, ["totalerlproc"]) -> rpc:call(N, erlang, system_info, [process_count]);
get(_, ["operatingsystem", title]) -> "Operating System";
get(N, ["operatingsystem"]) -> {rpc:call(N, os, type, []), rpc:call(N, os, version, [])};
get(_, ["erlangmachine", title]) -> "Erlang machine";
get(N, ["erlangmachine"]) -> rpc:call(N, erlang, system_info, [system_version]);
get(_, ["erlangmachinetarget", title]) -> "Erlang machine target";
get(N, ["erlangmachinetarget"]) -> rpc:call(N, erlang, system_info, [system_architecture]);
get(_, ["maxprocallowed", title]) -> "Maximum processes allowed";
get(N, ["maxprocallowed"]) -> rpc:call(N, erlang, system_info, [process_limit]);
get(_, ["procqueue", title]) -> "Number of processes on the running queue";
get(N, ["procqueue"]) -> rpc:call(N, erlang, statistics, [run_queue]);
get(_, ["uptimehuman", title]) -> "Uptime";
get(N, ["uptimehuman"]) ->
    io_lib:format("~w days ~w hours ~w minutes ~p seconds", ms_to_time(get(N, ["uptime"])));
get(_, ["lastrestart", title]) -> "Last restart";
get(N, ["lastrestart"]) ->
    Now = calendar:datetime_to_gregorian_seconds(rpc:call(N, erlang, localtime, [])),
    UptimeMS = get(N, ["uptime"]),
    Last_restartS = trunc(Now - (UptimeMS/1000)),
    Last_restart = calendar:gregorian_seconds_to_datetime(Last_restartS),
    localtime_to_string(Last_restart);

get(_, ["plainusers", title]) -> "Plain users";
get(_, ["plainusers"]) -> {R, _, _} = get_connectiontype(), R;
get(_, ["tlsusers", title]) -> "TLS users";
get(_, ["tlsusers"]) -> {_, R, _} = get_connectiontype(), R;
get(_, ["sslusers", title]) -> "SSL users";
get(_, ["sslusers"]) -> {_, _, R} = get_connectiontype(), R;
get(_, ["registeredusers", title]) -> "Registered users";
get(N, ["registeredusers"]) -> rpc:call(N, mnesia, table_info, [passwd, size]);
get(_, ["registeredusers", Host]) -> ejabberd_auth:count_users(Host);
get(_, ["onlineusers", title]) -> "Online users";
get(N, ["onlineusers"]) -> rpc:call(N, mnesia, table_info, [session, size]);
get(_, ["onlineusers", Host]) -> length(ejabberd_sm:get_vh_session_list(Host));
get(_, ["httpbindusers", title]) -> "HTTP-Bind users (aprox)";
get(N, ["httpbindusers"]) -> rpc:call(N, mnesia, table_info, [http_bind, size]);

get(_, ["s2sconnectionsoutgoing", title]) -> "Outgoing S2S connections";
get(_, ["s2sconnectionsoutgoing"]) -> ejabberd_s2s:outgoing_s2s_number();
get(_, ["s2sconnectionsincoming", title]) -> "Incoming S2S connections";
get(_, ["s2sconnectionsincoming"]) -> ejabberd_s2s:incoming_s2s_number();
get(_, ["s2sconnections", title]) -> "S2S connections";
get(_, ["s2sconnections"]) -> length(get_S2SConns());
get(_, ["s2sconnections", Host]) -> get_s2sconnections(Host);
get(_, ["s2sservers", title]) -> "S2S servers";
get(_, ["s2sservers"]) -> length(lists:usort([element(2, C) || C <- get_S2SConns()]));

get(_, ["offlinemsg", title]) -> "Offline messages";
get(N, ["offlinemsg"]) -> rpc:call(N, mnesia, table_info, [offline_msg, size]);
get(_, ["offlinemsg", Host]) -> get_offlinemsg(Host);
get(_, ["totalrosteritems", title]) -> "Total roster items";
get(N, ["totalrosteritems"]) -> rpc:call(N, mnesia, table_info, [roster, size]);
get(_, ["totalrosteritems", Host]) -> get_totalrosteritems(Host);

get(_, ["meanitemsinroster", title]) -> "Mean items in roster";
get(_, ["meanitemsinroster"]) -> get_meanitemsinroster();
get(_, ["meanitemsinroster", Host]) -> get_meanitemsinroster(Host);

get(_, ["totalmucrooms", title]) -> "Total MUC rooms";
get(_, ["totalmucrooms"]) -> ets:info(muc_online_room, size);
get(_, ["totalmucrooms", Host]) -> get_totalmucrooms(Host);
get(_, ["permmucrooms", title]) -> "Permanent MUC rooms";
get(N, ["permmucrooms"]) -> rpc:call(N, mnesia, table_info, [muc_room, size]);
get(_, ["permmucrooms", Host]) -> get_permmucrooms(Host);
get(_, ["regmucrooms", title]) -> "Users registered at MUC service";
get(N, ["regmucrooms"]) -> rpc:call(N, mnesia, table_info, [muc_registered, size]);
get(_, ["regmucrooms", Host]) -> get_regmucrooms(Host);
get(_, ["regpubsubnodes", title]) -> "Registered nodes at Pub/Sub";
get(N, ["regpubsubnodes"]) -> rpc:call(N, mnesia, table_info, [pubsub_node, size]);
get(_, ["vcards", title]) -> "Total vCards published";
get(N, ["vcards"]) -> rpc:call(N, mnesia, table_info, [vcard, size]);
get(_, ["vcards", Host]) -> get_vcards(Host);

%%get(_, ["ircconns", title]) -> "IRC connections";
%%get(_, ["ircconns"]) -> ets:info(irc_connection, size);
%%get(_, ["ircconns", Host]) -> get_irccons(Host); % This seems to crash for some people
get(_, ["uptime", title]) -> "Uptime";
get(N, ["uptime"]) -> element(1, rpc:call(N, erlang, statistics, [wall_clock]));
get(_, ["cputime", title]) -> "CPU Time";
get(N, ["cputime"]) -> element(1, rpc:call(N, erlang, statistics, [runtime]));

get(_, ["languages", title]) -> "Languages";
get(_, ["languages", Server]) -> get_languages(Server);

get(_, ["client_os", title]) -> "Client/OS";
get(_, ["client_os", Server]) -> get_client_os(Server);

get(_, ["client_conntype", title]) -> "Client/Connection Type";
get(_, ["client_conntype", Server]) -> get_client_conntype(Server);

get(N, A) ->
    io:format(" ----- node: '~p', A: '~p'~n", [N, A]),
    "666".

%%%==================================
%%%% get_*

get_S2SConns() -> ejabberd_s2s:dirty_get_connections().

get_tls_drv() ->
    R = lists:filter(
	  fun(P) ->
		  case erlang:port_info(P, name) of
		      {name, "tls_drv"} -> true;
		      _ -> false
		  end
	  end, erlang:ports()),
    length(R).

get_connections(Port) ->
    R = lists:filter(
	  fun(P) ->
		  case inet:port(P) of
		      {ok, Port} -> true;
		      _ -> false
		  end
	  end, erlang:ports()),
    length(R).

get_totalrosteritems(Host) ->
    F = fun() ->
		F2 = fun(R, {H, A}) ->
			     {_LUser, LServer, _LJID} = R#roster.usj,
			     A2 = case LServer of
				      H -> A+1;
				      _ -> A
				  end,
			     {H, A2}
		     end,
		mnesia:foldl(F2, {Host, 0}, roster)
	end,
    {atomic, {Host, Res}} = mnesia:transaction(F),
    Res.

%% Copied from ejabberd_sm.erl
%%-record(session, {sid, usr, us, priority}).

%%get_authusers(Host) ->
%%    F = fun() ->
%%		F2 = fun(R, {H, A}) ->
%%			{_LUser, LServer, _LResource} = R#session.usr,
%%			A2 = case LServer of
%%				H -> A+1;
%%				_ -> A
%%			end,
%%			{H, A2}
%%		end,
%%		mnesia:foldl(F2, {Host, 0}, session)
%%	end,
%%    {atomic, {Host, Res}} = mnesia:transaction(F),
%%	Res.

-record(offline_msg, {us, timestamp, expire, from, to, packet}).

get_offlinemsg(Host) ->
    F = fun() ->
		F2 = fun(R, {H, A}) ->
			     {_LUser, LServer} = R#offline_msg.us,
			     A2 = case LServer of
				      H -> A+1;
				      _ -> A
				  end,
			     {H, A2}
		     end,
		mnesia:foldl(F2, {Host, 0}, offline_msg)
	end,
    {atomic, {Host, Res}} = mnesia:transaction(F),
    Res.

-record(vcard, {us, vcard}).

get_vcards(Host) ->
    F = fun() ->
		F2 = fun(R, {H, A}) ->
			     {_LUser, LServer} = R#vcard.us,
			     A2 = case LServer of
				      H -> A+1;
				      _ -> A
				  end,
			     {H, A2}
		     end,
		mnesia:foldl(F2, {Host, 0}, vcard)
	end,
    {atomic, {Host, Res}} = mnesia:transaction(F),
    Res.

get_s2sconnections(Host) ->
    F = fun() ->
		F2 = fun(R, {H, A}) ->
			     {MyServer, _Server} = R#s2s.fromto,
			     A2 = case MyServer of
				      H -> A+1;
				      _ -> A
				  end,
			     {H, A2}
		     end,
		mnesia:foldl(F2, {Host, 0}, s2s)
	end,
    {atomic, {Host, Res}} = mnesia:transaction(F),
    Res.

%%-record(irc_connection, {jid_server_host, pid}).

%%get_irccons(Host) ->
%%	F2 = fun(R, {H, A}) ->
%%		{From, _Server, _Host} = R#irc_connection.jid_server_host,
%%		A2 = case From#jid.lserver of
%%			H -> A+1;
%%			_ -> A
%%		end,
%%		{H, A2}
%%	end,
%%    {Host, Res} = ets:foldl(F2, {Host, 0}, irc_connection),
%%	Res.

is_host(HostBin, SubhostBin) ->
    case catch binary:split(HostBin, SubhostBin) of
	[_Sub, <<"">>] -> true;
	_ -> false
    end.

-record(muc_online_room, {name_host, pid}).

get_totalmucrooms(Host) ->
    F2 = fun(R, {H, A}) ->
		 {_Name, MUCHost} = R#muc_online_room.name_host,
		 A2 = case is_host(MUCHost, H) of
			  true -> A+1;
			  false -> A
		      end,
		 {H, A2}
	 end,
    {Host, Res} = ets:foldl(F2, {Host, 0}, muc_online_room),
    Res.

-record(muc_room, {name_host, opts}).

get_permmucrooms(Host) ->
    F = fun() ->
		F2 = fun(R, {H, A}) ->
			     {_Name, MUCHost} = R#muc_room.name_host,
			     A2 = case is_host(MUCHost, H) of
				      true -> A+1;
				      false -> A
				  end,
			     {H, A2}
		     end,
		mnesia:foldl(F2, {Host, 0}, muc_room)
	end,
    {atomic, {Host, Res}} = mnesia:transaction(F),
    Res.

-record(muc_registered, {us_host, nick}).

get_regmucrooms(Host) ->
    F = fun() ->
		F2 = fun(R, {H, A}) ->
			     {_User, MUCHost} = R#muc_registered.us_host,
			     A2 = case is_host(MUCHost, H) of
				      true -> A+1;
				      false -> A
				  end,
			     {H, A2}
		     end,
		mnesia:foldl(F2, {Host, 0}, muc_registered)
	end,
    {atomic, {Host, Res}} = mnesia:transaction(F),
    Res.

get_stat(Stat) ->
    Host = case Stat of
	       {_, H} -> H;
	       {_, H, _, _} -> H
	   end,
    Table = table_name(Host),
    Res = ets:lookup(Table, Stat),
    [{_, C}] = Res,
    C.

get_stat(Stat, Ims) ->
    Host = case Stat of
	       {_, H} -> H;
	       {_, H, _, _} -> H
	   end,
    Table = table_name(Host),
    Res = ets:lookup(Table, Stat),
    ets:update_counter(Table, Stat, {2,1,0,0}),
    [{_, C}] = Res,
    calc_avg(C, Ims).
%%C.

calc_avg(Count, TimeMS) ->
    TimeMIN = TimeMS/(1000*60),
    Count/TimeMIN.

%%%==================================
%%%% utilities

get_connectiontype() ->
    C2 = get_connections(5222) -1,
    C3 = get_connections(5223) -1,
    NUplain = C2 + C3 - get_tls_drv(),
    NUtls = C2 - NUplain,
    NUssl = C3,
    {NUplain, NUtls, NUssl}.

ms_to_time(T) ->
    DMS = 24*60*60*1000,
    HMS = 60*60*1000,
    MMS = 60*1000,
    SMS = 1000,
    D = trunc(T/DMS),
    H = trunc((T - (D*DMS)) / HMS),
    M = trunc((T - (D*DMS) - (H*HMS)) / MMS),
    S = trunc((T - (D*DMS) - (H*HMS) - (M*MMS)) / SMS),
    [D, H, M, S].


%% Cuando un usuario conecta, pedirle iq:version a nombre de Host/mod_stats2file
user_login(#{user := User, lserver := Host, resource := Resource, ip := IpPort} = State) ->
    ets:update_counter(table_name(server), {user_login, server}, 1),
    ets:update_counter(table_name(Host), {user_login, Host}, 1),
    timer:apply_after(timer:seconds(5), ?MODULE,
                      request_iqversion, [User, Host, Resource, IpPort]),
    State.


%%user_logout_sm(_, JID, _Data) ->
%%    user_logout(JID#jid.luser, JID#jid.lserver, JID#jid.lresource, no_status).

%% cuando un usuario desconecta, buscar en la tabla su JID/USR y quitarlo
user_logout(#{user := User, lserver := Host, resource := Resource} = State, _Reason) ->
    TableHost = table_name(Host),
    TableServer = table_name(server),
    ets:update_counter(TableServer, {user_logout, server}, 1),
    ets:update_counter(TableHost, {user_logout, Host}, 1),

    JID = jid:make(User, Host, Resource),
    case ets:lookup(TableHost, {session, JID}) of
	[{_, Client_id, OS_id, Lang, ConnType, _Client, _Version, _OS}] ->
	    ets:delete(TableHost, {session, JID}),
	    ets:update_counter(TableHost, {client, Host, Client_id}, -1),
	    ets:update_counter(TableServer, {client, server, Client_id}, -1),
	    ets:update_counter(TableHost, {os, Host, OS_id}, -1),
	    ets:update_counter(TableServer, {os, server, OS_id}, -1),
	    ets:update_counter(TableHost, {conntype, Host, ConnType}, -1),
	    ets:update_counter(TableServer, {conntype, server, ConnType}, -1),
	    update_counter_create(TableHost, {client_os, Host, Client_id, OS_id}, -1),
	    update_counter_create(TableServer, {client_os, server, Client_id, OS_id}, -1),
	    update_counter_create(TableHost, {client_conntype, Host, Client_id, ConnType}, -1),
	    update_counter_create(TableServer, {client_conntype, server, Client_id, ConnType}, -1),
	    update_counter_create(TableHost, {lang, Host, Lang}, -1),
	    update_counter_create(TableServer, {lang, server, Lang}, -1);
	[] ->
	    ok
    end,
    State.

request_iqversion(User, Host, Resource, IpPort) ->
    case ejabberd_sm:get_user_ip(User, Host, Resource) of
        IpPort -> request_iqversion(User, Host, Resource);
        _ -> ok
    end.
request_iqversion(User, Host, Resource) ->
    From = jid:make(<<"">>, Host, list_to_binary(atom_to_list(?MODULE))),
    To = jid:make(User, Host, Resource),
    Query = #xmlel{name = <<"query">>, attrs = [{<<"xmlns">>, ?NS_VERSION}]},
    IQ = #iq{type = get,
             from = From,
             to = To,
             sub_els = [Query]},
    HandleResponse = fun(#iq{type = Type} = IQr) when (Type == result) or (Type == error) ->
			       spawn(?MODULE, received_response,
				     [To, From, IQr]);
			  (timeout) ->
			       spawn(?MODULE, received_response,
				     [To, unknown, unknown, <<"">>, "unknown", "unknown", "unknown"]);
			  (R) ->
			       ?INFO_MSG("Unexpected response: ~n~p", [{User, Host, Resource, R}]),
			       ok % Hmm.
		       end,
    ejabberd_router:route_iq(IQ, HandleResponse).

%% cuando el virtualJID recibe una respuesta iqversion,
%% almacenar su JID/USR + client + OS en una tabla
received_response(From, _To, El) ->
    try received_response(From, El)
    catch
    	_:_ -> ok
    end.

received_response(From, #iq{type = error, lang = Lang1, sub_els = Elc} = Iq)
  when [{xmlel,<<"error">>,
         [{<<"type">>,<<"modify">>}],
         [{xmlel,<<"not-acceptable">>,
           [{<<"xmlns">>,<<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
           []}]}] == Elc ->
    Resource = From#jid.lresource,
    {Client_id, OS_id} =
        case binary:split(Resource, [<<"-">>, <<"_">>], [global]) of
            [<<"xabber">>, <<"android">>, _] ->
                {xabber, android};
            [<<"Xabber">> | _] ->
                {xabber, unknown};
            _ ->
                ?INFO_MSG("statsdx unknown client: ~n~p", [Iq]),
                {unknown, unknown}
        end,
    received_response(From, Client_id, OS_id, Lang1,
                      "unknown", "unknown", "unknown");

received_response(From, #iq{type = result, lang = Lang1, sub_els = Elc}) ->
    [El] = fxml:remove_cdata(Elc),
    {xmlel, _, Attrs2, _Els2} = El,
    ?NS_VERSION = fxml:get_attr_s(<<"xmlns">>, Attrs2),
    Client = get_tag_cdata_subtag(El, <<"name">>),
    Version = get_tag_cdata_subtag(El, <<"version">>),
    OS = get_tag_cdata_subtag(El, <<"os">>),
    {Client_id, OS_id} = identify(Client, OS),
    received_response(From, Client_id, OS_id, Lang1, Client, Version, OS);

received_response(From, #iq{type = error, lang = Lang1} = Iq) ->
    ?INFO_MSG("statsdx unknown client: ~n~p", [Iq]),
    received_response(From, unknown, unknown, Lang1,
                      "unknown", "unknown", "unknown").

received_response(From, Client_id, OS_id, Lang1, Client, Version, OS) ->
    User = From#jid.luser,
    Host = From#jid.lserver,
    Resource = From#jid.lresource,
    ConnType = get_connection_type(User, Host, Resource),
    Lang = case Lang1 of
	       <<"">> -> "unknown";
	       L -> binary_to_list(L)
	   end,
    TableHost = table_name(Host),
    TableServer = table_name(server),
    ets:update_counter(TableHost, {client, Host, Client_id}, 1),
    ets:update_counter(TableServer, {client, server, Client_id}, 1),
    ets:update_counter(TableHost, {os, Host, OS_id}, 1),
    ets:update_counter(TableServer, {os, server, OS_id}, 1),
    ets:update_counter(TableHost, {conntype, Host, ConnType}, 1),
    ets:update_counter(TableServer, {conntype, server, ConnType}, 1),
    update_counter_create(TableHost, {lang, Host, Lang}, 1),
    update_counter_create(TableServer, {lang, server, Lang}, 1),
    update_counter_create(TableHost, {client_os, Host, Client_id, OS_id}, 1),
    update_counter_create(TableServer, {client_os, server, Client_id, OS_id}, 1),
    update_counter_create(TableHost, {client_conntype, Host, Client_id, ConnType}, 1),
    update_counter_create(TableServer, {client_conntype, server, Client_id, ConnType}, 1),
    ets:insert(TableHost, {{session, From}, Client_id, OS_id, Lang, ConnType, Client, Version, OS}).

get_connection_type(User, Host, Resource) ->
    UserInfo = ejabberd_sm:get_user_info(User, Host, Resource),
    {conn, Conn} = lists:keyfind(conn, 1, UserInfo),
    Conn.

update_counter_create(Table, Element, C) ->
    case ets:lookup(Table, Element) of
	[] -> ets:insert(Table, {Element, 1});
	_ -> ets:update_counter(Table, Element, C)
    end.

get_tag_cdata_subtag(E, T) ->
    E2 = fxml:get_subtag(E, T),
    case E2 of
	false -> "unknown";
	_ -> binary_to_list(fxml:get_tag_cdata(E2))
    end.

list_elem(Type, id) ->
    {_, Ids} = lists:unzip(list_elem(Type, full)),
    Ids;
list_elem(clients, full) ->
    [
     {"adium", adium},
     {"aqq", aqq},
     {"atalk", atalk},
     {"bitlbee", bitlbee},
     {"blabber.im", blabber_im},
     {"bruno", bruno},
     {"centerim", centerim},
     {"coccinella", coccinella},
     {"conversations", conversations},
     {"exodus", exodus},
     {"gabber", gabber},
     {"gaim", gaim},
     {"gajim", gajim},
     {"ichat", ichat},
     {"imagent", messages},
     {"instantbird", instantbird},
     {"irssi-xmpp", irssi_xmpp},
     {"jabber.el", jabber_el},
     {"jajc", jajc},
     {"jbother", jbother},
     {"kopete", kopete},
     {"libgaim", libgaim},
     {"mcabber", mcabber},
     {"miranda", miranda},
     {"monal", monal},
     {"pandion", pandion},
     {"pidgin", pidgin},
     {"poezio", poezio},
     {"profanity", profanity},
     {"psi", psi},
     {"qip infium", qipinfium},
     {"spark", spark},
     {"swift", swift},
     {"telepathy gabble", telepathy_gabble},
     {"thunderbird", thunderbird},
     {"tkabber", tkabber},
     {"trillian", trillian},
     {"vacuum-im", vacuum_im},
     {"wtw", wtw},
     {"xabber", xabber},
     {"xmpp messenger", xmpp_messenger},
     {"xmppjabberclient", xmpp_jabber_client},
     {"yaxim", yaxim},
     {"unknown", unknown}
    ];
list_elem(conntypes, full) ->
    [
     {"c2s", c2s},
     {"c2s_tls", c2s_tls},
     {"c2s_compressed", c2s_compressed},
     {"c2s_compressed_tls", c2s_compressed_tls},
     {"http_bind", http_bind},
     {"websocket", websocket},
     {"unknown", unknown}
    ];
list_elem(oss, full) ->
    [
     {"android", android},
     {"bsd", bsd},
     {"debian", linux},
     {"gentoo", linux},
     {"kde", linux},
     {"linux", linux},
     {"mac", mac},
     {"mageia", linux},
     {"opensuse", linux},
     {"sunos", linux},
     {"ubuntu", linux},
     {"win", windows},
     {"unknown", unknown}
    ].

identify(Client, OS) ->
    Res = {try_match(string:to_lower(Client), list_elem(clients, full)),
           try_match(string:to_lower(OS), list_elem(oss, full))},
    case Res of
	{libgaim, mac} -> {adium, mac};
	{adium, unknown} -> {adium, mac};
	{qipinfium, unknown} -> {qipinfium, windows};
	_ -> Res
    end.

try_match(_E, []) -> unknown;
try_match(E, [{Str, Id} | L]) ->
    case string:str(E, Str) of
	0 -> try_match(E, L);
	_ -> Id
    end.

get_client_os(Server) ->
    CO1 = ets:match(table_name(Server), {{client_os, Server, '$1', '$2'}, '$3'}),
    CO2 = lists:map(
	    fun([Cl, Os, A3]) ->
		    {lists:flatten([atom_to_list(Cl), "/", atom_to_list(Os)]), A3}
	    end,
	    CO1
	   ),
    lists:keysort(1, CO2).

get_client_conntype(Server) ->
    CO1 = ets:match(table_name(Server), {{client_conntype, Server, '$1', '$2'}, '$3'}),
    CO2 = lists:map(
	    fun([Cl, Os, A3]) ->
		    {lists:flatten([atom_to_list(Cl), "/", atom_to_list(Os)]), A3}
	    end,
	    CO1
	   ),
    lists:keysort(1, CO2).

get_languages(Server) ->
    L1 = ets:match(table_name(Server), {{lang, Server, '$1'}, '$2'}),
    L2 = lists:map(
	   fun([La, C]) ->
		   {La, C}
	   end,
	   L1
	  ),
    lists:keysort(1, L2).

get_meanitemsinroster() ->
    get_meanitemsinroster2(getl("totalrosteritems"), getl("registeredusers")).
get_meanitemsinroster(Host) ->
    get_meanitemsinroster2(getl("totalrosteritems", Host), getl("registeredusers", Host)).
get_meanitemsinroster2(Items, Users) ->
    case Users of
	0 -> 0;
	_ -> Items/Users
    end.

localtime_to_string({{Y, Mo, D},{H, Mi, S}}) ->
    lists:concat([H, ":", Mi, ":", S, " ", D, "/", Mo, "/", Y]).

%% cuando toque mostrar estadisticas
%%get_iqversion() ->
%% contar en la tabla cuantos tienen cliente: *psi*
%%buscar en la tabla iqversion
%%ok.


%%%==================================
%%%% Web Admin Menu

web_menu_main(Acc, Lang) ->
    Acc ++ [{<<"statsdx">>, <<(translate:translate(Lang, ?T("Statistics")))/binary, " Dx">>}].

web_menu_node(Acc, _Node, Lang) ->
    Acc ++ [{<<"statsdx">>, <<(translate:translate(Lang, ?T("Statistics")))/binary, " Dx">>}].

web_menu_host(Acc, _Host, Lang) ->
    Acc ++ [{<<"statsdx">>, <<(translate:translate(Lang, ?T("Statistics")))/binary, " Dx">>}].

%% ejabberd 24.02 or older
web_user(Acc, User, Host, Lang) when is_binary(Lang) ->
    EmptyRequest = #request{method = 'GET',
                            raw_path = <<"">>,
                            ip = {{127,0,0,1}, 0},
                            lang = Lang,
                            sockmod = 'gen_tcp',
                            socket = hd(erlang:ports())},
    web_user(Acc, User, Host, EmptyRequest);

web_user(Acc, User, Host, #request{lang = Lang}) ->
    Filter = [<<"username">>, User],
    Sort_query = {normal, 1},
    Acc ++
        [?XCT(<<"h3">>, <<(translate:translate(Lang, ?T("Statistics")))/binary, " Dx">>),
	 ?XE(<<"table">>,
             [?XE(<<"thead">>,
                  [?XE(<<"tr">>, make_sessions_table_tr(Lang, false) )]),
              ?XE(<<"tbody">>,
                  do_sessions_table(global, Lang, Filter, Sort_query, Host))
             ])
        ].

%%%==================================
%%%% Web Admin Page

web_page_main(_, #request{path=[<<"statsdx">>], lang = Lang} = _Request) ->
    Res = [?XC(<<"h1">>, <<(translate:translate(Lang, ?T("Statistics")))/binary, " Dx">>),
	   ?XC(<<"h3">>, <<"Accounts">>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "registeredusers")
			      ])
		]),
	   ?XC(<<"h3">>, <<"Roster">>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "totalrosteritems"),
			       do_stat(global, Lang, "meanitemsinroster"),
			       ?XE(<<"tr">>,
				  [?XE(<<"td">>, [?CT(<<"Top rosters">>)]),
				   ?XE(<<"td">>, [
				    ?ACT(<<"top/roster/30/">>, <<"30">>), ?C(<<", ">>),
				    ?ACT(<<"top/roster/100/">>, <<"100">>), ?C(<<", ">>),
				    ?ACT(<<"top/roster/500/">>, <<"500">>) ])]
				 )
			      ])
		]),
	   ?XC(<<"h3">>, <<"Users">>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "onlineusers"),
			       do_stat(global, Lang, "offlinemsg"),
			       ?XE(<<"tr">>,
				  [?XE(<<"td">>, [?CT(<<"Top offline message queues">>) ]),
				   ?XE(<<"td">>, [
				    ?ACT(<<"top/offlinemsg/30/">>, <<"30">>), ?C(<<", ">>),
				    ?ACT(<<"top/offlinemsg/100/">>, <<"100">>), ?C(<<", ">>),
				    ?ACT(<<"top/offlinemsg/500/">>, <<"500">>) ])]
				 ),
			       do_stat(global, Lang, "vcards"),
			       ?XE(<<"tr">>,
				  [?XE(<<"td">>, [?CT(<<"Top vCard sizes">>) ]),
				   ?XE(<<"td">>, [
				    ?ACT(<<"top/vcard/5/">>, <<"5">>), ?C(<<", ">>),
				    ?ACT(<<"top/vcard/30/">>, <<"30">>), ?C(<<", ">>),
				    ?ACT(<<"top/vcard/100/">>, <<"100">>), ?C(<<", ">>),
				    ?ACT(<<"top/vcard/500/">>, <<"500">>) ])]
				 )
			      ])
		]),
	   ?XC(<<"h3">>, <<"MUC">>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "totalmucrooms"),
			       do_stat(global, Lang, "permmucrooms"),
			       do_stat(global, Lang, "regmucrooms")
			      ])
		]),
	   ?XC(<<"h3">>, <<"Pub/Sub">>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "regpubsubnodes")
			      ])
		]),
	   %%?XC("h3", "IRC"),
	   %%?XAE("table", [],
	   %% [?XE("tbody", [
	   %%  do_stat(global, Lang, "ircconns")
	   %% ])
	   %%]),
	   %%?XC("h3", "Ratios"),
	   %%?XAE("table", [],
	   %%	[?XE("tbody", [
	   %%		      ])
	   %%	]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("client"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "client", server)
		    )
		]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("os"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "os", server)
		    )
		]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("client"))/binary, "/", (get_stat_n("os"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "client_os", server)
		    )
		]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("conntype"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "conntype", server)
		    )
		]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("client"))/binary, "/", (get_stat_n("conntype"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "client_conntype", server)
		    )
		]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("languages"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "languages", server)
		    )
		])
	  ],
    {stop, Res};
web_page_main(_, #request{path=[<<"statsdx">>, <<"top">>, Topic, Topnumber], q = _Q, lang = Lang} = _Request) ->
    Res = [?XC(<<"h1">>, <<(translate:translate(Lang, ?T("Statistics")))/binary, " Dx">>),
	   case Topic of
		<<"offlinemsg">> -> ?XCT(<<"h2">>, <<"Top offline message queues">>);
		<<"vcard">> -> ?XCT(<<"h2">>, <<"Top vCard sizes">>);
		<<"roster">> -> ?XCT(<<"h2">>, <<"Top rosters">>)
	   end,
	   ?XE(<<"table">>,
	       [?XE(<<"thead">>, [?XE(<<"tr">>,
				  [?XE(<<"td">>, [?CT(<<"#">>)]),
				   ?XE(<<"td">>, [?CT(<<"Jabber ID">>)]),
				   ?XE(<<"td">>, [?CT(<<"Value">>)])]
				 )]),
		?XE(<<"tbody">>, do_top_table(global, Lang, Topic, Topnumber, server))
	       ])
	  ],
    {stop, Res};
web_page_main(_, #request{path=[<<"statsdx">> | Filter], q = Q, lang = Lang} = _Request) ->
    Sort_query = get_sort_query(Q),
    FilterS = io_lib:format("~p", [Filter]),
    Res = [?XC(<<"h1">>, <<(translate:translate(Lang, ?T("Statistics")))/binary, " Dx">>),
	   ?XC(<<"h2">>, list_to_binary("Sessions with: " ++ FilterS)),
	   ?XE(<<"table">>,
	       [
		?XE(<<"thead">>, [?XE(<<"tr">>, make_sessions_table_tr(Lang) )]),
		?XE(<<"tbody">>, do_sessions_table(global, Lang, Filter, Sort_query, server))
	       ])
	  ],
    {stop, Res};
web_page_main(Acc, _) -> Acc.

do_top_table(_Node, Lang, Topic, TopnumberBin, Host) ->
    List = get_top_users(Host, binary_to_integer(TopnumberBin), Topic),
    %% get_top_users(Topnumber, "roster")
    {List2, _} = lists:mapfoldl(
      fun({Value, UserB, ServerB}, Counter) ->
	    User = binary_to_list(UserB),
	    Server = binary_to_list(ServerB),
	    UserJID = User++"@"++Server,
	    Level = case Host of
		server -> 4;
		_ -> 6
	    end,
	    UserJIDUrl = lists:duplicate(Level, "../") ++ "server/" ++ Server ++ "/user/" ++ User ++ "/",
			ValueString = integer_to_list(Value),
	    ValueEl = case Topic of
		<<"offlinemsg">> -> {url, UserJIDUrl++"queue/", ValueString};
		<<"vcard">> -> {url, UserJIDUrl++"vcard/", ValueString};
		<<"roster">> -> {url, UserJIDUrl++"roster/", ValueString};
		_ -> ValueString
	    end,
	    {do_table_element(Counter, Lang, UserJID, {fixed_url, UserJIDUrl}, ValueEl),
		Counter+1}
      end,
    1,
      List
     ),
     List2.

%% Code copied from mod_muc_admin.erl
%% Returns: {normal | reverse, Integer}
get_sort_query(Q) ->
    case catch get_sort_query2(Q) of
	{ok, Res} -> Res;
	_ -> {normal, 1}
    end.
get_sort_query2(Q) ->
    {value, {_, Binary}} = lists:keysearch(<<"sort">>, 1, Q),
    Integer = binary_to_integer(lists:nth(1, binary:split(Binary, <<"/">>))),
    case Integer >= 0 of
	true -> {ok, {normal, Integer}};
	false -> {ok, {reverse, abs(Integer)}}
    end.
make_sessions_table_tr(Lang) ->
    make_sessions_table_tr(Lang, true).
make_sessions_table_tr(Lang, Sorting) ->
    Titles = [<<"Jabber ID">>,
	      <<"Client ID">>,
	      <<"OS ID">>,
	      <<"Lang">>,
	      <<"Connection">>,
	      <<"Client">>,
	      <<"Version">>,
	      <<"OS">>],
    {Titles_TR, _} =
	lists:mapfoldl(
	  fun(Title, Num_column) ->
		  NCS = list_to_binary(integer_to_list(Num_column)),
                  SortingEls =
                      case Sorting of
                          false -> [];
                          true -> [?BR,
                                   ?ACT(<<"?sort=", NCS/binary>>, <<"<">>),
                                   ?C(<<" ">>),
                                   ?ACT(<<"?sort=-", NCS/binary>>, <<">">>)]
                      end,
		  TD = ?XE(<<"td">>, [?CT(Title)] ++ SortingEls),
		  {TD, Num_column+1}
	  end,
	  1,
	  Titles),
    Titles_TR.

%% ejabberd 24.02 or older
web_page_node(Acc, Node, Path, Query, Lang) ->
    web_page_node(Acc, Node, #request{method = 'GET',
                                      raw_path = <<"">>,
                                      ip = {{127,0,0,1}, 0},
                                      sockmod = 'gen_tcp',
                                      socket = hd(erlang:ports()),
                                      path = Path, q = Query, lang = Lang}).

web_page_node(_, Node, #request{path = [<<"statsdx">>], lang = Lang}) ->
    TransactionsCommited =
	rpc:call(Node, mnesia, system_info, [transaction_commits]),
    TransactionsAborted =
	rpc:call(Node, mnesia, system_info, [transaction_failures]),
    TransactionsRestarted =
	rpc:call(Node, mnesia, system_info, [transaction_restarts]),
    TransactionsLogged =
	rpc:call(Node, mnesia, system_info, [transaction_log_writes]),

    Res =
	[?XC(<<"h1">>, list_to_binary(io_lib:format(translate:translate(Lang, ?T("~p statistics")), [Node]))),
	 ?XC(<<"h3">>, <<"Connections">>),
	 ?XAE(<<"table">>, [],
	      [?XE(<<"tbody">>, [
			     do_stat(global, Lang, "onlineusers"),
			     do_stat(Node, Lang, "httpbindusers"),
			     do_stat(Node, Lang, "s2sconnections"),
			     do_stat(Node, Lang, "s2sservers")
			    ])
	      ]),
	 ?XC(<<"h3">>, <<"ejabberd">>),
	 ?XAE(<<"table">>, [],
	      [?XE(<<"tbody">>, [
			     do_stat(Node, Lang, "ejabberdversion")
			    ])
	      ]),
	 ?XC(<<"h3">>, <<"Erlang">>),
	 ?XAE(<<"table">>, [],
	      [?XE(<<"tbody">>, [
			     do_stat(Node, Lang, "operatingsystem"),
			     do_stat(Node, Lang, "erlangmachine"),
			     do_stat(Node, Lang, "erlangmachinetarget"),
			     do_stat(Node, Lang, "maxprocallowed"),
			     do_stat(Node, Lang, "procqueue"),
			     do_stat(Node, Lang, "totalerlproc")
			    ])
	      ]),
	 ?XC(<<"h3">>, <<"Times">>),
	 ?XAE(<<"table">>, [],
	      [?XE(<<"tbody">>, [
			     do_stat(Node, Lang, "uptime"),
			     do_stat(Node, Lang, "uptimehuman"),
			     do_stat(Node, Lang, "lastrestart"),
			     do_stat(Node, Lang, "cputime")
			    ])
	      ]),
	 ?XC(<<"h3">>, <<"CPU">>),
	 ?XAE(<<"table">>, [],
	      [?XE(<<"tbody">>, [
			     do_stat(Node, Lang, "cpu_avg1"),
			     do_stat(Node, Lang, "cpu_avg5"),
			     do_stat(Node, Lang, "cpu_avg15"),
			     do_stat(Node, Lang, "cpu_nprocs")%,
			     %%do_stat(Node, Lang, "cpu_util_user"),
			     %%do_stat(Node, Lang, "cpu_nice_user"),
			     %%do_stat(Node, Lang, "cpu_kernel"),
			     %%do_stat(Node, Lang, "cpu_idle"),
			     %%do_stat(Node, Lang, "cpu_wait")
			    ])
	      ]),
	 %%?XC("h3", "RAM"),
	 %%?XAE("table", [],
	 %% [?XE("tbody", [
	 %%  do_stat(Node, Lang, "memsup_system"),
	 %%  do_stat(Node, Lang, "memsup_free"),
	 %%  do_stat(Node, Lang, "reductions")
	 %%])
	 %%]),
	 ?XC(<<"h3">>, <<"Memory (bytes)">>),
	 ?XAE(<<"table">>, [],
	      [?XE(<<"tbody">>, [
			     do_stat(Node, Lang, "memory_total"),
			     do_stat(Node, Lang, "memory_processes"),
			     do_stat(Node, Lang, "memory_processes_used"),
			     do_stat(Node, Lang, "memory_system"),
			     do_stat(Node, Lang, "memory_atom"),
			     do_stat(Node, Lang, "memory_atom_used"),
			     do_stat(Node, Lang, "memory_binary"),
			     do_stat(Node, Lang, "memory_code"),
			     do_stat(Node, Lang, "memory_ets")
			    ])
	      ]),
	 ?XC(<<"h3">>, <<"Database">>),
	 ?XAE(<<"table">>, [],
	      [?XE(<<"tbody">>,
		   [
		    ?XE(<<"tr">>, [?XCT(<<"td">>, <<"Transactions commited">>),
			       ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
				    list_to_binary(integer_to_list(TransactionsCommited)))]),
		    ?XE(<<"tr">>, [?XCT(<<"td">>, <<"Transactions aborted">>),
			       ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
				    list_to_binary(integer_to_list(TransactionsAborted)))]),
		    ?XE(<<"tr">>, [?XCT(<<"td">>, <<"Transactions restarted">>),
			       ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
				    list_to_binary(integer_to_list(TransactionsRestarted)))]),
		    ?XE(<<"tr">>, [?XCT(<<"td">>, <<"Transactions logged">>),
			       ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
				    list_to_binary(integer_to_list(TransactionsLogged)))])
		   ])
	      ])],
    {stop, Res};
web_page_node(Acc, _, _) -> Acc.

web_page_host(_, Host,
	      #request{path = [<<"statsdx">>],
		       lang = Lang} = _Request) ->
    Res = [?XC(<<"h1">>, <<(translate:translate(Lang, ?T("Statistics")))/binary, " Dx">>),
	   ?XC(<<"h2">>, Host),
	   ?XC(<<"h3">>, <<"Accounts">>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "registeredusers", Host)
			      ])
		]),
	   ?XC(<<"h3">>, <<"Roster">>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "totalrosteritems", Host),
			       %%get_meanitemsinroster2(TotalRosterItems, RegisteredUsers)
			       ?XE(<<"tr">>,
				  [?XE(<<"td">>, [?C(<<"Top rosters">>) ]),
				   ?XE(<<"td">>, [
				    ?ACT(<<"top/roster/30/">>, <<"30">>), ?C(<<", ">>),
				    ?ACT(<<"top/roster/100/">>, <<"100">>), ?C(<<", ">>),
				    ?ACT(<<"top/roster/500/">>, <<"500">>) ])]
				 )
			      ])
		]),
	   ?XC(<<"h3">>, <<"Users">>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "onlineusers", Host),
			       %%do_stat(global, Lang, "offlinemsg", Host), %% This make take a lot of time
			       %%do_stat(global, Lang, "vcards", Host) %% This make take a lot of time
			       ?XE(<<"tr">>,
				  [?XE(<<"td">>, [?C(<<"Top offline message queues">>)]),
				   ?XE(<<"td">>, [
				    ?ACT(<<"top/offlinemsg/30/">>, <<"30">>), ?C(<<", ">>),
				    ?ACT(<<"top/offlinemsg/100/">>, <<"100">>), ?C(<<", ">>),
				    ?ACT(<<"top/offlinemsg/500/">>, <<"500">>) ])]
				 ),
			       ?XE(<<"tr">>,
				  [?XE(<<"td">>, [?C(<<"Top vCard sizes">>) ]),
				   ?XE(<<"td">>, [
				    ?ACT(<<"top/vcard/5/">>, <<"5">>), ?C(<<", ">>),
				    ?ACT(<<"top/vcard/30/">>, <<"30">>), ?C(<<", ">>),
				    ?ACT(<<"top/vcard/100/">>, <<"100">>), ?C(<<", ">>),
				    ?ACT(<<"top/vcard/500/">>, <<"500">>) ])]
				 )
			      ])
		]),
	   ?XC(<<"h3">>, <<"Connections">>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "s2sconnections", Host)
			      ])
		]),
	   ?XC(<<"h3">>, <<"MUC">>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "totalmucrooms", Host),
			       do_stat(global, Lang, "permmucrooms", Host),
			       do_stat(global, Lang, "regmucrooms", Host)
			      ])
		]),
	   %%?XC("h3", "IRC"),
	   %%?XAE("table", [],
	   %% [?XE("tbody", [
	   %%  do_stat(global, Lang, "ircconns", Host)
	   %% ])
	   %%]),
	   %%?XC("h3", "Pub/Sub"),
	   %%?XAE("table", [],
	   %% [?XE("tbody", [
	   %%  do_stat(global, Lang, "regpubsubnodes", Host)
	   %% ])
	   %%]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("client"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "client", Host)
		    )
		]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("os"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "os", Host)
		    )
		]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("client"))/binary, "/", (get_stat_n("os"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "client_os", Host)
		    )
		]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("conntype"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "conntype", Host)
		    )
		]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("client"))/binary, "/", (get_stat_n("conntype"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "client_conntype", Host)
		    )
		]),
	   ?XC(<<"h3">>, <<"Sessions: ", (get_stat_n("languages"))/binary>>),
	   ?XAE(<<"table">>, [],
		[?XE(<<"tbody">>,
		     do_stat_table(global, Lang, "languages", Host)
		    )
		]),
	   ?XC(<<"h3">>, <<"Ratios">>),
	   ?XAE(<<"table">>, [],
	   	[?XE(<<"tbody">>, [
			       do_stat(global, Lang, "user_login", Host),
			       do_stat(global, Lang, "user_logout", Host),
			       do_stat(global, Lang, "register_user", Host),
			       do_stat(global, Lang, "remove_user", Host),
			       do_stat(global, Lang, {send, iq, in}, Host),
			       do_stat(global, Lang, {send, iq, out}, Host),
			       do_stat(global, Lang, {send, message, in}, Host),
			       do_stat(global, Lang, {send, message, out}, Host),
			       do_stat(global, Lang, {send, presence, in}, Host),
			       do_stat(global, Lang, {send, presence, out}, Host),
			       do_stat(global, Lang, {recv, iq, in}, Host),
			       do_stat(global, Lang, {recv, iq, out}, Host),
			       do_stat(global, Lang, {recv, message, in}, Host),
			       do_stat(global, Lang, {recv, message, out}, Host),
			       do_stat(global, Lang, {recv, presence, in}, Host),
			       do_stat(global, Lang, {recv, presence, out}, Host)
	   		      ])
	   	])
	  ],
    {stop, Res};
web_page_host(_, Host, #request{path=[<<"statsdx">>, <<"top">>, Topic, Topnumber], q = _Q, lang = Lang} = _Request) ->
    Res = [?XC(<<"h1">>, <<(translate:translate(Lang, ?T("Statistics")))/binary, " Dx">>),
	   case Topic of
		<<"offlinemsg">> -> ?XCT(<<"h2">>, <<"Top offline message queues">>);
		<<"vcard">> -> ?XCT(<<"h2">>, <<"Top vCard sizes">>);
		<<"roster">> -> ?XCT(<<"h2">>, <<"Top rosters">>)
	   end,
	   ?XE(<<"table">>,
	       [?XE(<<"thead">>, [?XE(<<"tr">>,
				  [?XE(<<"td">>, [?CT(<<"#">>)]),
				   ?XE(<<"td">>, [?CT(<<"Jabber ID">>)]),
				   ?XE(<<"td">>, [?CT(<<"Value">>)])]
				 )]),
		?XE(<<"tbody">>, do_top_table(global, Lang, Topic, Topnumber, Host))
	       ])
	  ],
    {stop, Res};
web_page_host(_, Host, #request{path=[<<"statsdx">> | Filter], q = Q,
				lang = Lang} = _Request) ->
    Sort_query = get_sort_query(Q),
    Res = [?XC(<<"h1">>, <<(translate:translate(Lang, ?T("Statistics")))/binary, " Dx">>),
	   ?XC(<<"h2">>, list_to_binary("Sessions with: "++io_lib:format("~p", [Filter]))),
	   ?XAE(<<"table">>, [],
		[
		 ?XE(<<"thead">>, [?XE(<<"tr">>, make_sessions_table_tr(Lang) )]),
		 ?XE(<<"tbody">>, do_sessions_table(global, Lang, Filter, Sort_query, Host))
		])
	  ],
    {stop, Res};
web_page_host(Acc, _, _) -> Acc.


%%%==================================
%%%% Web Admin Utils

do_table_element(Lang, L, StatLink, N) ->
    do_table_element(no_counter, Lang, L, StatLink, N).
do_table_element(Counter, Lang, L, StatLink, N) ->
    ?XE(<<"tr">>, [
	       case Counter of
		   no_counter -> ?C(<<"">>);
		   _ -> ?XE(<<"td">>, [?C(list_to_binary(integer_to_list(Counter)))])
               end,
	       case StatLink of
		   no_link -> ?XCT(<<"td">>, L);
		   {fixed_url, Fixedurl} -> ?XE(<<"td">>, [?AC(list_to_binary(Fixedurl), list_to_binary(L))]);
		   _ -> ?XE(<<"td">>, [?AC(list_to_binary(make_url(StatLink, L)), list_to_binary(L))])
               end,
	       case N of
		   {url, NUrl, NName} -> ?XAE(<<"td">>, [{<<"class">>, <<"alignright">>}], [?AC(list_to_binary(NUrl), list_to_binary(NName))]);
		   N when is_list(N) -> ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}], list_to_binary(N));
		   _ -> ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}], N)
               end
	      ]).

make_url(StatLink, L) ->
    List = case string:tokens(StatLink, "_") of
	       [Stat] ->
		   [Stat, L];
	       [Stat1, Stat2] ->
		   [L1, L2] = string:tokens(L, "/"),
		   [Stat1, L1, Stat2, L2]
	   end,
    string:join(List, "/")++["/"].

do_stat_table(global, Lang, Stat, Host) ->
    Os = mod_statsdx:get_statistic(global, [Stat, Host]),
    lists:map(
      fun({_L, 0}) when Stat == "client" ->
              ?C(<<"">>);
         ({L, N}) ->
	      do_table_element(Lang, L, Stat, io_lib:format("~p", [N]))
      end,
      lists:reverse(lists:keysort(2, Os))
     ).

do_sessions_table(_Node, _Lang, Filter, {Sort_direction, Sort_column}, Host) ->
    Sessions = get_sessions_filtered(Filter, Host),
    SessionsSorted = sort_sessions(Sort_direction, Sort_column, Sessions),
    lists:map(
      fun( {{session, JID}, Client_id, OS_id, LangS, ConnType, Client, Version, OS} ) ->
	      Lang = list_to_binary(LangS),
	      User = binary_to_list(JID#jid.luser),
	      Server = binary_to_list(JID#jid.lserver),
	      Level = case Host of
		server -> 1 + length(Filter);
		_ -> 3 + length(Filter)
	      end,
	      UserURL = lists:duplicate(Level, "../") ++ "server/" ++ Server ++ "/user/" ++ User ++ "/",
              {UpInt, UserEl} =
                  case Filter of
                      [<<"username">>, _] ->
                          {0, ?XCT(<<"td">>, jid:encode(JID))};
                      _ ->
                          {1, ?XE(<<"td">>, [?AC(list_to_binary(UserURL), jid:encode(JID))])}
                  end,
	      UpStr = list_to_binary(lists:duplicate(length(Filter) + UpInt, "../")),
	      ClientIdBin = misc:atom_to_binary(Client_id),
	      OsIdBin = misc:atom_to_binary(OS_id),
	      ConnTypeBin = misc:atom_to_binary(ConnType),
	      ?XE(<<"tr">>, [
			 UserEl,
			 ?XE(<<"td">>, [?AC(<<UpStr/binary, "statsdx/client/", ClientIdBin/binary>>, ClientIdBin)]),
			 ?XE(<<"td">>, [?AC(<<UpStr/binary, "statsdx/os/", OsIdBin/binary>>, OsIdBin)]),
			 ?XE(<<"td">>, [?AC(<<UpStr/binary, "statsdx/languages/", Lang/binary>>, Lang)]),
			 ?XE(<<"td">>, [?AC(<<UpStr/binary, "statsdx/conntype/", ConnTypeBin/binary>>, ConnTypeBin)]),
			 ?XCTB("td", Client),
			 ?XCTB("td", Version),
			 ?XCTB("td", OS)
			])
      end,
      SessionsSorted
     ).

%% Code copied from mod_muc_admin.erl
sort_sessions(Direction, Column, Rooms) ->
    Rooms2 = lists:keysort(Column, Rooms),
    case Direction of
	normal -> Rooms2;
	reverse -> lists:reverse(Rooms2)
    end.

get_sessions_filtered(Filter, server) ->
    lists:foldl(
      fun(Host, Res) ->
	      try get_sessions_filtered(Filter, Host) of
		  List when is_list(List) -> List ++ Res
	      catch
		  _:_ -> Res
	      end
      end,
      [],
      ejabberd_config:get_option(hosts));
get_sessions_filtered(Filter, Host) ->
    Match = case Filter of
		[<<"username">>, Username] -> {{session, {jid, Username, Host, '$1', Username, Host, '$1'}}, '$2', '$3', '$4', '$5', '$6', '$7', '$8'};
		[<<"client">>, Client] -> {{session, '$1'}, misc:binary_to_atom(Client), '$2', '$3', '$4', '$5', '$6', '$7'};
		[<<"os">>, OS] -> {{session, '$1'}, '$2', misc:binary_to_atom(OS), '$3', '$4', '$5', '$6', '$7'};
		[<<"conntype">>, ConnType] -> {{session, '$1'}, '$2', '$3', '$4', misc:binary_to_atom(ConnType), '$5', '$6', '$7'};
		[<<"languages">>, Lang] -> {{session, '$1'}, '$2', '$3', binary_to_list(Lang), '$4', '$5', '$6', '$7'};
		[<<"client">>, Client, <<"os">>, OS] -> {{session, '$1'}, misc:binary_to_atom(Client), misc:binary_to_atom(OS), '$3', '$4', '$5', '$6', '$7'};
		[<<"client">>, Client, <<"conntype">>, ConnType] -> {{session, '$1'}, misc:binary_to_atom(Client), '$2', '$3', misc:binary_to_atom(ConnType), '$5', '$6', '$7'};
		_ -> {{session, '$1'}, '$2', '$3', '$4', '$5'}
	    end,
    ets:match_object(table_name(Host), Match).

do_stat(Node, Lang, Stat) ->
    ?XE(<<"tr">>, [
	       ?XCT(<<"td">>, get_stat_n(Stat)),
	       ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
		    get_stat_v(Node, [Stat]))]).

do_stat(Node, Lang, Stat, Host) ->
    %%[Res] = get_stat_v(Node, [Stat, Host]),
    %%do_table_element(Lang, get_stat_n(Stat), Res).
    do_table_element(Lang, get_stat_n(Stat), no_link, get_stat_v(Node, [Stat, Host])).

%% Get a stat name
get_stat_n(Stat) ->
    list_to_binary(mod_statsdx:get_statistic(foo, [Stat, title])).
%% Get a stat value
get_stat_v(Node, Stat) -> list_to_binary(get_stat_v2(mod_statsdx:get_statistic(Node, Stat))).
get_stat_v2(Value) when is_list(Value) -> Value;
get_stat_v2(Value) when is_float(Value) -> io_lib:format("~.4f", [Value]);
get_stat_v2(Value) when is_integer(Value) ->
    [Str] = io_lib:format("~p", [Value]),
    pretty_string_int(Str);
get_stat_v2(Value) -> io_lib:format("~p", [Value]).

%% Transform "1234567890" into "1,234,567,890"
pretty_string_int(String) ->
    {_, Result} = lists:foldl(
		    fun(NewNumber, {3, Result}) ->
			    {1, [NewNumber, $, | Result]};
		       (NewNumber, {CountAcc, Result}) ->
			    {CountAcc+1, [NewNumber | Result]}
		    end,
		    {0, ""},
		    lists:reverse(String)),
    Result.

%%%==================================
%%%% Commands

commands() ->
    [
     #ejabberd_commands{name = get_top_users, tags = [stats],
			desc = "Get top X users with larger offlinemsg, vcard or roster.",
			policy = admin,
			module = ?MODULE, function = get_top_users,
			args = [{topnumber, integer}, {topic, string}],
			result = {top, {list,
					{user, {tuple, [
							{value, integer},
							{user, string},
							{server, string}
						       ]}}
				       }}},
     #ejabberd_commands{name = getstatsdx, tags = [stats],
			desc = "Get statistical value.",
			policy = admin,
			module = ?MODULE, function = getstatsdx,
			args = [{name, string}],
			result = {stat, integer}},
     #ejabberd_commands{name = getstatsdx_host, tags = [stats],
			desc = "Get statistical value for this host.",
			policy = admin,
			module = ?MODULE, function = getstatsdx,
			args = [{name, string}, {host, string}],
			result = {stat, integer}}
    ].

getstatsdx(Name) ->
    get_statistic(global, [Name]).

getstatsdx(Name, Host) ->
    get_statistic(global, [Name, Host]).

get_top_users(Number, Topic) ->
    get_top_users(server, Number, Topic).

%% Returns: [{Integer, User, Server}]
get_top_users(Host, Number, <<"vcard">>) ->
    get_top_users_vcard(Host, Number);
get_top_users(Host, Number, <<"offlinemsg">>) ->
    get_top_users(Host, Number, offline_msg, #offline_msg.us);
get_top_users(Host, Number, <<"roster">>) ->
    get_top_users(Host, Number, roster, #roster.us).


get_top_users(Host, TopX, Table, RecordUserPos) ->
    F = fun() ->
		F2 = fun(R, {H, Dict}) ->
			     {LUser, LServer} = element(RecordUserPos, R),
			     case H of
				 server ->
				     {Host, dict:update_counter({LUser, LServer}, 1, Dict)};
				 LServer ->
				     {Host, dict:update_counter({LUser, LServer}, 1, Dict)};
				 _ ->
				     {Host, Dict}
			     end
		     end,
		mnesia:foldl(F2, {Host, dict:new()}, Table)
	end,
    {atomic, {Host, DictRes}} = mnesia:transaction(F),
    {_, _, Result} = dict:fold(
		       fun({User, Server}, Num, {EntryNumber, Size, TopList}) ->
			       case {Num > EntryNumber, Size < TopX} of
				   {false, true} ->
				       {Num, Size+1, lists:keymerge(1, TopList, [{Num, User, Server}])};
				   {true, true} ->
				       {EntryNumber, Size+1, lists:keymerge(1, TopList, [{Num, User, Server}])};
				   {true, false} ->
				       [{NewEntryNumber, _, _} | _] = TopList2 = lists:keydelete(EntryNumber, 1, TopList),
				       {NewEntryNumber, Size, lists:keymerge(1, TopList2, [{Num, User, Server}])};
				   {false, false} ->
				       {EntryNumber, Size, TopList}
			       end
		       end,
		       {10000000000000000, 0, []},
		       DictRes),
    lists:reverse(Result).

get_top_users_vcard(Host, Number) ->
    F = fun() ->
	B = fun get_users_vcard_fun/2,
	{_Host, _NumSelects, _MinSize, _Sizes, Selects} = mnesia:foldl(B, {Host, Number, -1, [], []}, vcard), %+++
	Selects
    end,
    {atomic, Result} = mnesia:transaction(F),
    lists:reverse(Result).

%% Selects = [{Size, Vcard}] sorted from smaller to larger
get_users_vcard_fun(#vcard{us = {_, Host1}}, {HostReq, NumRemaining, MinSize, Sizes, Selects})
    when (Host1 /= HostReq) and (HostReq /= server) ->
    {HostReq, NumRemaining, MinSize, Sizes, Selects};
get_users_vcard_fun(Vcard, {HostReq, NumRemaining, MinSize, Sizes, Selects}) ->
    Binary = fxml:element_to_binary(Vcard#vcard.vcard),
    Size = byte_size(Binary),
    case {Size > MinSize, NumRemaining > 0} of
	{true, true} ->
	    {User, Host} = Vcard#vcard.us,
	    Selects2 = lists:umerge(Selects, [{Size, User, Host}]),
	    Sizes2 = lists:umerge(Sizes, [Size]),
	    MinSize2 = lists:min(Sizes2),
	    {HostReq, NumRemaining-1, MinSize2, Sizes2, Selects2};
	{true, false} ->
	    [_ | SelectsReduced] = Selects,
	    [_ | SizesReduced] = Sizes,
	    Sizes2 = lists:umerge(SizesReduced, [Size]),
	    MinSize2 = lists:min(Sizes2),
	    {User, Host} = Vcard#vcard.us,
	    Selects2 = lists:umerge(SelectsReduced, [{Size, User, Host}]),
	    {HostReq, NumRemaining, MinSize2, Sizes2, Selects2};
	{false, _} ->
	    {HostReq, NumRemaining, MinSize, Sizes, Selects}
    end.


%%%==================================

%%% vim: set foldmethod=marker foldmarker=%%%%,%%%=:
