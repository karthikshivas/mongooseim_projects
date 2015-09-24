-module(mod_auth_token).

-behavior(gen_mod).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("mod_auth_token.hrl").


%% gen_mod callbacks
-export([start/2,
         stop/1]).

-export([process_iq/3]).

-compile([export_all]).


start(Host, Opts) ->
   mod_disco:register_feature(Host, ?NS_AUTH_TOKEN),
   IQDisc = gen_mod:get_opt(iqdisc, Opts, no_queue),
   gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_AUTH_TOKEN, ?MODULE, process_iq, IQDisc),
   ok.

stop(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_AUTH_TOKEN),
  ok.

validate_access_token(TokenIn) ->
    %% io:format("~n validate_access_token: : ~n~p~n ", [TokenIn]),
    TokenReceivedRec = get_token_as_record(TokenIn),
    %% io:format("~n Token Parsed as: : ~n~p~n ", [TokenReceivedRec]),
    #auth_token{user_jid = TokenOwnerUser} = TokenReceivedRec,
    io:format("~n Token Owner: ~n~p~n ", [TokenOwnerUser]),
    UsersKey = acquire_key_for_user(TokenOwnerUser),
    %% io:format("~n Token Owner Key: ~n~p~n ", [UsersKey]),

    #auth_token{token_body = RecvdTokenBody} = TokenReceivedRec,
    MACreference = get_token_mac(RecvdTokenBody, UsersKey, get_hash_algorithm()),

    #auth_token{mac_signature = MACReceived} = TokenReceivedRec,

    MACCheckResult = MACReceived =:= MACreference,
   {MACCheckResult, mod_auth_token}.

process_iq(From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
%%    io:format("~ngot something !!! : ~p~n ", [IQ]),
    case xml:get_tag_attr(<<"xmlns">>, SubEl) of
        false ->
            {error, ?ERR_BAD_REQUEST};
        {value, Ns} ->
            case Ns of
                ?NS_AUTH_TOKEN ->
                    create_token_response(From, IQ);
                _OTHER  ->
                    {error, ?ERR_BAD_REQUEST}
                end
    end.

create_token_response(From, IQ) ->
    IQ#iq{type = result,
          sub_el = [#xmlel{name = <<"items">>,
                           attrs = [{<<"xmlns">>, ?NS_AUTH_TOKEN}],
                           children = tokens_body(From)}]}.

%% generate expiry date for access/refresh/provisioning tokens
%% Expiry date/time is returned as gregorian seconds
get_token_expiry_date() ->
    get_expiry_date_from_config().

%% DateTime -> integer()
datetime_to_seconds(DateTime) ->
    calendar:datetime_to_gregorian_seconds(DateTime).

%% integer -> DateTime
seconds_to_datetime(Seconds) ->
    calendar:gregorian_seconds_to_datetime(Seconds).

%% returns DateTime
get_expiry_date_from_config() ->
    %% todo: set / parametrize it somehow - tbd
    calendar:local_time().

tokens_body(User) ->

    Halgo = get_hash_algorithm(),
    UserBareJid = get_bare_jid_binary(User),

    %% todo: handle revocation!
    SeqNo = 555,
    ExpiryDate = get_expiry_date_from_config(),
    UserKey  = acquire_key_for_user(UserBareJid),

    {AccessToken, MacAccess}  = generate_access_token(UserBareJid, ExpiryDate, UserKey, Halgo),
    {RefreshToken, MacRefresh} = generate_refresh_token(UserBareJid, ExpiryDate, UserKey, Halgo, SeqNo),

    AccessTokenMac = concat_token_mac(AccessToken, MacAccess),
    RefreshTokenMac = concat_token_mac(RefreshToken, MacRefresh),

    [
     #xmlel{ name = <<"access_token">>,
             children=[#xmlcdata{content = encode_for_transport(AccessTokenMac)}] },
     #xmlel{ name = <<"refresh_token">>,
             children=[#xmlcdata{content = encode_for_transport(RefreshTokenMac)}]}
    ].

% ----------------------------- tokens assembly routines -----------------
%% returns binary Token + Mac glued together using + separator.
%% args: binary(), binary() -> binary()
concat_token_mac(TokenRaw, Mac) when is_binary(TokenRaw), is_binary(Mac) ->
    <<TokenRaw/binary, "+", Mac/binary>>.

%% returns Token body and the MAC as tuple {Token, MAC}
%% args: binary() -> {binary(), binary()}
token_mac_split(Token) when is_binary(Token) ->
    R = binary:split(Token, <<"+">>, [global]),
    {hd(R), lists:last(R)}.

%% split decoded (eg from base64) token to list of binaries
%% args: binary() -> [binary()]
token_body_split(Token) when is_binary(Token) ->
    binary:split(Token, <<"&">>, [global]).


%% generate Message Authentication Code based on content and secret key
get_token_mac(TokenBin, SecretKey, Method) ->
    crypto:hmac(Method, SecretKey, TokenBin).

assemble_token_from_params(TokenParams) ->
    lists:foldl(fun(X,Sum) -> <<Sum/binary, X/binary,"&">> end, <<>> , TokenParams).
   % https://developers.google.com/talk/jep_extensions/oauth

%% args: binary(), datetime(), binary(), atom() -> {binary(), binary()}
generate_access_token(UserBareJid, ExpiryDateTime, Key, HashAlgorithm) ->
    RawAccessToken  = generate_access_token_body(UserBareJid, ExpiryDateTime),
    Mac = get_token_mac(RawAccessToken, Key, HashAlgorithm),
    %% io:format("~n Access Token (raw) ~p ~n ", [RawAccessToken]),
    %% io:format("~n MAC ~p ~n ", [Mac]),
    {RawAccessToken, Mac}.

generate_access_token_body(UserBareJid, ExpiryDateTime) ->

    UserAccessTokenParams = [
                             term_to_binary(access),    %% eg. access
                             UserBareJid,               %% <<"bob@host.com">>
                             term_to_binary(datetime_to_seconds(ExpiryDateTime)) %% {{2015,9,21},{12,29,51}}
                            ],

    io:format("~n UserAccessTokenParams: ~p ~n", [UserAccessTokenParams]),
    assemble_token_from_params(UserAccessTokenParams).


generate_refresh_token(UserBareJid, ExpiryDateTime, Key, HashAlgorithm, SeqNo) ->

    RawRefreshToken = generate_refresh_token_body(
                               UserBareJid, ExpiryDateTime, SeqNo),

    Mac = get_token_mac(RawRefreshToken, Key, HashAlgorithm),
    io:format("~n Refresh Token (raw)  ~p ~n ", [RawRefreshToken]),
    io:format("~n MAC ~p ~n ", [Mac]),
    {RawRefreshToken, Mac}.

generate_refresh_token_body(UserBareJid, ExpiryDateTime, SeqNo) ->

    UserRefreshTokenParams = [
                              term_to_binary(refresh),
                              UserBareJid,
                              term_to_binary(datetime_to_seconds(ExpiryDateTime)),
                              term_to_binary(SeqNo)   %%  234982
                             ],

    assemble_token_from_params(UserRefreshTokenParams).

%% args: Token with Mac decoded from transport, #auth_token
%% is shared between tokens. Introduce other container types if
%% they start to differ more than a few fields.
%% args: {binary(),binary()} -> #auth_token()
get_token_as_record(TokenIn) ->
    {Token, MAC} = token_mac_split(TokenIn),
    TokenParts =  token_body_split(Token),
    TokenType = binary_to_term(lists:nth(1, TokenParts)),
    SeqNo = case TokenType of
                access -> -1;
                refresh -> binary_to_term(lists:nth(4, TokenParts))
            end,

    #auth_token{type = TokenType,
                expiry_datetime = seconds_to_datetime(binary_to_term(lists:nth(3, TokenParts))),
                user_jid = lists:nth(2, TokenParts),
                sequence_no = SeqNo,
                mac_signature = MAC,
                token_body = Token
               }.

acquire_key_for_user(User) ->
    #jid{lserver = UsersHost} = jlib:binary_to_jid(User),
    %% todo : extract key name from config (possible resolution by host)
    [{asdqwe_access_secret, RawKey}] = ejabberd_hooks:run_fold(get_key, UsersHost, [], [asdqwe_access_secret]),
    RawKey.

split_token(TokenBody) ->
    Parts = token_body_split(TokenBody).

%% consider reading it out of config file
get_hash_algorithm() ->
    sha384.

%% args: binary() -> binary()
decode_from_transport(Data) ->
    base64:decode(Data).

%% args: binary() -> binary()
encode_for_transport(Data) ->
    base64:encode(Data).


%% args: -record #jid
get_bare_jid_binary(User) ->
    U = User#jid.luser,
    S = User#jid.lserver,
    <<U/binary,"@",S/binary>>.




