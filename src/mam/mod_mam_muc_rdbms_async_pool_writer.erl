%%%-------------------------------------------------------------------
%%% @author Uvarov Michael <arcusfelis@gmail.com>
%%% @copyright (C) 2013, Uvarov Michael
%%% @doc Collect messages and flush them into the database.
%%% @end
%%%-------------------------------------------------------------------
-module(mod_mam_muc_rdbms_async_pool_writer).

%% ----------------------------------------------------------------------
%% Exports

%% gen_mod handlers
-export([start/2, stop/1]).

%% MAM hook handlers
-behaviour(ejabberd_gen_mam_archive).
-export([archive_size/4,
         archive_message/3,
         lookup_messages/3,
         remove_archive/4]).

%% Helpers for debugging
-export([queue_length/1,
         queue_lengths/1]).

%% gen_server callbacks
-export([init/1, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(PER_MESSAGE_FLUSH_TIME, [?MODULE, per_message_flush_time]).
-define(FLUSH_TIME, [?MODULE, flush_time]).
-define(DEFAULT_POOL_SIZE, 32).

-include("mongoose.hrl").
-include("jlib.hrl").

-record(state, {flush_interval      :: non_neg_integer(), %% milliseconds
                max_batch_size     :: non_neg_integer(),
                host_type           :: mongooseim:host_type(),
                acc=[]              :: list(),
                flush_interval_tref :: reference() | undefined
              }).
-type state() :: #state{}.

worker_prefix() ->
    "ejabberd_mod_mam_muc_writer".


%% @doc Ensure, that:
%% `worker_count(_) = Int * mod_mam_muc_rdbms_arch:partition_count()'
%%
%% For example,
%% `worker_count(_) = 32, partition_count() = 16'.
%% or
%% `worker_count(_) = 16, partition_count() = 16'.
worker_count(HostType) ->
    gen_mod:get_module_opt(HostType, ?MODULE, pool_size, ?DEFAULT_POOL_SIZE).


-spec worker_names(mongooseim:host_type()) -> [{integer(), atom()}].
worker_names(HostType) ->
    [{N, worker_name(HostType, N)} || N <- lists:seq(0, worker_count(HostType) - 1)].


-spec worker_name(mongooseim:host_type(), integer()) -> atom().
worker_name(HostType, N) ->
    list_to_atom(worker_prefix() ++ "_" ++ binary_to_list(HostType) ++ "_" ++ integer_to_list(N)).


-spec select_worker(mongooseim:host_type(), integer()) -> atom().
select_worker(HostType, ArcID) ->
    N = worker_number(HostType, ArcID),
    worker_name(HostType, N).


-spec worker_number(mongooseim:host_type(), mod_mam:archive_id()) -> integer().
worker_number(HostType, ArcID) ->
    ArcID rem worker_count(HostType).


%% ----------------------------------------------------------------------
%% gen_mod callbacks
%% Starting and stopping functions for users' archives

-spec start(mongooseim:host_type(), _) -> 'ok'.
start(HostType, Opts) ->
    mongoose_metrics:ensure_metric(HostType, ?PER_MESSAGE_FLUSH_TIME, histogram),
    mongoose_metrics:ensure_metric(HostType, ?FLUSH_TIME, histogram),
    MaxSize = gen_mod:get_module_opt(HostType, ?MODULE, max_batch_size, 30),
    mod_mam_muc_rdbms_arch:prepare_insert(insert_mam_muc_message, 1),
    mod_mam_muc_rdbms_arch:prepare_insert(insert_mam_muc_messages, MaxSize),
    start_workers(HostType, MaxSize),
    start_muc(HostType, Opts).


-spec stop(mongooseim:host_type()) -> any().
stop(HostType) ->
    stop_muc(HostType),
    stop_workers(HostType).

%% ----------------------------------------------------------------------
%% Add hooks for mod_mam_muc

-spec start_muc(mongooseim:host_type(), _) -> 'ok'.
start_muc(HostType, _Opts) ->
    ejabberd_hooks:add(mam_muc_archive_message, HostType, ?MODULE, archive_message, 50),
    ok.


-spec stop_muc(mongooseim:host_type()) -> 'ok'.
stop_muc(HostType) ->
    ejabberd_hooks:delete(mam_muc_archive_message, HostType, ?MODULE, archive_message, 50),
    ok.

%%====================================================================
%% API
%%====================================================================

-spec start_workers(mongooseim:host_type(), MaxSize :: pos_integer()) -> [{'error', _}
                                        | {'ok', 'undefined' | pid()}
                                        | {'ok', 'undefined' | pid(), _}].
start_workers(HostType, MaxSize) ->
    [start_worker(WriterProc, N, HostType, MaxSize)
     || {N, WriterProc} <- worker_names(HostType)].


-spec stop_workers(mongooseim:host_type()) -> ['ok'
    | {'error', 'not_found' | 'restarting' | 'running' | 'simple_one_for_one'}].
stop_workers(HostType) ->
    [stop_worker(WriterProc) ||  {_, WriterProc} <- worker_names(HostType)].


-spec start_worker(atom(), integer(), mongooseim:host_type(), MaxSize :: pos_integer())
      -> {'error', _}
         | {'ok', 'undefined' | pid()}
         | {'ok', 'undefined' | pid(), _}.
start_worker(WriterProc, _N, HostType, MaxSize) ->
    WriterChildSpec =
    {WriterProc,
     {gen_server, start_link, [{local, WriterProc}, ?MODULE, [HostType, MaxSize], []]},
     permanent,
     5000,
     worker,
     [mod_mam_muc_rdbms_async_pool_writer]},
    supervisor:start_child(mod_mam_sup, WriterChildSpec).


-spec stop_worker(atom()) -> 'ok'
        | {'error', 'not_found' | 'restarting' | 'running' | 'simple_one_for_one'}.
stop_worker(Proc) ->
    supervisor:terminate_child(mod_mam_sup, Proc),
    supervisor:delete_child(mod_mam_sup, Proc).

-spec archive_message(_Result, mongooseim:host_type(), mod_mam:archive_message_params()) ->
          ok | {error, timeout}.
archive_message(_Result, HostType, Params0 = #{archive_id := RoomID}) ->
    Params = mod_mam_muc_rdbms_arch:extend_params_with_sender_id(HostType, Params0),
    Worker = select_worker(HostType, RoomID),
    WorkerPid = whereis(Worker),
    %% Send synchronously if queue length is too long.
    case is_overloaded(WorkerPid) of
        false ->
            gen_server:cast(Worker, {archive_message, Params});
        true ->
            {Pid, MonRef} = spawn_monitor(fun() ->
                                                  gen_server:cast(Worker, {archive_message, Params})
                                          end),
            receive
                {'DOWN', MonRef, process, Pid, normal} -> ok;
                {'DOWN', MonRef, process, Pid, _} ->
                    mongoose_metrics:update(HostType, modMamDropped, 1),
                    {error, timeout}
            end
    end.


-spec is_overloaded(pid()) -> boolean().
is_overloaded(Pid) ->
    {message_queue_len, Len} = erlang:process_info(Pid, message_queue_len),
    Len > 500.


%% @doc For metrics.
-spec queue_length(mongooseim:host_type()) -> {'ok', number()}.
queue_length(HostType) ->
    Len = lists:sum(queue_lengths(HostType)),
    {ok, Len}.


-spec queue_lengths(mongooseim:host_type()) -> [non_neg_integer()].
queue_lengths(HostType) ->
    [worker_queue_length(SrvName) || {_, SrvName} <- worker_names(HostType)].


-spec worker_queue_length(atom()) -> non_neg_integer().
worker_queue_length(SrvName) ->
    case whereis(SrvName) of
        undefined ->
            0;
        Pid ->
            {message_queue_len, Len} = erlang:process_info(Pid, message_queue_len),
            Len
    end.


-spec archive_size(integer(), mongooseim:host_type(), mod_mam:archive_id(),
                   jid:jid()) -> integer().
archive_size(Size, HostType, ArcID, _ArcJID) when is_integer(Size) ->
    Size.


-spec lookup_messages(Result :: any(), HostType :: mongooseim:host_type(), Params :: map()) ->
    {ok, mod_mam:lookup_result()}.
lookup_messages(Result, HostType, #{archive_id := ArcID, end_ts := End, now := Now}) ->
    Result.

%% #rh
-spec remove_archive(map(), mongooseim:host_type(), mod_mam:archive_id(), jid:jid()) -> map().
remove_archive(Acc, HostType, ArcID, _ArcJID) ->
    Acc.

%%====================================================================
%% Internal functions
%%====================================================================

-spec run_flush(state()) -> state().
run_flush(State = #state{acc=[]}) ->
    State;
run_flush(State = #state{host_type = HostType, acc = Acc}) ->
    MessageCount = length(Acc),
    {FlushTime, NewState} = timer:tc(fun do_run_flush/2, [MessageCount, State]),
    mongoose_metrics:update(HostType, ?PER_MESSAGE_FLUSH_TIME, round(FlushTime / MessageCount)),
    mongoose_metrics:update(HostType, ?FLUSH_TIME, FlushTime),
    NewState.

do_run_flush(MessageCount, State = #state{host_type = HostType, max_batch_size = MaxSize,
                                          flush_interval_tref = TRef, acc = Acc}) ->
    cancel_and_flush_timer(TRef),
    ?LOG_DEBUG(#{what => mam_flush, message_count => MessageCount}),

    Rows = [mod_mam_muc_rdbms_arch:prepare_message(HostType, Params) || Params <- Acc],

    InsertResult =
        case MessageCount of
            MaxSize ->
                mongoose_rdbms:execute(HostType, insert_mam_muc_messages, lists:append(Rows));
            OtherSize ->
                Results = [mongoose_rdbms:execute(HostType, insert_mam_muc_message, Row) || Row <- Rows],
                case lists:keyfind(error, 1, Results) of
                    false -> {updated, OtherSize};
                    Error -> Error
                end
        end,

    case InsertResult of
        {updated, _Count} -> ok;
        {error, Reason} ->
            mongoose_metrics:update(HostType, modMamDropped2, MessageCount),
            ?LOG_ERROR(#{what => archive_message_query_failed,
                         text => <<"archive_message query failed, modMamDropped2 metric updated">>,
                         message_count => MessageCount, reason => Reason}),
            ok
    end,

    [mod_mam_muc_rdbms_arch:retract_message(HostType, Params) || Params <- Acc],

    spawn_link(fun() ->
                       mongoose_hooks:mam_muc_flush_messages(HostType, MessageCount)
               end),
    erlang:garbage_collect(),
    State#state{acc=[], flush_interval_tref=undefined}.


-spec cancel_and_flush_timer('undefined' | reference()) -> 'ok'.
cancel_and_flush_timer(undefined) ->
    ok;
cancel_and_flush_timer(TRef) ->
    case erlang:cancel_timer(TRef) of
        false ->
            receive
                flush -> ok
            after 0 -> ok
            end;
        _ -> ok
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([HostType, MaxSize]) ->
    %% Use a private RDBMS-connection.
    Int = gen_mod:get_module_opt(HostType, ?MODULE, flush_interval, 2000),
    {ok, #state{host_type = HostType, flush_interval = Int, max_batch_size = MaxSize}}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------

handle_cast({archive_message, Params},
            State=#state{acc=Acc, flush_interval_tref=TRef, flush_interval=Int,
                         max_batch_size=Max}) ->
    TRef2 = case {Acc, TRef} of
                {[], undefined} -> erlang:send_after(Int, self(), flush);
                {_, _} -> TRef
            end,
    State2 = State#state{acc=[Params|Acc], flush_interval_tref=TRef2},
    case length(Acc) + 1 >= Max of
        true -> {noreply, run_flush(State2)};
        false -> {noreply, State2}
    end;
handle_cast(Msg, State) ->
    ?UNEXPECTED_CAST(Msg),
    {noreply, State}.


%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

-spec handle_info('flush', state()) -> {'noreply', state()}.
handle_info(flush, State) ->
    {noreply, run_flush(State#state{flush_interval_tref=undefined})};
handle_info(Msg, State) ->
    ?UNEXPECTED_INFO(Msg),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
