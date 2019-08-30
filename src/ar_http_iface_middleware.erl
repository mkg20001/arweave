-module(ar_http_iface_middleware).
-behaviour(cowboy_middleware).
-export([execute/2, read_complete_body/1]).
-include("ar.hrl").
-define(HANDLER_TIMEOUT, 55000).

%%%===================================================================
%%% Cowboy handler callbacks.
%%%===================================================================

%% To allow prometheus_cowboy2_handler to be run when the
%% cowboy_router middleware matches on the /metrics route, this
%% middleware runs between the cowboy_router and cowboy_handler
%% middlewares. It uses the `handler` env value set by cowboy_router
%% to determine whether or not it should run, otherwise it lets
%% the cowboy_handler middleware run prometheus_cowboy2_handler.
execute(Req, #{ handler := ar_http_iface_handler } = Env) ->
	Pid = self(),
	Req1 = with_pid_req_field(Req, Pid),
	Req2 = with_arql_semaphore_req_field(Req1, Env),
	HandlerPid = spawn_link(fun() ->
		Pid ! {handled, handle(Req2)}
	end),
	{ok, TimeoutRef} = timer:send_after(
		?HANDLER_TIMEOUT,
		{timeout, HandlerPid, Req}
	),
	loop(TimeoutRef);
execute(Req, Env) ->
	{ok, Req, Env}.

%%%===================================================================
%%% Private functions.
%%%===================================================================

with_pid_req_field(Req, Pid) ->
	Req#{ '_ar_http_iface_middleware_pid' => Pid }.

with_arql_semaphore_req_field(Req, #{ arql_semaphore := Name }) ->
	Req#{ '_ar_http_iface_middleware_arql_semaphore' => Name }.

%% @doc In order to be able to have a handler-side timeout, we need to
%% handle the request asynchronously. However, cowboy doesn't allow
%% reading the request's body from a process other than its handler's.
%% This following loop function allows us to work around this
%% limitation. (see https://github.com/ninenines/cowboy/issues/1374)
loop(TimeoutRef) ->
	receive
		{handled, {Status, Headers, Body, HandledReq}} ->
			timer:cancel(TimeoutRef),
			CowboyStatus = handle208(Status),
			RepliedReq = cowboy_req:reply(CowboyStatus, Headers, Body, HandledReq),
			{stop, RepliedReq};
		{read_complete_body, From, Req} ->
			Term = do_read_complete_body(Req),
			From ! {read_complete_body, Term},
			loop(TimeoutRef);
		{timeout, HandlerPid, InitialReq} ->
			unlink(HandlerPid),
			exit(HandlerPid, handler_timeout),
			ar:warn([
				handler_timeout,
				{method, cowboy_req:method(InitialReq)},
				{path, cowboy_req:path(InitialReq)}
			]),
			RepliedReq = cowboy_req:reply(500, #{}, <<"Handler timeout">>, InitialReq),
			{stop, RepliedReq}
	end.

handle(Req) ->
	%% Inform ar_bridge about new peer, performance rec will be updated from cowboy_metrics_h
	%% (this is leftover from update_performance_list)
	Peer = arweave_peer(Req),
	handle(Peer, Req).

handle(Peer, Req) ->
	Method = cowboy_req:method(Req),
	SplitPath = ar_http_iface_server:split_path(cowboy_req:path(Req)),
	case ar_meta_db:get(http_logging) of
		true ->
			ar:info(
				[
					http_request,
					{method, Method},
					{path, SplitPath},
					{peer, Peer}
				]
			);
		_ ->
			do_nothing
	end,
	case ar_meta_db:get({peer, Peer}) of
		not_found ->
			ar_bridge:add_remote_peer(whereis(http_bridge_node), Peer);
		_ ->
			do_nothing
	end,
	case handle(Method, SplitPath, Req) of
		{Status, Hdrs, Body, HandledReq} ->
			{Status, maps:merge(?DEFAULT_RESPONSE_HEADERS, Hdrs), Body, HandledReq};
		{Status, Body, HandledReq} ->
			{Status, ?DEFAULT_RESPONSE_HEADERS, Body, HandledReq}
	end.

%% @doc Return network information from a given node.
%% GET request to endpoint /info
handle(<<"GET">>, [], Req) ->
	return_info(Req);

handle(<<"GET">>, [<<"info">>], Req) ->
	return_info(Req);

%% @doc Some load balancers use 'HEAD's rather than 'GET's to tell if a node
%% is alive. Appease them.
handle(<<"HEAD">>, [], Req) ->
	{200, #{}, <<>>, Req};
handle(<<"HEAD">>, [<<"info">>], Req) ->
	{200, #{}, <<>>, Req};

%% @doc Return permissive CORS headers for all endpoints
handle(<<"OPTIONS">>, [<<"block">>], Req) ->
	{200, #{<<"access-control-allow-methods">> => <<"GET, POST">>,
		    <<"access-control-allow-headers">> => <<"Content-Type">>}, <<"OK">>, Req};
handle(<<"OPTIONS">>, [<<"tx">>], Req) ->
	{200, #{<<"access-control-allow-methods">> => <<"GET, POST">>,
		    <<"access-control-allow-headers">> => <<"Content-Type">>}, <<"OK">>, Req};
handle(<<"OPTIONS">>, [<<"peer">>|_], Req) ->
	{200, #{<<"access-control-allow-methods">> => <<"GET, POST">>,
		    <<"access-control-allow-headers">> => <<"Content-Type">>}, <<"OK">>, Req};
handle(<<"OPTIONS">>, [<<"arql">>], Req) ->
	{200, #{<<"access-control-allow-methods">> => <<"GET, POST">>,
		    <<"access-control-allow-headers">> => <<"Content-Type">>}, <<"OK">>, Req};
handle(<<"OPTIONS">>, _, Req) ->
	{200, #{<<"access-control-allow-methods">> => <<"GET">>}, <<"OK">>, Req};

handle(Method, [<<"api">>, <<"ipfs">> | Path], Req) ->
	app_ipfs_daemon_server:handle(Method, Path, Req);

%% @doc Return the current universal time in seconds.
handle(<<"GET">>, [<<"time">>], Req) ->
	{200, #{}, integer_to_binary(os:system_time(second)), Req};

%% @doc Return all mempool transactions.
%% GET request to endpoint /tx/pending.
handle(<<"GET">>, [<<"tx">>, <<"pending">>], Req) ->
	{200, #{},
			ar_serialize:jsonify(
				%% Should encode
				lists:map(
					fun ar_util:encode/1,
					ar_node:get_pending_txs(whereis(http_entrypoint_node))
				)
			),
	Req};

%% @doc Return additional information about the transaction with the given identifier (hash).
%% GET request to endpoint /tx/{hash}.
handle(<<"GET">>, [<<"tx">>, Hash, <<"status">>], Req) ->
	ar_semaphore:acquire(arql_semaphore(Req), 5000),
	case get_tx_filename(Hash) of
		{ok, _} ->
			TagsToInclude = [
				<<"block_height">>,
				<<"block_indep_hash">>
			],
			Tags = lists:filter(
				fun(Tag) ->
					{Name, _} = Tag,
					lists:member(Name, TagsToInclude)
				end,
				?OK(ar_tx_search:get_tags_by_id(ar_util:decode(Hash)))
			),
			CurrentBHL = ar_node:get_hash_list(whereis(http_entrypoint_node)),
			[TXIndepHashEncoded] = proplists:get_all_values(<<"block_indep_hash">>, Tags),
			TXIndepHash = ar_util:decode(TXIndepHashEncoded),
			case lists:member(TXIndepHash, CurrentBHL) of
				false ->
					{404, #{}, <<"Not Found.">>, Req};
				true ->
					CurrentHeight = ar_node:get_height(whereis(http_entrypoint_node)),
					[TXHeight] = proplists:get_all_values(<<"block_height">>, Tags),
					%% First confirmation is when the TX is in the latest block.
					NumberOfConfirmations = CurrentHeight - TXHeight + 1,
					Status = Tags ++ [{<<"number_of_confirmations">>, NumberOfConfirmations}],
					{200, #{}, ar_serialize:jsonify({Status}), Req}
			end;
		{response, {Status, Headers, Body}} ->
			{Status, Headers, Body, Req}
	end;


% @doc Return a transaction specified via the the transaction id (hash)
%% GET request to endpoint /tx/{hash}
handle(<<"GET">>, [<<"tx">>, Hash], Req) ->
	case get_tx_filename(Hash) of
		{ok, Filename} ->
			{200, #{}, sendfile(Filename), Req};
		{response, {Status, Headers, Body}} ->
			{Status, Headers, Body, Req}
	end;

%% @doc Return the transaction IDs of all txs where the tags in post match the given set of key value pairs.
%% POST request to endpoint /arql with body of request being a logical expression valid in ar_parser.
%%
%% Example logical expression.
%%	{
%%		op:		{ and | or | equals }
%%		expr1:	{ string | logical expression }
%%		expr2:	{ string | logical expression }
%%	}
%%
handle(<<"POST">>, [<<"arql">>], Req) ->
	ar_semaphore:acquire(arql_semaphore(Req), 5000),
	case read_complete_body(Req) of
		{ok, QueryJson, ReadReq} ->
			case ar_serialize:json_struct_to_query(QueryJson) of
				{ok, Query} ->
					TXIDs = ar_util:unique(ar_parser:eval(Query)),
					SortedTXIDs = ar_tx_search:sort_txids(TXIDs),
					Body = ar_serialize:jsonify(ar_serialize:hash_list_to_json_struct(SortedTXIDs)),
					{200, #{}, Body, ReadReq};
				{error, _} ->
					{400, #{}, <<"Invalid ARQL query.">>, ReadReq}
			end;
		{error, body_size_too_large, TooLargeReq} ->
			reply_with_413(TooLargeReq)
	end;

%% @doc Return the data field of the transaction specified via the transaction ID (hash) served as HTML.
%% GET request to endpoint /tx/{hash}/data.html
handle(<<"GET">>, [<<"tx">>, Hash, << "data.", _/binary >>], Req) ->
	case hash_to_filename(tx, Hash) of
		{error, invalid} ->
			{400, #{}, <<"Invalid hash.">>, Req};
		{error, _, unavailable} ->
			{404, #{}, sendfile("data/not_found.html"), Req};
		{ok, Filename} ->
			{ok, T} = ar_storage:read_tx_file(Filename),
			{
				200,
				#{
					<<"content-type">> => proplists:get_value(
						<<"Content-Type">>, T#tx.tags, "text/html"
					)
				},
				T#tx.data,
				Req
			}
	end;

%% @doc Share a new block to a peer.
%% POST request to endpoint /block with the body of the request being a JSON encoded block
%% as specified in ar_serialize.
handle(<<"POST">>, [<<"block">>], Req) ->
	post_block(request, Req);

%% @doc Generate a wallet and receive a secret key identifying it.
%% Requires internal_api_secret startup option to be set.
%% WARNING: only use it if you really really know what you are doing.
handle(<<"POST">>, [<<"wallet">>], Req) ->
	case check_internal_api_secret(Req) of
		pass ->
			WalletAccessCode = ar_util:encode(crypto:strong_rand_bytes(32)),
			{{_, PubKey}, _} = ar_wallet:new_keyfile(WalletAccessCode),
			ResponseProps = [
				{<<"wallet_address">>, ar_util:encode(ar_wallet:to_address(PubKey))},
				{<<"wallet_access_code">>, WalletAccessCode}
			],
			{200, #{}, ar_serialize:jsonify({ResponseProps}), Req};
		{reject, {Status, Headers, Body}} ->
			{Status, Headers, Body, Req}
	end;

%% @doc Share a new transaction with a peer.
%% POST request to endpoint /tx with the body of the request being a JSON encoded tx as
%% specified in ar_serialize.
handle(<<"POST">>, [<<"tx">>], Req) ->
	case read_complete_body(Req) of
		{ok, TXJSON, ReadReq} ->
			TX = ar_serialize:json_struct_to_tx(TXJSON),
			case handle_post_tx(TX) of
				ok ->
					{200, #{}, <<"OK">>, ReadReq};
				{error_response, {Status, Headers, Body}} ->
					{Status, Headers, Body, ReadReq}
			end;
		{error, body_size_too_large, TooLargeReq} ->
			reply_with_413(TooLargeReq)
	end;

%% @doc Sign and send a tx to the network.
%% Fetches the wallet by the provided key generated via POST /wallet.
%% Requires internal_api_secret startup option to be set.
%% WARNING: only use it if you really really know what you are doing.
handle(<<"POST">>, [<<"unsigned_tx">>], Req) ->
	case check_internal_api_secret(Req) of
		pass ->
			case read_complete_body(Req) of
				{ok, Body, ReadReq} ->
					{UnsignedTXProps} = ar_serialize:dejsonify(Body),
					WalletAccessCode = proplists:get_value(<<"wallet_access_code">>, UnsignedTXProps),
					%% ar_serialize:json_struct_to_tx/1 requires all properties to be there,
					%% so we're adding id, owner and signature with bogus values. These
					%% will later be overwritten in ar_tx:sign/2
					FullTxProps = lists:append(
						proplists:delete(<<"wallet_access_code">>, UnsignedTXProps),
						[
							{<<"id">>, ar_util:encode(<<"id placeholder">>)},
							{<<"owner">>, ar_util:encode(<<"owner placeholder">>)},
							{<<"signature">>, ar_util:encode(<<"signature placeholder">>)}
						]
					),
					KeyPair = ar_wallet:load_keyfile(ar_wallet:wallet_filepath(WalletAccessCode)),
					UnsignedTX = ar_serialize:json_struct_to_tx({FullTxProps}),
					SignedTX = ar_tx:sign(UnsignedTX, KeyPair),
					case handle_post_tx(SignedTX) of
						ok ->
							{200, #{}, ar_serialize:jsonify({[{<<"id">>, ar_util:encode(SignedTX#tx.id)}]}), ReadReq};
						{error_response, {Status, Headers, Body}} ->
							{Status, Headers, Body, ReadReq}
					end;
				{error, body_size_too_large, TooLargeReq} ->
					reply_with_413(TooLargeReq)
			end;
		{reject, {Status, Headers, Body}} ->
			{Status, Headers, Body, Req}
	end;

%% @doc Return the list of peers held by the node.
%% GET request to endpoint /peers
handle(<<"GET">>, [<<"peers">>], Req) ->
	{200, #{},
		ar_serialize:jsonify(
			[
				list_to_binary(ar_util:format_peer(P))
			||
				P <- ar_bridge:get_remote_peers(whereis(http_bridge_node)),
				P /= arweave_peer(Req)
			]
		),
	Req};

%% @doc Return the estimated transaction fee.
%% The endpoint is pessimistic, it computes the difficulty of the new block
%% as if it has been just mined and uses the smaller of the two difficulties
%% to estimate the price.
%% GET request to endpoint /price/{bytes}
handle(<<"GET">>, [<<"price">>, SizeInBytesBinary], Req) ->
	{200, #{}, integer_to_binary(estimate_tx_price(SizeInBytesBinary, no_wallet)), Req};

%% @doc Return the estimated reward cost of transactions with a data body size of 'bytes'.
%% The endpoint is pessimistic, it computes the difficulty of the new block
%% as if it has been just mined and uses the smaller of the two difficulties
%% to estimate the price.
%% GET request to endpoint /price/{bytes}/{address}
handle(<<"GET">>, [<<"price">>, SizeInBytesBinary, Addr], Req) ->
	case ar_util:safe_decode(Addr) of
		{error, invalid} ->
			{400, #{}, <<"Invalid address.">>, Req};
		{ok, AddrOK} ->
			{200, #{}, integer_to_binary(estimate_tx_price(SizeInBytesBinary, AddrOK)), Req}
	end;

%% @doc Return the current hash list held by the node.
%% GET request to endpoint /hash_list
handle(<<"GET">>, [<<"hash_list">>], Req) ->
	ok = ar_semaphore:acquire(hash_list_semaphore, infinity),
	HashList = ar_node:get_hash_list(whereis(http_entrypoint_node)),
	{200, #{},
		ar_serialize:jsonify(
			ar_serialize:hash_list_to_json_struct(HashList)
		),
	Req};

%% @doc Return the current wallet list held by the node.
%% GET request to endpoint /wallet_list
handle(<<"GET">>, [<<"wallet_list">>], Req) ->
	Node = whereis(http_entrypoint_node),
	WalletList = ar_node:get_wallet_list(Node),
	{200, #{},
		ar_serialize:jsonify(
			ar_serialize:wallet_list_to_json_struct(WalletList)
		),
	Req};

%% @doc Share your nodes IP with another peer.
%% POST request to endpoint /peers with the body of the request being your
%% nodes network information JSON encoded as specified in ar_serialize.
% NOTE: Consider returning remaining timeout on a failed request
handle(<<"POST">>, [<<"peers">>], Req) ->
	case read_complete_body(Req) of
		{ok, BlockJSON, ReadReq} ->
			case ar_serialize:dejsonify(BlockJSON) of
				{Struct} ->
					{<<"network">>, NetworkName} = lists:keyfind(<<"network">>, 1, Struct),
					case (NetworkName == <<?NETWORK_NAME>>) of
						false ->
							{400, #{}, <<"Wrong network.">>, ReadReq};
						true ->
							Peer = arweave_peer(ReadReq),
							case ar_meta_db:get({peer, Peer}) of
								not_found ->
									ar_bridge:add_remote_peer(whereis(http_bridge_node), Peer);
								X -> X
							end,
							{200, #{}, [], ReadReq}
					end;
				_ -> {400, #{}, "Wrong network", ReadReq}
			end;
		{error, body_size_too_large, TooLargeReq} ->
			reply_with_413(TooLargeReq)
	end;
%% @doc Return the balance of the wallet specified via wallet_address.
%% GET request to endpoint /wallet/{wallet_address}/balance
handle(<<"GET">>, [<<"wallet">>, Addr, <<"balance">>], Req) ->
	case ar_util:safe_decode(Addr) of
		{error, invalid} ->
			{400, #{}, <<"Invalid address.">>, Req};
		{ok, AddrOK} ->
			%% ar_node:get_balance/2 can time out which is not suitable for this
			%% use-case. It would be better if it never timed out so that Cowboy
			%% would handle the timeout instead.
			case ar_node:get_balance(whereis(http_entrypoint_node), AddrOK) of
				node_unavailable ->
					{503, #{}, <<"Internal timeout.">>, Req};
				Balance ->
					{200, #{}, integer_to_binary(Balance), Req}
			end
	end;

%% @doc Return the last transaction ID (hash) for the wallet specified via wallet_address.
%% GET request to endpoint /wallet/{wallet_address}/last_tx
handle(<<"GET">>, [<<"wallet">>, Addr, <<"last_tx">>], Req) ->
	case ar_util:safe_decode(Addr) of
		{error, invalid} ->
			{400, #{}, <<"Invalid address.">>, Req};
		{ok, AddrOK} ->
			{200, #{},
				ar_util:encode(
					?OK(ar_node:get_last_tx(whereis(http_entrypoint_node), AddrOK))
				),
			Req}
	end;

%% @doc Return a block anchor to use for building transactions.
handle(<<"GET">>, [<<"tx_anchor">>], Req) ->
	case ar_node:get_hash_list(whereis(http_entrypoint_node)) of
		[] ->
			{400, #{}, <<"The node has not joined the network yet.">>, Req};
		BHL when is_list(BHL) ->
			{
				200,
				#{},
				ar_util:encode(
					lists:nth(min(length(BHL), (?MAX_TX_ANCHOR_DEPTH)) div 2 + 1, BHL)
				),
				Req
			}
	end;

%% @doc Return transaction identifiers (hashes) for the wallet specified via wallet_address.
%% GET request to endpoint /wallet/{wallet_address}/txs
handle(<<"GET">>, [<<"wallet">>, Addr, <<"txs">>], Req) ->
	ar_semaphore:acquire(arql_semaphore(Req), 5000),
	{Status, Headers, Body} = handle_get_wallet_txs(Addr, none),
	{Status, Headers, Body, Req};

%% @doc Return transaction identifiers (hashes) starting from the earliest_tx for the wallet
%% specified via wallet_address.
%% GET request to endpoint /wallet/{wallet_address}/txs/{earliest_tx}
handle(<<"GET">>, [<<"wallet">>, Addr, <<"txs">>, EarliestTX], Req) ->
	ar_semaphore:acquire(arql_semaphore(Req), 5000),
	{Status, Headers, Body} = handle_get_wallet_txs(Addr, ar_util:decode(EarliestTX)),
	{Status, Headers, Body, Req};

%% @doc Return identifiers (hashes) of transfer transactions depositing to the given wallet_address.
%% GET request to endpoint /wallet/{wallet_address}/deposits
handle(<<"GET">>, [<<"wallet">>, Addr, <<"deposits">>], Req) ->
	ar_semaphore:acquire(arql_semaphore(Req), 5000),
	TXIDs = lists:reverse(
		lists:map(fun ar_util:encode/1, ar_tx_search:get_entries(<<"to">>, Addr))
	),
	{200, #{}, ar_serialize:jsonify(TXIDs), Req};

%% @doc Return identifiers (hashes) of transfer transactions depositing to the given wallet_address
%% starting from the earliest_deposit.
%% GET request to endpoint /wallet/{wallet_address}/deposits/{earliest_deposit}
handle(<<"GET">>, [<<"wallet">>, Addr, <<"deposits">>, EarliestDeposit], Req) ->
	ar_semaphore:acquire(arql_semaphore(Req), 5000),
	TXIDs = lists:reverse(
		lists:map(fun ar_util:encode/1, ar_tx_search:get_entries(<<"to">>, Addr))
	),
	{Before, After} = lists:splitwith(fun(T) -> T /= EarliestDeposit end, TXIDs),
	FilteredTXs = case After of
		[] ->
			Before;
		[EarliestDeposit | _] ->
			Before ++ [EarliestDeposit]
	end,
	{200, #{}, ar_serialize:jsonify(FilteredTXs), Req};

%% @doc Return the encrypted blockshadow corresponding to the indep_hash.
%% GET request to endpoint /block/hash/{indep_hash}/encrypted
%handle(<<"GET">>, [<<"block">>, <<"hash">>, Hash, <<"encrypted">>], _Req) ->
	%ar:d({resp_block_hash, Hash}),
	%ar:report_console([{resp_getting_block_by_hash, Hash}, {path, ar_http_iface_middleware:split_path(cowboy_req:path(Req))}]),
	%case ar_key_db:get(ar_util:decode(Hash)) of
	%	[{Key, Nonce}] ->
	%		return_encrypted_block(
	%			ar_node:get_block(
	%				whereis(http_entrypoint_node),
	%				ar_util:decode(Hash)
	%			),
	%			Key,
	%			Nonce
	%		);
	%	not_found ->
	%		ar:d(not_found_block),
	%		return_encrypted_block(unavailable)
	% end;

%% @doc Return the blockshadow corresponding to the indep_hash / height.
%% GET request to endpoint /block/{height|hash}/{indep_hash|height}
handle(<<"GET">>, [<<"block">>, Type, ID], Req) ->
	Filename =
		case Type of
			<<"hash">> ->
				case hash_to_filename(block, ID) of
					{error, invalid}        -> invalid_hash;
					{error, _, unavailable} -> unavailable;
					{ok, Fn}                -> Fn
				end;
			<<"height">> ->
				try binary_to_integer(ID) of
					Int ->
						ar_storage:lookup_block_filename(Int)
				catch _:_ ->
					invalid_height
				end
		end,
	case Filename of
		invalid_hash ->
			{400, #{}, <<"Invalid height.">>, Req};
		invalid_height ->
			{400, #{}, <<"Invalid hash.">>, Req};
		unavailable ->
			{404, #{}, <<"Block not found.">>, Req};
		_  ->
			case {ar_meta_db:get(api_compat), cowboy_req:header(<<"x-block-format">>, Req, <<"2">>)} of
				{false, <<"1">>} ->
					{426, #{}, <<"Client version incompatible.">>, Req};
				{_, <<"1">>} ->
					% Supprt for legacy nodes (pre-1.5).
					BHL = ar_node:get_hash_list(whereis(http_entrypoint_node)),
					try ar_storage:read_block_file(Filename, BHL) of
						B ->
							{JSONStruct} =
								ar_serialize:block_to_json_struct(
									B#block {
										txs =
											[
												if is_binary(TX) -> TX; true -> TX#tx.id end
											||
												TX <- B#block.txs
											]
									}
								),
							{200, #{},
								ar_serialize:jsonify(
									{
										[
											{
												<<"hash_list">>,
												ar_serialize:hash_list_to_json_struct(B#block.hash_list)
											}
										|
											JSONStruct
										]
									}
								),
							Req}
					catch error:cannot_generate_block_hash_list ->
						{404, #{}, <<"Requested block not found on block hash list.">>, Req}
					end;
				{_, _} ->
					{200, #{}, sendfile(Filename), Req}
			end
	end;

%% @doc Return block or block field.
handle(<<"GET">>, [<<"block">>, Type, IDBin, Field], Req) ->
	case validate_get_block_type_id(Type, IDBin) of
		{error, {Status, Headers, Body}} ->
			{Status, Headers, Body, Req};
		{ok, ID} ->
			process_request(get_block, [Type, ID, Field], Req)
	end;

%% @doc Return the current block.
%% GET request to endpoint /current_block
%% GET request to endpoint /block/current
handle(<<"GET">>, [<<"block">>, <<"current">>], Req) ->
	case ar_node:get_hash_list(whereis(http_entrypoint_node)) of
		[] -> {404, #{}, <<"Block not found.">>, Req};
		[IndepHash|_] ->
			handle(<<"GET">>, [<<"block">>, <<"hash">>, ar_util:encode(IndepHash)], Req)
	end;

%% DEPRECATED (12/07/2018)
handle(<<"GET">>, [<<"current_block">>], Req) ->
	handle(<<"GET">>, [<<"block">>, <<"current">>], Req);

%% @doc Return a list of known services.
%% GET request to endpoint /services
handle(<<"GET">>, [<<"services">>], Req) ->
	{200, #{},
		ar_serialize:jsonify(
			{
				[
					{
						[
							{"name", Name},
							{"host", ar_util:format_peer(Host)},
							{"expires", Expires}
						]
					}
				||
					#service {
						name = Name,
						host = Host,
						expires = Expires
					} <- ar_services:get(whereis(http_service_node))
				]
			}
		),
	Req};

%% @doc Return a given field of the transaction specified by the transaction ID (hash).
%% GET request to endpoint /tx/{hash}/{field}
%%
%% {field} := { id | last_tx | owner | tags | target | quantity | data | signature | reward }
%%
handle(<<"GET">>, [<<"tx">>, Hash, Field], Req) ->
	case hash_to_filename(tx, Hash) of
		{error, invalid} ->
			{400, #{}, <<"Invalid hash.">>, Req};
		{error, ID, unavailable} ->
			case is_a_pending_tx(ID) of
				true ->
					{202, #{}, <<"Pending">>, Req};
				false ->
					{404, #{}, <<"Not Found.">>, Req}
			end;
		{ok, Filename} ->
			case Field of
				<<"tags">> ->
					{ok, TX} = ar_storage:read_tx_file(Filename),
					{200, #{}, ar_serialize:jsonify(
						lists:map(
							fun({Name, Value}) ->
								{
									[
										{name, ar_util:encode(Name)},
										{value, ar_util:encode(Value)}
									]
								}
							end,
							TX#tx.tags
						)
					), Req};
				_ ->
					{ok, JSONBlock} = file:read_file(Filename),
					{TXJSON} = ar_serialize:dejsonify(JSONBlock),
					Res = val_for_key(Field, TXJSON),
					{200, #{}, Res, Req}
			end
	end;

%% @doc Share the location of a given service with a peer.
%% POST request to endpoint /services where the body of the request is a JSON encoded serivce as
%% specified in ar_serialize.
handle(<<"POST">>, [<<"services">>], Req) ->
	case read_complete_body(Req) of
		{ok, BodyBin, ReadReq} ->
			{ServicesJSON} = ar_serialize:jsonify(BodyBin),
			ar_services:add(
				whereis(http_services_node),
				lists:map(
					fun({Vals}) ->
						{<<"name">>, Name} = lists:keyfind(<<"name">>, 1, Vals),
						{<<"host">>, Host} = lists:keyfind(<<"host">>, 1, Vals),
						{<<"expires">>, Expiry} = lists:keyfind(<<"expires">>, 1, Vals),
						#service { name = Name, host = Host, expires = Expiry }
					end,
					ServicesJSON
				)
			),
			{200, #{}, "OK", ReadReq};
		{error, body_size_too_large, TooLargeReq} ->
			reply_with_413(TooLargeReq)
	end;

%% @doc Return the current block hieght, or 500
handle(Method, [<<"height">>], Req)
		when (Method == <<"GET">>) or (Method == <<"HEAD">>) ->
	case ar_node:get_height(whereis(http_entrypoint_node)) of
		-1 -> {503, #{}, <<"Node has not joined the network yet.">>, Req};
		H -> {200, #{}, integer_to_binary(H), Req}
	end;

%% @doc If we are given a hash with no specifier (block, tx, etc), assume that
%% the user is requesting the data from the TX associated with that hash.
%% Optionally allow a file extension.
handle(<<"GET">>, [<<Hash:43/binary, MaybeExt/binary>>], Req) ->
	handle(<<"GET">>, [<<"tx">>, Hash, <<"data.", MaybeExt/binary>>], Req);

%% @doc Catch case for requests made to unknown endpoints.
%% Returns error code 400 - Request type not found.
handle(_, _, Req) ->
	not_found(Req).

% Cowlib does not yet support status code 208 properly.
% See https://github.com/ninenines/cowlib/pull/79
handle208(208) -> <<"208 Already Reported">>;
handle208(Status) -> Status.

arweave_peer(Req) ->
	{{IpV4_1, IpV4_2, IpV4_3, IpV4_4}, _TcpPeerPort} = cowboy_req:peer(Req),
	ArweavePeerPort =
		case cowboy_req:header(<<"x-p2p-port">>, Req) of
			undefined -> ?DEFAULT_HTTP_IFACE_PORT;
			Binary -> binary_to_integer(Binary)
		end,
	{IpV4_1, IpV4_2, IpV4_3, IpV4_4, ArweavePeerPort}.

sendfile(Filename) ->
	{sendfile, 0, filelib:file_size(Filename), Filename}.

read_complete_body(#{'_ar_http_iface_middleware_pid' := Pid} = Req) ->
	Pid ! {read_complete_body, self(), Req},
	receive
		{read_complete_body, Term} -> Term
	end.

arql_semaphore(#{'_ar_http_iface_middleware_arql_semaphore' := Name}) ->
	Name.

do_read_complete_body(Req) ->
	do_read_complete_body(Req, <<>>).

do_read_complete_body(Req, Acc) ->
	{MoreOrOk, Data, ReadReq} = cowboy_req:read_body(Req),
	NewAcc = <<Acc/binary, Data/binary>>,
	do_read_complete_body(MoreOrOk, NewAcc, ReadReq).

do_read_complete_body(_, Data, Req) when byte_size(Data) > ?MAX_BODY_SIZE ->
	{error, body_size_too_large, Req};
do_read_complete_body(more, Data, Req) ->
	do_read_complete_body(Req, Data);
do_read_complete_body(ok, Data, Req) ->
	{ok, Data, Req}.

not_found(Req) ->
	{400, #{}, <<"Request type not found.">>, Req}.

reply_with_413(Req) ->
	{413, #{}, <<"Payload too large">>, Req}.

%% @doc Get the filename for an encoded TX id.
get_tx_filename(Hash) ->
	case hash_to_filename(tx, Hash) of
		{error, invalid} ->
			{response, {400, #{}, <<"Invalid hash.">>}};
		{error, ID, unavailable} ->
			case is_a_pending_tx(ID) of
				true ->
					{response, {202, #{}, <<"Pending">>}};
				false ->
					case ar_tx_db:get_error_codes(ID) of
						{ok, ErrorCodes} ->
							ErrorBody = list_to_binary(lists:join(" ", ErrorCodes)),
							{response, {410, #{}, ErrorBody}};
						not_found ->
							{response, {404, #{}, <<"Not Found.">>}}
					end
			end;
		{ok, Filename} ->
			{ok, Filename}
	end.

estimate_tx_price(SizeInBytesBinary, WalletAddr) ->
	SizeInBytes = binary_to_integer(SizeInBytesBinary),
	Node = whereis(http_entrypoint_node),
	Height = ar_node:get_height(Node),
	CurrentDiff = ar_node:get_diff(Node),
	NextDiff = ar_node:get_current_diff(Node),
	Timestamp  = os:system_time(seconds),
	CurrentDiffPrice = estimate_tx_price(SizeInBytes, CurrentDiff, Height, WalletAddr, Timestamp),
	NextDiffPrice = estimate_tx_price(SizeInBytes, NextDiff, Height + 1, WalletAddr, Timestamp),
	max(NextDiffPrice, CurrentDiffPrice).

estimate_tx_price(SizeInBytes, Diff, Height, WalletAddr, Timestamp) ->
	case WalletAddr of
		no_wallet ->
			ar_tx:calculate_min_tx_cost(
				SizeInBytes,
				Diff,
				Height,
				Timestamp
			);
		Addr ->
			ar_tx:calculate_min_tx_cost(
				SizeInBytes,
				Diff,
				Height,
				ar_node:get_wallet_list(whereis(http_entrypoint_node)),
				Addr,
				Timestamp
			)
	end.

handle_get_wallet_txs(Addr, EarliestTXID) ->
	case ar_util:safe_decode(Addr) of
		{error, invalid} ->
			{400, #{}, <<"Invalid address.">>};
		{ok, _} ->
			TXIDs = ar_tx_search:get_entries(<<"from">>, Addr),
			SortedTXIDs = ar_tx_search:sort_txids(TXIDs),
			RecentTXIDs = get_wallet_txs(EarliestTXID, SortedTXIDs),
			EncodedTXIDs = lists:map(fun ar_util:encode/1, RecentTXIDs),
			{200, #{}, ar_serialize:jsonify(EncodedTXIDs)}
	end.

%% @doc Returns a list of all TX IDs starting with the last one to EarliestTXID (inclusive)
%% for the same wallet.
get_wallet_txs(EarliestTXID, TXIDs) ->
	lists:reverse(get_wallet_txs(EarliestTXID, TXIDs, [])).

get_wallet_txs(_EarliestTXID, [], Acc) ->
	Acc;
get_wallet_txs(EarliestTXID, [TXID | TXIDs], Acc) ->
	case TXID of
		EarliestTXID ->
			[EarliestTXID | Acc];
		_ ->
			get_wallet_txs(EarliestTXID, TXIDs, [TXID | Acc])
	end.

handle_post_tx(TX) ->
	Node = whereis(http_entrypoint_node),
	MempoolTXs = ar_node:get_all_known_txs(Node),
	Height = ar_node:get_height(Node),
	case verify_mempool_txs_size(MempoolTXs, TX, Height) of
		invalid ->
			handle_post_tx_no_mempool_space_response();
		valid ->
			handle_post_tx(Node, TX, Height, MempoolTXs)
	end.

handle_post_tx(Node, TX, Height, MempoolTXs) ->
	%% Check whether the TX is already ignored, ignore it if it is not
	%% (and then pass to processing steps).
	case ar_bridge:is_id_ignored(TX#tx.id) of
		true ->
			{error_response, {208, #{}, <<"Transaction already processed.">>}};
		false ->
			ar_bridge:ignore_id(TX#tx.id),
			handle_post_tx2(Node, TX, Height, MempoolTXs)
	end.

handle_post_tx2(Node, TX, Height, MempoolTXs) ->
	WalletList = ar_node:get_wallet_list(Node),
	OwnerAddr = ar_wallet:to_address(TX#tx.owner),
	case lists:keyfind(OwnerAddr, 1, WalletList) of
		{_, Balance, _} when (TX#tx.reward + TX#tx.quantity) > Balance ->
			ar:info([
				submitted_txs_exceed_balance,
				{owner, ar_util:encode(OwnerAddr)},
				{balance, Balance},
				{tx_cost, TX#tx.reward + TX#tx.quantity}
			]),
			handle_post_tx_exceed_balance_response();
		_ ->
			handle_post_tx(Node, TX, Height, MempoolTXs, WalletList)
	end.

handle_post_tx(Node, TX, Height, MempoolTXs, WalletList) ->
	Diff = ar_node:get_current_diff(Node),
	{ok, BlockTXPairs} = ar_node:get_block_txs_pairs(Node),
	case ar_tx_replay_pool:verify_tx(
		TX,
		Diff,
		Height,
		BlockTXPairs,
		MempoolTXs,
		WalletList
	) of
		{invalid, tx_verification_failed} ->
			handle_post_tx_verification_response();
		{invalid, last_tx_in_mempool} ->
			handle_post_tx_last_tx_in_mempool_response();
		{invalid, invalid_last_tx} ->
			handle_post_tx_verification_response();
		{invalid, tx_bad_anchor} ->
			handle_post_tx_bad_anchor_response();
		{invalid, tx_already_in_weave} ->
			handle_post_tx_already_in_weave_response();
		{invalid, tx_already_in_mempool} ->
			handle_post_tx_already_in_mempool_response();
		{valid, _, _} ->
			handle_post_tx_accepted(TX)
	end.

verify_mempool_txs_size(MempoolTXs, TX, Height) ->
	case ar_fork:height_1_8() of
		H when Height >= H ->
			verify_mempool_txs_size(MempoolTXs, TX);
		_ ->
			valid
	end.

verify_mempool_txs_size(MempoolTXs, TX) ->
	TotalSize = lists:foldl(
		fun(MempoolTX, Sum) ->
			Sum + byte_size(MempoolTX#tx.data)
		end,
		0,
		MempoolTXs
	),
	case byte_size(TX#tx.data) + TotalSize of
		Size when Size > ?TOTAL_WAITING_TXS_DATA_SIZE_LIMIT ->
			invalid;
		_ ->
			valid
	end.

handle_post_tx_accepted(TX) ->
	ar:info([
		ar_http_iface_handler,
		accepted_tx,
		{id, ar_util:encode(TX#tx.id)}
	]),
	ar_bridge:add_tx(whereis(http_bridge_node), TX),
	ok.

handle_post_tx_exceed_balance_response() ->
	{error_response, {400, #{}, <<"Waiting TXs exceed balance for wallet.">>}}.

handle_post_tx_verification_response() ->
	{error_response, {400, #{}, <<"Transaction verification failed.">>}}.

handle_post_tx_last_tx_in_mempool_response() ->
	{error_response, {400, #{}, <<"Invalid anchor (last_tx from mempool).">>}}.

handle_post_tx_no_mempool_space_response() ->
	ar:err([ar_http_iface_middleware, rejected_transaction, {reason, mempool_is_full}]),
	{error_response, {400, #{}, <<"Mempool is full.">>}}.

handle_post_tx_bad_anchor_response() ->
	{error_response, {400, #{}, <<"Invalid anchor (last_tx).">>}}.

handle_post_tx_already_in_weave_response() ->
	{error_response, {400, #{}, <<"Transaction is already on the weave.">>}}.

handle_post_tx_already_in_mempool_response() ->
	{error_response, {400, #{}, <<"Transaction is already in the mempool.">>}}.

check_internal_api_secret(Req) ->
	Reject = fun(Msg) ->
		log_internal_api_reject(Msg, Req),
		timer:sleep(rand:uniform(1000) + 1000), % Reduce efficiency of timing attacks by sleeping randomly between 1-2s.
		{reject, {421, #{}, <<"Internal API disabled or invalid internal API secret in request.">>}}
	end,
	case {ar_meta_db:get(internal_api_secret), cowboy_req:header(<<"x-internal-api-secret">>, Req)} of
		{not_set, _} ->
			Reject("Request to disabled internal API");
		{_Secret, _Secret} when is_binary(_Secret) ->
			pass;
		_ ->
			Reject("Invalid secret for internal API request")
	end.

log_internal_api_reject(Msg, Req) ->
	spawn(fun() ->
		Path = ar_http_iface_server:split_path(cowboy_req:path(Req)),
		{IpAddr, _Port} = cowboy_req:peer(Req),
		BinIpAddr = list_to_binary(inet:ntoa(IpAddr)),
		ar:warn("~s: IP address: ~s Path: ~p", [Msg, BinIpAddr, Path])
	end).

%% @doc Convert a blocks field with the given label into a string
block_field_to_string(<<"nonce">>, Res) -> Res;
block_field_to_string(<<"previous_block">>, Res) -> Res;
block_field_to_string(<<"timestamp">>, Res) -> integer_to_list(Res);
block_field_to_string(<<"last_retarget">>, Res) -> integer_to_list(Res);
block_field_to_string(<<"diff">>, Res) -> integer_to_list(Res);
block_field_to_string(<<"height">>, Res) -> integer_to_list(Res);
block_field_to_string(<<"hash">>, Res) -> Res;
block_field_to_string(<<"indep_hash">>, Res) -> Res;
block_field_to_string(<<"txs">>, Res) -> ar_serialize:jsonify(Res);
block_field_to_string(<<"hash_list">>, Res) -> ar_serialize:jsonify(Res);
block_field_to_string(<<"wallet_list">>, Res) -> ar_serialize:jsonify(Res);
block_field_to_string(<<"reward_addr">>, Res) -> Res.

%% @doc checks if hash is valid & if so returns filename.
hash_to_filename(Type, Hash) ->
	case ar_util:safe_decode(Hash) of
		{error, invalid} ->
			{error, invalid};
		{ok, ID} ->
			{Mod, Fun} = type_to_mf({Type, lookup_filename}),
			F = apply(Mod, Fun, [ID]),
			case F of
				unavailable ->
					{error, ID, unavailable};
				Filename ->
					{ok, Filename}
			end
	end.

%% @doc Return true if ID is a pending tx.
is_a_pending_tx(ID) ->
	lists:member(ID, ar_node:get_pending_txs(whereis(http_entrypoint_node))).

%% @doc Given a request, returns a blockshadow.
request_to_struct_with_blockshadow(Req) ->
	case read_complete_body(Req) of
		{ok, BlockJSON, ReadReq} ->
			try
				{Struct} = ar_serialize:dejsonify(BlockJSON),
				JSONB = val_for_key(<<"new_block">>, Struct),
				BShadow = ar_serialize:json_struct_to_block(JSONB),
				{ok, {Struct, BShadow}, ReadReq}
			catch
				Exception:Reason ->
					{error, {Exception, Reason}, ReadReq}
			end;
		{error, body_size_too_large, TooLargeReq} ->
			{error, body_size_too_large, TooLargeReq}
	end.

%% @doc Generate and return an informative JSON object regarding
%% the state of the node.
return_info(Req) ->
	{Time, Current} =
		timer:tc(fun() -> ar_node:get_current_block_hash(whereis(http_entrypoint_node)) end),
	{Time2, Height} =
		timer:tc(fun() -> ar_node:get_height(whereis(http_entrypoint_node)) end),
	{200, #{},
		ar_serialize:jsonify(
			{
				[
					{network, list_to_binary(?NETWORK_NAME)},
					{version, ?CLIENT_VERSION},
					{release, ?RELEASE_NUMBER},
					{height,
						case Height of
							not_joined -> -1;
							H -> H
						end
					},
					{current,
						case is_atom(Current) of
							true -> atom_to_binary(Current, utf8);
							false -> ar_util:encode(Current)
						end
					},
					{blocks, ar_storage:blocks_on_disk()},
					{peers, length(ar_bridge:get_remote_peers(whereis(http_bridge_node)))},
					{queue_length,
						element(
							2,
							erlang:process_info(whereis(http_entrypoint_node), message_queue_len)
						)
					},
					{node_state_latency, (Time + Time2) div 2}
				]
			}
		),
	Req}.

%% @doc converts a tuple of atoms to a {Module, Function} tuple.
type_to_mf({tx, lookup_filename}) ->
	{ar_storage, lookup_tx_filename};
type_to_mf({block, lookup_filename}) ->
	{ar_storage, lookup_block_filename}.

%% @doc Convenience function for lists:keyfind(Key, 1, List).
%% returns Value not {Key, Value}.
val_for_key(K, L) ->
	{K, V} = lists:keyfind(K, 1, L),
	V.

%% @doc Handle multiple steps of POST /block. First argument is a subcommand,
%% second the argument for that subcommand.
post_block(request, Req) ->
	OrigPeer = arweave_peer(Req),
	case ar_blacklist_middleware:is_peer_banned(OrigPeer) of
		not_banned ->
			post_block(read_blockshadow, OrigPeer, Req);
		banned ->
			{403, #{}, <<"IP address blocked due to previous request.">>, Req}
	end.
post_block(read_blockshadow, OrigPeer, Req) ->
	% Convert request to struct and block shadow.
	case request_to_struct_with_blockshadow(Req) of
		{error, {_, _}, ReadReq} ->
			{400, #{}, <<"Invalid block.">>, ReadReq};
		{error, body_size_too_large, TooLargeReq} ->
			reply_with_413(TooLargeReq);
		{ok, {ReqStruct, BShadow}, ReadReq} ->
			post_block(check_data_segment_processed, {ReqStruct, BShadow, OrigPeer}, ReadReq)
	end;
post_block(check_data_segment_processed, {ReqStruct, BShadow, OrigPeer}, Req) ->
	% Check if block is already known.
	case lists:keyfind(<<"block_data_segment">>, 1, ReqStruct) of
		{_, BDSEncoded} ->
			BDS = ar_util:decode(BDSEncoded),
			case ar_bridge:is_id_ignored(BDS) of
				true ->
					{208, #{}, <<"Block Data Segment already processed.">>, Req};
				false ->
					post_block(check_indep_hash_processed, {ReqStruct, BShadow, OrigPeer, BDS}, Req)
			end;
		false ->
			post_block_reject_warn(BShadow, block_data_segment_missing, OrigPeer),
			{400, #{}, <<"block_data_segment missing.">>, Req}
	end;
post_block(check_indep_hash_processed, {ReqStruct, BShadow, OrigPeer, BDS}, Req) ->
	case ar_bridge:is_id_ignored(BShadow#block.indep_hash) of
		true ->
			{208, <<"Block already processed.">>, Req};
		false ->
			ar_bridge:ignore_id(BShadow#block.indep_hash),
			post_block(check_is_joined, {ReqStruct, BShadow, OrigPeer, BDS}, Req)
	end;
post_block(check_is_joined, {ReqStruct, BShadow, OrigPeer, BDS}, Req) ->
	% Check if node is joined.
	case ar_node:is_joined(whereis(http_entrypoint_node)) of
		false ->
			{503, #{}, <<"Not joined.">>, Req};
		true ->
			post_block(check_height, {ReqStruct, BShadow, OrigPeer, BDS}, Req)
	end;
post_block(check_height, {ReqStruct, BShadow, OrigPeer, BDS}, Req) ->
	CurrentHeight = ar_node:get_height(whereis(http_entrypoint_node)),
	case BShadow#block.height of
		H when H < CurrentHeight - ?STORE_BLOCKS_BEHIND_CURRENT ->
			{400, #{}, <<"Height is too far behind">>, Req};
		H when H > CurrentHeight + ?STORE_BLOCKS_BEHIND_CURRENT ->
			{400, #{}, <<"Height is too far ahead">>, Req};
		_ ->
			post_block(check_difficulty, {ReqStruct, BShadow, OrigPeer, BDS}, Req)
	end;
%% The min difficulty check is filtering out blocks from smaller networks, e.g.
%% testnets. Therefor, we don't want to log when this check or any check above
%% rejects the block because there are potentially a lot of rejections.
post_block(check_difficulty, {ReqStruct, BShadow, OrigPeer, BDS}, Req) ->
	case BShadow#block.diff >= ar_mine:min_difficulty(BShadow#block.height) of
		true ->
			post_block(check_pow, {ReqStruct, BShadow, OrigPeer, BDS}, Req);
		_ ->
			{400, #{}, <<"Difficulty too low">>, Req}
	end;
%% Note! Checking PoW should be as cheap as possible. All slow steps should
%% be after the PoW check to reduce the possibility of doing a DOS attack on
%% the network.
post_block(check_pow, {ReqStruct, BShadow, OrigPeer, BDS}, Req) ->
	case ar_mine:validate(BDS, BShadow#block.nonce, BShadow#block.diff, BShadow#block.height) of
		{invalid, _} ->
			post_block_reject_warn(BShadow, check_pow, OrigPeer),
			ar_blacklist_middleware:ban_peer(OrigPeer, ?BAD_POW_BAN_TIME),
			{400, #{}, <<"Invalid Block Proof of Work">>, Req};
		{valid, _} ->
			ar_bridge:ignore_id(BDS),
			post_block(check_timestamp, {ReqStruct, BShadow, OrigPeer, BDS}, Req)
	end;
post_block(check_timestamp, {ReqStruct, BShadow, OrigPeer, BDS}, Req) ->
	%% Verify the timestamp of the block shadow.
	case ar_block:verify_timestamp(BShadow) of
		false ->
			post_block_reject_warn(
				BShadow,
				check_timestamp,
				OrigPeer,
				[{block_time, BShadow#block.timestamp},
				 {current_time, os:system_time(seconds)}]
			),
			{400, #{}, <<"Invalid timestamp.">>, Req};
		true ->
			post_block(post_block, {ReqStruct, BShadow, OrigPeer, BDS}, Req)
	end;
post_block(post_block, {ReqStruct, BShadow, OrigPeer, BDS}, Req) ->
	%% The ar_block:generate_block_from_shadow/2 call is potentially slow. Since
	%% all validation steps already passed, we can do the rest in a separate
	spawn(fun() ->
		RecallSize = val_for_key(<<"recall_size">>, ReqStruct),
		B = ar_block:generate_block_from_shadow(BShadow, RecallSize),
		RecallIndepHash = ar_util:decode(val_for_key(<<"recall_block">>, ReqStruct)),
		Key = ar_util:decode(val_for_key(<<"key">>, ReqStruct)),
		Nonce = ar_util:decode(val_for_key(<<"nonce">>, ReqStruct)),
		ar:info([{
			sending_external_block_to_bridge,
			ar_util:encode(B#block.indep_hash)
		}]),
		ar:info([
			ar_http_iface_handler,
			accepted_block,
			{indep_hash, ar_util:encode(B#block.indep_hash)}
		]),
		ar_bridge:add_block(
			whereis(http_bridge_node),
			OrigPeer,
			B,
			BDS,
			{RecallIndepHash, RecallSize, Key, Nonce}
		)
	end),
	{200, #{}, <<"OK">>, Req}.

post_block_reject_warn(BShadow, Step, Peer) ->
	ar:warn([
		{post_block_rejected, ar_util:encode(BShadow#block.indep_hash)},
		Step,
		{peer, ar_util:format_peer(Peer)}
	]).

post_block_reject_warn(BShadow, Step, Peer, Params) ->
	ar:warn([
		{post_block_rejected, ar_util:encode(BShadow#block.indep_hash)},
		{Step, Params},
		{peer, ar_util:format_peer(Peer)}
	]).

%% @doc Return the block hash list associated with a block.
process_request(get_block, [Type, ID, <<"hash_list">>], Req) ->
	CurrentBHL = ar_node:get_hash_list(whereis(http_entrypoint_node)),
	case is_block_known(Type, ID, CurrentBHL) of
		true ->
			Hash =
				case Type of
					<<"height">> ->
						B =
							ar_node:get_block(whereis(http_entrypoint_node),
							ID,
							CurrentBHL),
						B#block.indep_hash;
					<<"hash">> -> ID
				end,
			BlockBHL = ar_block:generate_hash_list_for_block(Hash, CurrentBHL),
			{200, #{},
				ar_serialize:jsonify(
					ar_serialize:hash_list_to_json_struct(
						BlockBHL
					)
				),
			Req};
		false ->
			{404, #{}, <<"Block not found.">>, Req}
	end;
%% @doc Return the wallet list associated with a block (as referenced by hash
%% or height).
process_request(get_block, [Type, ID, <<"wallet_list">>], Req) ->
	HTTPEntryPointPid = whereis(http_entrypoint_node),
	CurrentBHL = ar_node:get_hash_list(HTTPEntryPointPid),
	case is_block_known(Type, ID, CurrentBHL) of
		false -> {404, #{}, <<"Block not found.">>, Req};
		true ->
			B = find_block(Type, ID, CurrentBHL),
			case ?IS_BLOCK(B) of
				true ->
					{200, #{},
						ar_serialize:jsonify(
							ar_serialize:wallet_list_to_json_struct(
								B#block.wallet_list
							)
						),
					Req};
				false ->
					{404, #{}, <<"Block not found.">>, Req}
			end
	end;
%% @doc Return a given field for the the blockshadow corresponding to the block height, 'height'.
%% GET request to endpoint /block/hash/{hash|height}/{field}
%%
%% {field} := { nonce | previous_block | timestamp | last_retarget | diff | height | hash | indep_hash
%%				txs | hash_list | wallet_list | reward_addr | tags | reward_pool }
%%
process_request(get_block, [Type, ID, Field], Req) ->
	CurrentBHL = ar_node:get_hash_list(whereis(http_entrypoint_node)),
	case ar_meta_db:get(subfield_queries) of
		true ->
			case find_block(Type, ID, CurrentBHL) of
				unavailable ->
					{404, #{}, <<"Not Found.">>, Req};
				B ->
					{BLOCKJSON} = ar_serialize:block_to_json_struct(B),
					{_, Res} = lists:keyfind(list_to_existing_atom(binary_to_list(Field)), 1, BLOCKJSON),
					Result = block_field_to_string(Field, Res),
					{200, #{}, Result, Req}
			end;
		_ ->
			{421, #{}, <<"Subfield block querying is disabled on this node.">>, Req}
	end.

validate_get_block_type_id(<<"height">>, ID) ->
	try binary_to_integer(ID) of
		Int -> {ok, Int}
	catch _:_ ->
		{error, {400, #{}, <<"Invalid height.">>}}
	end;
validate_get_block_type_id(<<"hash">>, ID) ->
	case ar_util:safe_decode(ID) of
		{ok, Hash} -> {ok, Hash};
		invalid    -> {error, {400, #{}, <<"Invalid hash.">>}}
	end.

%% @doc Take a block type specifier, an ID, and a BHL, returning whether the
%% given block is part of the BHL.
is_block_known(<<"height">>, RawHeight, BHL) when is_binary(RawHeight) ->
	is_block_known(<<"height">>, binary_to_integer(RawHeight), BHL);
is_block_known(<<"height">>, Height, BHL) ->
	Height < length(BHL);
is_block_known(<<"hash">>, ID, BHL) ->
	lists:member(ID, BHL).

%% @doc Find a block, given a type and a specifier.
find_block(<<"height">>, RawHeight, BHL) ->
	ar_node:get_block(
		whereis(http_entrypoint_node),
		binary_to_integer(RawHeight),
		BHL
	);
find_block(<<"hash">>, ID, BHL) ->
	ar_storage:read_block(ID, BHL).
