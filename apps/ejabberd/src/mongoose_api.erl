-module(mongoose_api).

%% ejabberd_cowboy callbacks
-export([cowboy_router_paths/2]).

%% cowboy_rest callbacks
-export([init/3,
         rest_init/2,
         rest_terminate/2]).

-export([allowed_methods/2,
         content_types_provided/2,
         content_types_accepted/2]).

-export([to_xml/2,
         to_json/2,
         from_json/2]).

-record(state, {handler, opts, bindings}).

-type prefix() :: string().
-type route() :: {string(), options()}.
-type routes() :: [route()].
-type bindings() :: proplists:proplist().
-type options() :: [any()].
-type response() :: {ok, any()} | {error, atom()}.
-export_type([prefix/0, routes/0, route/0, bindings/0, options/0, response/0]).

-callback prefix() -> prefix().
-callback routes() -> routes().
-callback handle_get(bindings(), options()) -> response().

%%--------------------------------------------------------------------
%% ejabberd_cowboy callbacks
%%--------------------------------------------------------------------
cowboy_router_paths(Base, Opts) ->
    Handlers = gen_mod:get_opt(handlers, Opts, []),
    lists:flatmap(pa:bind(fun register_handler/2, Base), Handlers).

register_handler(Base, Handler) ->
    [{[Base, Handler:prefix(), Path], ?MODULE, [{handler, Handler}|Opts]}
     || {Path, Opts} <- Handler:routes()].

%%--------------------------------------------------------------------
%% cowboy_rest callbacks
%%--------------------------------------------------------------------
init({_Transport, http}, Req, Opts) ->
    {upgrade, protocol, cowboy_rest, Req, Opts}.

rest_init(Req, Opts) ->
    case lists:keytake(handler, 1, Opts) of
        {value, {handler, Handler}, Opts1} ->
            {Bindings, Req1} = cowboy_req:bindings(Req),
            State = #state{handler=Handler, opts=Opts1, bindings=Bindings},
            {ok, Req1, State};
        false ->
            erlang:throw(no_handler_defined)
    end.

rest_terminate(_Req, _State) ->
    ok.

allowed_methods(Req, #state{handler=Handler}=State) ->
    Methods = lists:foldl(fun collect_allowed_methods/2,
                          [<<"OPTIONS">>], Handler:module_info(exports)),
    {Methods, Req, State}.

content_types_provided(Req, State) ->
    CTP = [{{<<"application">>, <<"json">>, '*'}, to_json},
           {{<<"application">>, <<"xml">>, '*'}, to_xml}],
    {CTP, Req, State}.

content_types_accepted(Req, State) ->
    CTA = [{{<<"application">>, <<"json">>, '*'}, from_json}],
    {CTA, Req, State}.

%%--------------------------------------------------------------------
%% content_types_provided/2 callbacks
%%--------------------------------------------------------------------
to_json(Req, State) ->
    handle_get(mongoose_api_json, Req, State).

to_xml(Req, State) ->
    handle_get(mongoose_api_xml, Req, State).

%%--------------------------------------------------------------------
%% content_types_accepted/2 callbacks
%%--------------------------------------------------------------------
from_json(Req, State) ->
    handle_unsafe(mongoose_api_json, Req, State).

%%--------------------------------------------------------------------
%% HTTP verbs handlers
%%--------------------------------------------------------------------
handle_get(Serializer, Req, #state{opts=Opts, bindings=Bindings}=State) ->
    Result = call(handle_get, [Bindings, Opts], State),
    handle_result(Result, Serializer, Req, State).

handle_unsafe(Deserializer, Req, State) ->
    {Method, Req1} = cowboy_req:method(Req),
    {ok, Body, Req2} = cowboy_req:body(Req1),
    case Deserializer:deserialize(Body) of
        {ok, Data} ->
            handle_unsafe(Method, Data, Req2, State);
        {error, _Reason} ->
            {false, Req2, State}
    end.

handle_unsafe(<<"POST">>, Data, Req, State) ->
    handle_post(Data, Req, State);
handle_unsafe(_Other, _Data, Req, State) ->
    error_response(not_implemented, Req, State).

handle_post(Data, Req, #state{opts=Opts, bindings=Bindings}=State) ->
    Result = call(handle_post, [Data, Bindings, Opts], State),
    handle_result(Result, Req, State).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
collect_allowed_methods({handle_get, 2}, Acc) ->
    [<<"HEAD">>, <<"GET">> | Acc];
collect_allowed_methods({handle_post, 3}, Acc) ->
    [<<"POST">> | Acc];
collect_allowed_methods(_Other, Acc) ->
    Acc.

handle_result({ok, Result}, Serializer, Req, State) ->
    serialize(Result, Serializer, Req, State);
handle_result(Other, _Serializer, Req, State) ->
    handle_result(Other, Req, State).

handle_result(ok, Req, State) ->
    {true, Req, State};
handle_result({error, Error}, Req, State) ->
    error_response(Error, Req, State);
handle_result(no_call, Req, State) ->
    error_response(not_implemented, Req, State).

serialize(Data, Serializer, Req, State) ->
    {Serializer:serialize(Data), Req, State}.

call(Function, Args, #state{handler=Handler}) ->
    try
        apply(Handler, Function, Args)
    catch error:undef ->
        no_call
    end.

%%--------------------------------------------------------------------
%% Error responses
%%--------------------------------------------------------------------
error_response(Code, Req, State) when is_integer(Code) ->
    {ok, Req1} = cowboy_req:reply(Code, Req),
    {halt, Req1, State};
error_response(Reason, Req, State) ->
    error_response(error_code(Reason), Req, State).

error_code(not_found)       -> 404;
error_code(not_implemented) -> 501.
