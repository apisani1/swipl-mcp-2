/*  Author:        Jan Wielemaker
    E-mail:        jan@swi-prolog.org
    WWW:           http://www.swi-prolog.org
    Copyright (c)  2026, SWI-Prolog Solutions b.v.
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(mcp_server,
          [ mcp_tool/3,                 % +Name, +Description, +InputSchema
            mcp_resource/3,             % +URI, +Description, +Options
            mcp_resource_template/3,    % +UriTemplate, +Description, +Options
            mcp_prompt/3,               % +Name, +Description, +Arguments
            mcp_server_info/1,          % +Dict

            mcp_register_tool/4,        % +Module, +Name, +Description, +Schema
            mcp_register_resource/4,    % +Module, +URI, +Description, +Options
            mcp_register_resource_template/4, % +Module, +Tmpl, +Desc, +Opts
            mcp_register_prompt/4,      % +Module, +Name, +Description, +Args

            mcp_dispatch/3,             % :Stream, +Request, +Options
            mcp_protocol_version/1,     % -Atom
            mcp_supported_protocol_versions/1, % -List

            mcp_notify/2,               % +Method, +Params
            mcp_subscription_add/4,     % +Key, +Id, +Filter, +Sink
            mcp_subscription_remove/1,  % +Key
            mcp_subscription_close/1,   % +Key
            mcp_current_subscription/4, % ?Key, ?Id, ?Filter, ?Sink
            mcp_server_capabilities/1,  % -Dict
            mcp_get_server_info/1,      % -Dict
            mcp_current_prompt/4,
            mcp_current_resource/4,     % ?Module, ?URI, ?Description, ?Options
            mcp_current_tool/4,         % ?Module, ?URI, ?Description, ?Options
            mcp_current_resource_template/4, % ?Module, ?URI, ?Description, ?Options
            mcp_current_tool_raw_schema/3    % ?Module, ?Name, ?Schema
          ]).
:- use_module(library(json_schema), [json_compile_schema/3]).
:- use_module(library(debug), [debug/3]).
:- use_module(library(error), [must_be/2]).
:- use_module(library(json_rpc_common), [json_rpc_send/3]).
:- use_module(library(lists), [member/2]).
:- use_module(library(apply), [include/3]).
:- use_module(library(option), [option/2]).

/** <module> MCP server framework

This  module  exposes  the  directives  used  to  declare  MCP  _tools_,
_resources_ and _prompts_, plus the dispatcher   invoked  by a transport
(stdio or HTTP). Transports are  provided   by  sibling  modules such as
library(mcp/stdio).

Tools, resources and prompts are registered into a global registry keyed
by the declaring module. The handler predicate   is  then called in that
module when a request arrives.

The dispatcher implements the *stateless*  2026-07-28 revision of MCP.
There is no `initialize` handshake: every request carries its protocol
version and the client capabilities in `params._meta`, every result
carries `resultType` and the server identity in `result._meta`, and
long-lived change notifications are only delivered on streams opened
with `subscriptions/listen`.

@see https://modelcontextprotocol.io/specification/2026-07-28
*/

:- multifile
    mcp_server_info_hook/1,             % Hook to override serverInfo
    mcp_cache_hint/4.                   % +Method, +Params, -TtlMs, -Scope
:- meta_predicate
    mcp_tool(2, +, +),
    mcp_resource_template(3, +, +),
    mcp_prompt(2, +, +).


%!  mcp_protocol_version(-Version) is det.
%
%   The latest (preferred) MCP protocol revision implemented here.

mcp_protocol_version('2026-07-28').

%!  mcp_supported_protocol_versions(-Versions:list(atom)) is det.
%
%   All protocol revisions this server accepts in the
%   `io.modelcontextprotocol/protocolVersion` request metadata.
%   Reported by `server/discover` and in UnsupportedProtocolVersion
%   errors.

mcp_supported_protocol_versions(['2026-07-28']).


                /*******************************
                *           REGISTRIES         *
                *******************************/

:- dynamic
    tool/4,                             % Module, Name, Description, CompiledSchema
    tool_raw_schema/3,                  % Module, Name, RawSchema
    resource/4,                         % Module, URI, Description, Options
    resource_template/4,                % Module, UriTemplate, Description, Options
    prompt/4,                           % Module, Name, Description, Arguments
    server_info/1,                      % Dict
    subscription/4.                     % Key, Id, Filter, Sink

:- multifile                            % several server modules contribute
    tool/4,
    tool_raw_schema/3,
    resource/4,
    resource_template/4,
    prompt/4.


%!  mcp_current_prompt(?Module, ?Name, ?Description, ?Arguments) is
%!                     nondet.
%
%   True when this is a prompt registered using mcp_prompt/3 in Module.

mcp_current_prompt(Module, Name, Description, Arguments) :-
    prompt(Module, Name, Description, Arguments).

%!  mcp_current_resource(?Module, ?URI, ?Description, ?Options) is
%!                       nondet.

mcp_current_resource(Module, URI, Description, Options) :-
    resource(Module, URI, Description, Options).

%!  mcp_current_resource_template(?Module, ?URI, ?Description, ?Options)
%!                                is nondet.

mcp_current_resource_template(Module, URI, Description, Options) :-
    resource_template(Module, URI, Description, Options).

%!  mcp_current_tool(?Module, ?URI, ?Description, ?Options) is nondet.

mcp_current_tool(Module, URI, Description, Options) :-
    tool(Module, URI, Description, Options).

%!  mcp_current_tool_raw_schema(?Module, ?Name, ?Schema) is nondet.

mcp_current_tool_raw_schema(Module, Name, Schema) :-
    tool_raw_schema(Module, Name, Schema).

                /*******************************
                *           DIRECTIVES         *
                *******************************/

%!  mcp_tool(:Name, +Description, +InputSchema) is det.
%
%   Declare an MCP _tool_ called  Name.   Description  is a short string
%   shown to the client. InputSchema is a   JSON Schema (as a dict) that
%   describes the parameters object passed to the handler.
%
%   This is normally used as a directive:
%
%       :- mcp_tool(name, "desc", #{...}).
%
%   The directive is processed by term_expansion/2  below and turns into
%   clauses for the dynamic  predicates   tool/4  and tool_raw_schema/3.
%   Reloading the source  file  therefore   replaces  the  registrations
%   cleanly (no duplicate accumulation, no stale   entries  if a tool is
%   removed).
%
%   The declaring module must provide a handler predicate Name/2:
%
%       handler(+Args:dict, -Content) is det.
%
%   The Content may be:
%
%     - A string or atom -- wrapped as a text content item
%     - A dict matching the MCP content schema
%     - A list of such dicts (multiple content items)
%
%   See library(mcp/content) for helpers that build content items.
%
%   For ad-hoc runtime registration use mcp_register_tool/4 directly.

mcp_tool(Module:Name, Description, Schema) :-
    mcp_register_tool(Module, Name, Description, Schema).

mcp_register_tool(Module, Name, Description, Schema) :-
    must_be_atom(Name),
    must_be_string(Description),
    json_compile_schema(Schema, Compiled, []),
    retractall(tool(Module, Name, _, _)),
    retractall(tool_raw_schema(Module, Name, _)),
    assertz(tool(Module, Name, Description, Compiled)),
    assertz(tool_raw_schema(Module, Name, Schema)),
    debug(mcp(register), 'Registered tool ~w:~w', [Module, Name]).

%!  mcp_resource(+URI, +Description, +Options) is det.
%
%   Declare a static MCP _resource_ identified by URI.  Options:
%
%     - name(+String)
%       Display name; defaults to URI.
%     - mime_type(+String)
%       Content MIME type; defaults to "text/plain".
%     - handler(:Goal)
%       Predicate Goal(+URI, -Content) returning content.
%       Defaults to a predicate of name `resource` taking URI and
%       Content in the declaring module.

mcp_resource(URI, Description, Options) :-
    mcp_register_resource(user, URI, Description, Options).

mcp_register_resource(Module, URI, Description, Options) :-
    must_be_string(URI),
    must_be_string(Description),
    retractall(resource(Module, URI, _, _)),
    assertz(resource(Module, URI, Description, Options)),
    debug(mcp(register), 'Registered resource ~w', [URI]).

%!  mcp_resource_template(+UriTemplate, +Description, +Options) is det.
%
%   Declare an RFC-6570 URI template describing   a  class of resources.
%   Options as for mcp_resource/3 plus:
%
%     - name(+String)
%     - mime_type(+String)
%     - handler(:Goal)
%       Predicate Goal(+URI, +Bindings:dict, -Content).
%
%   Normally    `:-    mcp_resource_template(Template,Desc,Opts)`     is
%   term-expanded.

mcp_resource_template(Module:Template, Description, Options) :-
    mcp_register_resource_template(Module, Template, Description, Options).

mcp_register_resource_template(Module, Template, Description, Options) :-
    must_be_string(Template),
    must_be_string(Description),
    retractall(resource_template(Module, Template, _, _)),
    assertz(resource_template(Module, Template, Description, Options)),
    debug(mcp(register), 'Registered resource template ~w', [Template]).

%!  mcp_prompt(:Name, +Description, +Arguments) is det.
%
%   Declare an MCP _prompt_ template.  Arguments is a list of
%   `#{name:String, description:String, required:Bool}` dicts.
%   The declaring module must provide a handler Name/2:
%
%       handler(+Args:dict, -Messages:list) is det.
%
%   where Messages is a list of `#{role:R, content:C}` dicts (see
%   library(mcp/content)).
%
%   Normally `:- mcp_prompt(Name,Desc,Args)` is term-expanded.


mcp_prompt(Module:Name, Description, Arguments) :-
    mcp_register_prompt(Module, Name, Description, Arguments).

mcp_register_prompt(Module, Name, Description, Arguments) :-
    must_be_atom(Name),
    must_be_string(Description),
    must_be(list, Arguments),
    retractall(prompt(Module, Name, _, _)),
    assertz(prompt(Module, Name, Description, Arguments)),
    debug(mcp(register), 'Registered prompt ~w:~w', [Module, Name]).

%!  mcp_server_info(+Dict) is det.
%
%   Declare  the  server  identity  (an  MCP  `Implementation`  object).
%   Dict should contain at least `name`   and  `version`, and may hold
%   `title`, `description`, `websiteUrl` and  `icons`. It is reported in
%   the `io.modelcontextprotocol/serverInfo` key  of   the  `_meta` of
%   every result.  An optional `instructions` key is not part of the
%   identity; it is returned as the `instructions` field of the
%   `server/discover` result.
%
%   Normally `:- mcp_server_info(Dict)` is term-expanded.

mcp_server_info(Dict) :-
    must_be(dict, Dict),
    retractall(server_info(_)),
    assertz(server_info(Dict)).


                /*******************************
                *            DISPATCH          *
                *******************************/

:- use_module(library(mcp/lifecycle)).
:- use_module(library(mcp/tools)).
:- use_module(library(mcp/resources)).
:- use_module(library(mcp/prompts)).

:- meta_predicate
    mcp_dispatch(:, +, +).

%!  mcp_dispatch(:Stream, +Message, +Options) is det.
%
%   Handle a single decoded JSON-RPC Message from  the MCP client. Replies
%   are written to Stream as a single line of JSON. Notifications and
%   (illegal) client responses produce no reply.
%
%   JSON-RPC batches (arrays) were removed  from   MCP  in  2025-06-18 and
%   are answered with an `Invalid Request` error.
%
%   Options:
%
%     - subscription(-Listen)
%       Used by transports that serve `subscriptions/listen` on a
%       dedicated stream (Streamable HTTP).  If the message is a valid
%       `subscriptions/listen` request, nothing is written to Stream
%       and Listen is unified with listen(Id, AckFilter): the
%       transport must open the stream, send the acknowledgement and
%       register the subscription using mcp_subscription_add/4.
%       Without this option the subscription is registered on Stream
%       itself (stdio).
%
%   Other options are passed to json_write_dict/3.

mcp_dispatch(_:Stream, Message, Options) :-
    catch(mcp_handle(Message, Stream, Options),
          Error,
          mcp_protocol_error(Error, Message, Stream, Options)).

mcp_handle(Message, Stream, Options) :-
    message_kind(Message, Kind),
    debug(mcp(rpc), 'message ~p: ~p', [Kind, Message]),
    mcp_handle(Kind, Message, Stream, Options).

mcp_handle(request(Method, Id, Params), _Message, Stream, Options) :-
    mcp_request(Method, Id, Params, Stream, Options).
mcp_handle(notification(Method, Params), _Message, Stream, Options) :-
    mcp_notification(Method, Params, Stream, Options).
mcp_handle(response, _Message, _Stream, _Options) :-
    debug(mcp(rpc), 'Ignored JSON-RPC response from client', []).
mcp_handle(invalid(Id, Why), _Message, Stream, Options) :-
    rpc_error(Stream, Id, -32600, "Invalid Request", Why, Options).

%!  message_kind(+Message, -Kind) is det.
%
%   Classify a decoded JSON-RPC message.

message_kind(Message, Kind) :-
    is_dict(Message),
    !,
    (   get_dict(jsonrpc, Message, "2.0")
    ->  message_kind_(Message, Kind)
    ;   message_id(Message, Id),
        Kind = invalid(Id, "jsonrpc must be \"2.0\"")
    ).
message_kind(Message, invalid(null, "JSON-RPC batching is not supported")) :-
    is_list(Message),
    !.
message_kind(_, invalid(null, "Message must be a JSON object")).

message_kind_(Message, Kind) :-
    get_dict(method, Message, MethodS),
    !,
    (   \+ string(MethodS)
    ->  message_id(Message, Id),
        Kind = invalid(Id, "method must be a string")
    ;   atom_string(Method, MethodS),
        Params = Message.get(params, #{}),
        (   get_dict(id, Message, Id0)
        ->  (   valid_id(Id0)
            ->  Kind = request(Method, Id0, Params)
            ;   Kind = invalid(null, "id must be a string or integer")
            )
        ;   Kind = notification(Method, Params)
        )
    ).
message_kind_(Message, response) :-
    get_dict(id, Message, _),
    (   get_dict(result, Message, _)
    ;   get_dict(error, Message, _)
    ),
    !.
message_kind_(Message, invalid(Id, "Missing method")) :-
    message_id(Message, Id).

valid_id(Id) :- string(Id), !.
valid_id(Id) :- integer(Id).

message_id(Message, Id) :-
    is_dict(Message),
    get_dict(id, Message, Id),
    valid_id(Id),
    !.
message_id(_, null).

%!  mcp_request(+Method, +Id, +Params, +Stream, +Options) is det.

mcp_request(initialize, _Id, Params, _Stream, _Options) :-
    !,
    %  Legacy (2025-11-25 and earlier) clients open with `initialize`.
    %  The spec asks modern-only servers to name the versions they
    %  support in the error, as this may be the only diagnostic a
    %  legacy client can show.
    mcp_supported_protocol_versions(Versions),
    (   is_dict(Params),
        get_dict(protocolVersion, Params, Requested),
        string(Requested)
    ->  true
    ;   Requested = ""
    ),
    atomic_list_concat(Versions, ', ', VersionsText),
    format(string(Msg),
           "Unsupported protocol version: this server implements the \c
            stateless MCP revision(s) ~w, which have no initialize \c
            handshake", [VersionsText]),
    throw(mcp_error(-32022, Msg,
                    #{supported:Versions, requested:Requested})).
mcp_request(Method, Id, Params, Stream, Options) :-
    (   is_dict(Params)
    ->  true
    ;   throw(mcp_error(-32602, "Invalid params", "params must be an object"))
    ),
    mcp_lifecycle:check_request_meta(Params),
    debug(mcp(rpc), 'request ~w id=~p params=~p', [Method, Id, Params]),
    mcp_method(Method, Id, Params, Stream, Options).

%!  mcp_method(+Method, +Id, +Params, +Stream, +Options) is det.

mcp_method('subscriptions/listen', Id, Params, Stream, Options) :-
    !,
    listen(Id, Params, Stream, Options).
mcp_method(Method, Id, Params, Stream, Options) :-
    known_method(Method),
    !,
    (   method_result(Method, Params, Result)
    ->  rpc_result(Stream, Id, Result, Options)
    ;   throw(mcp_error(-32603, "Internal error", "Request handler failed"))
    ).
mcp_method(Method, _Id, _Params, _Stream, _Options) :-
    throw(mcp_error(-32601, "Method not found", Method)).

known_method('server/discover').
known_method('tools/list').
known_method('tools/call').
known_method('resources/list').
known_method('resources/templates/list').
known_method('resources/read').
known_method('prompts/list').
known_method('prompts/get').

%!  method_result(+Method, +Params, -Result) is semidet.

method_result('server/discover', Params, Result) :-
    mcp_lifecycle:discover(Result0),
    cacheable('server/discover', Params, Result0, Result).
method_result('tools/list', Params, Result) :-
    single_page(Params),
    mcp_tools:list_tools(Tools),
    cacheable('tools/list', Params, #{tools:Tools}, Result).
method_result('tools/call', Params, Result) :-
    mcp_tools:call_tool(Params, Result).
method_result('resources/list', Params, Result) :-
    single_page(Params),
    mcp_resources:list_resources(Resources),
    cacheable('resources/list', Params, #{resources:Resources}, Result).
method_result('resources/templates/list', Params, Result) :-
    single_page(Params),
    mcp_resources:list_resource_templates(Templates),
    cacheable('resources/templates/list', Params,
              #{resourceTemplates:Templates}, Result).
method_result('resources/read', Params, Result) :-
    mcp_resources:read_resource(Params, Result0),
    cacheable('resources/read', Params, Result0, Result).
method_result('prompts/list', Params, Result) :-
    single_page(Params),
    mcp_prompts:list_prompts(Prompts),
    cacheable('prompts/list', Params, #{prompts:Prompts}, Result).
method_result('prompts/get', Params, Result) :-
    mcp_prompts:get_prompt(Params, Result).

%!  single_page(+Params) is det.
%
%   All list results are returned as a single page, so we never hand
%   out a `nextCursor`.  Any cursor sent by the client is therefore
%   invalid.

single_page(Params) :-
    (   get_dict(cursor, Params, Cursor),
        Cursor \== null
    ->  throw(mcp_error(-32602, "Invalid cursor", #{cursor:Cursor}))
    ;   true
    ).

%!  cacheable(+Method, +Params, +Result0, -Result) is det.
%
%   Add the `ttlMs` and `cacheScope` caching hints that are mandatory
%   on the results of `server/discover`, the `*/list` methods and
%   `resources/read`.  The values come from the multifile hook
%   mcp_cache_hint/4; the default is to consider the result
%   immediately stale (`ttlMs: 0`, which matches the behaviour of
%   pre-2026 clients) and `public`, except for `resources/read` which
%   defaults to `private`.

cacheable(Method, Params, Result0, Result) :-
    cache_hint(Method, Params, TtlMs, Scope),
    must_be(nonneg, TtlMs),
    must_be(oneof([public,private]), Scope),
    atom_string(Scope, ScopeS),
    Result = Result0.put(#{ttlMs:TtlMs, cacheScope:ScopeS}).

cache_hint(Method, Params, TtlMs, Scope) :-
    mcp_cache_hint(Method, Params, TtlMs, Scope),
    !.
cache_hint('resources/read', _, 0, private) :- !.
cache_hint(_, _, 0, public).

%!  mcp_notification(+Method, +Params, +Stream, +Options) is det.
%
%   Handle a client notification.  The only client notification in
%   the 2026-07-28 core protocol is `notifications/cancelled`.  Our
%   transports process requests synchronously, so the only request
%   that can still be in flight when a cancellation arrives is a
%   `subscriptions/listen` stream on the same (stdio) channel.

mcp_notification('notifications/cancelled', Params, Stream, _Options) :-
    !,
    (   is_dict(Params),
        get_dict(requestId, Params, Id)
    ->  debug(mcp(subscription), 'Client cancelled request ~p', [Id]),
        actual_stream(Stream, S),
        mcp_subscription_remove(sub(S, Id))
    ;   true
    ).
mcp_notification(Method, _Params, _Stream, _Options) :-
    debug(mcp(rpc), 'Unknown notification ~w (ignored)', [Method]).


%!  mcp_protocol_error(+Error, +Message, +Stream, +Options) is det.
%
%   Map an exception raised while handling Message to a JSON-RPC error
%   response.  Handlers raise mcp_error(Code, Message, Data) for
%   protocol-level errors; anything else is an internal error.
%   Notifications never get a reply.

mcp_protocol_error(Error, Message, Stream, Options) :-
    (   is_request(Message, Id)
    ->  error_object(Error, Code, Msg, Data),
        rpc_error(Stream, Id, Code, Msg, Data, Options)
    ;   debug(mcp(rpc), 'Error handling notification: ~p', [Error])
    ).

is_request(Message, Id) :-
    is_dict(Message),
    get_dict(method, Message, _),
    get_dict(id, Message, Id),
    valid_id(Id).

error_object(mcp_error(Code, Msg, Data), Code, Msg, Data) :-
    integer(Code),
    !.
error_object(Error, -32603, "Internal error", Data) :-
    message_to_string(Error, Data).


                /*******************************
                *        SUBSCRIPTIONS         *
                *******************************/

%!  listen(+Id, +Params, +Stream, +Options) is det.
%
%   Handle `subscriptions/listen`.  The request stays open for the
%   lifetime of the subscription; it is answered only if the server
%   tears the subscription down using mcp_subscription_close/1.

listen(Id, Params, Stream, Options) :-
    (   get_dict(notifications, Params, Filter),
        is_dict(Filter)
    ->  true
    ;   throw(mcp_error(-32602, "Invalid params",
                        "subscriptions/listen requires a notifications object"))
    ),
    honored_filter(Filter, Ack),
    (   option(subscription(Listen), Options)
    ->  Listen = listen(Id, Ack)
    ;   actual_stream(Stream, S),
        Key = sub(S, Id),
        mcp_subscription_remove(Key),
        rpc_reply(S, #{ jsonrpc:"2.0",
                        method:"notifications/subscriptions/acknowledged",
                        params: #{ '_meta':
                                     #{ 'io.modelcontextprotocol/subscriptionId':Id },
                                   notifications:Ack
                                 }
                      }, Options),
        mcp_subscription_add(Key, Id, Ack, stream(S))
    ).

%!  honored_filter(+Requested:dict, -Honored:dict) is det.
%
%   The subset of the requested notification filter that this server
%   supports, as derived from mcp_server_capabilities/1.  This is
%   reported in `notifications/subscriptions/acknowledged`.

honored_filter(Requested, Honored) :-
    mcp_server_capabilities(Caps),
    dict_pairs(Requested, _, Pairs0),
    include(honored(Caps), Pairs0, Pairs),
    dict_pairs(Honored, _, Pairs).

honored(Caps, toolsListChanged-true) :-
    true == Caps.get(tools).get(listChanged).
honored(Caps, promptsListChanged-true) :-
    true == Caps.get(prompts).get(listChanged).
honored(Caps, resourcesListChanged-true) :-
    true == Caps.get(resources).get(listChanged).
honored(Caps, resourceSubscriptions-URIs) :-
    true == Caps.get(resources).get(subscribe),
    is_list(URIs).

%!  mcp_subscription_add(+Key, +Id, +Filter:dict, +Sink) is det.
%
%   Register an active `subscriptions/listen` stream.  Key uniquely
%   identifies the subscription within this process, Id is the
%   JSON-RPC id of the `subscriptions/listen` request (the
%   `io.modelcontextprotocol/subscriptionId`), Filter is the
%   acknowledged notification filter and Sink is one of
%
%     - stream(+Stream)
%       Write notifications as JSON lines to Stream (stdio).
%     - queue(+Queue)
%       Send notification(Dict) terms to the message queue Queue.  The
%       transport writes them to its stream (Streamable HTTP).
%
%   Notifications must only be delivered after the subscription has
%   been acknowledged.

mcp_subscription_add(Key, Id, Filter, Sink) :-
    with_mutex(mcp_subscriptions,
               ( retractall(subscription(Key, _, _, _)),
                 assertz(subscription(Key, Id, Filter, Sink))
               )),
    debug(mcp(subscription), 'Subscription ~p (id ~p): ~p',
          [Key, Id, Filter]).

%!  mcp_subscription_remove(+Key) is det.
%
%   Forget about a subscription.  Succeeds if there is no such
%   subscription.

mcp_subscription_remove(Key) :-
    with_mutex(mcp_subscriptions,
               retractall(subscription(Key, _, _, _))).

%!  mcp_subscription_close(+Key) is det.
%
%   End a subscription on the server's initiative (e.g., at shutdown).
%   This sends the (empty) response to the `subscriptions/listen`
%   request, which tells the client the subscription ended gracefully,
%   and removes the subscription.  Key may be partially instantiated
%   to close multiple subscriptions.

mcp_subscription_close(Key) :-
    forall(retract_subscription(Key, Id, Sink),
           close_subscription(Sink, Id)).

retract_subscription(Key, Id, Sink) :-
    with_mutex(mcp_subscriptions,
               findall(Key-Id-Sink,
                       retract(subscription(Key, Id, _, Sink)),
                       Subs)),
    member(Key-Id-Sink, Subs).

close_subscription(Sink, Id) :-
    complete_result(#{ '_meta':
                         #{ 'io.modelcontextprotocol/subscriptionId':Id }
                     }, Result),
    Message = #{jsonrpc:"2.0", id:Id, result:Result},
    (   Sink = stream(Stream)
    ->  catch(rpc_reply(Stream, Message, []), E, print_message(silent, E))
    ;   Sink = queue(Queue)
    ->  catch(thread_send_message(Queue, close(Message)), E,
              print_message(silent, E))
    ;   true
    ).

%!  mcp_current_subscription(?Key, ?Id, ?Filter, ?Sink) is nondet.

mcp_current_subscription(Key, Id, Filter, Sink) :-
    subscription(Key, Id, Filter, Sink).

%!  mcp_server_capabilities(-Capabilities:dict) is det.
%
%   The `ServerCapabilities` advertised by `server/discover`.  This is
%   also what decides which subscription notification types are
%   honoured.

mcp_server_capabilities(#{ tools:     #{ listChanged: true },
                           resources: #{},
                           prompts:   #{}
                         }).


                /*******************************
                *            REPLY             *
                *******************************/

%!  rpc_result(+Stream, +Id, +Result0, +Options) is det.
%
%   Send a successful response.  Adds the mandatory `resultType`
%   (`"complete"` unless the handler set it) and our identity as
%   `_meta["io.modelcontextprotocol/serverInfo"]`.

rpc_result(Stream, Id, Result0, Options) :-
    complete_result(Result0, Result),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id, result:Result}, Options).

complete_result(Result0, Result) :-
    (   get_dict(resultType, Result0, _)
    ->  Result1 = Result0
    ;   put_dict(resultType, Result0, "complete", Result1)
    ),
    server_implementation(Info),
    Meta0 = Result1.get('_meta', #{}),
    put_dict('io.modelcontextprotocol/serverInfo', Meta0, Info, Meta),
    put_dict('_meta', Result1, Meta, Result).

%!  rpc_error(+Stream, +Id, +Code, +Message, ?Data, +Options) is det.

rpc_error(Stream, Id, Code, Message, Data, Options) :-
    (   var(Data)
    ->  Error = #{code:Code, message:Message}
    ;   Error = #{code:Code, message:Message, data:Data}
    ),
    rpc_reply(Stream, #{jsonrpc:"2.0", id:Id, error:Error}, Options).

%!  rpc_reply(+Stream, +Dict, +Options) is det.
%
%   Write Dict as a single-line JSON message terminated by a newline,
%   as required by the MCP stdio transport.  Writes are serialized, so
%   notifications for subscriptions may be emitted from other threads.

rpc_reply(Stream, Dict, Options) :-
    json_options(Options, JSONOptions),
    with_mutex(mcp_rpc_output,
               ( json_rpc_send(Stream, Dict, [width(0)|JSONOptions]),
                 nl(Stream),
                 flush_output(Stream)
               )).

json_options([], []).
json_options([H|T0], T) :-
    mcp_option(H),
    !,
    json_options(T0, T).
json_options([H|T0], [H|T]) :-
    json_options(T0, T).

mcp_option(subscription(_)).

%!  actual_stream(+StreamOrAlias, -Stream) is det.
%
%   Resolve `current_output` and other aliases to the stream handle,
%   so a subscription keeps writing to the stream it was opened on.

actual_stream(current_output, S) :-
    !,
    current_output(S).
actual_stream(Alias, S) :-
    atom(Alias),
    stream_property(S, alias(Alias)),
    !.
actual_stream(S, S).

                /*******************************
                *           UTILITIES          *
                *******************************/

:- use_module(library(error), [must_be/2]).

must_be_atom(X)   :- must_be(atom, X).
must_be_string(X) :- (string(X) ; atom(X)), !.
must_be_string(X) :- must_be(string, X).


                /*******************************
                *        SERVER INFO ACCESS    *
                *******************************/

%!  mcp_get_server_info(-Info:dict) is det.

mcp_get_server_info(Info) :-
    server_info(Info), !.
mcp_get_server_info(Info) :-
    mcp_server_info_hook(Info), !.
mcp_get_server_info(#{name:"swipl-mcp", version:"0.1.0"}).


                /*******************************
                *        TERM EXPANSION        *
                *******************************/

%   Expand registration directives into clauses of the dynamic
%   registry predicates (tool/4, tool_raw_schema/3, resource/4,
%   resource_template/4, prompt/4).  This way the clauses are
%   attached to the source file: on reload SWI replaces them
%   atomically, instead of the runtime-assertz pattern which has
%   to retract by (Module, Name) and silently leaves stale entries
%   if a tool is removed or renamed.

:- multifile
    system:term_expansion/2.

system:term_expansion((:- mcp_tool(Name, Description, Schema)),
                      [ mcp_server:tool(M, Name, Description, Compiled),
                        mcp_server:tool_raw_schema(M, Name, Schema)
                      ]) :-
    \+ current_prolog_flag(xref, true),
    prolog_load_context(module, M),
    must_be_atom(Name),
    must_be_string(Description),
    json_compile_schema(Schema, Compiled, []).

system:term_expansion((:- mcp_resource(URI, Description, Options)),
                      mcp_server:resource(M, URI, Description, Options)) :-
    \+ current_prolog_flag(xref, true),
    prolog_load_context(module, M),
    must_be_string(URI),
    must_be_string(Description).

system:term_expansion((:- mcp_resource_template(Template, Description, Options)),
                      mcp_server:resource_template(M, Template, Description, Options)) :-
    \+ current_prolog_flag(xref, true),
    prolog_load_context(module, M),
    must_be_string(Template),
    must_be_string(Description).

system:term_expansion((:- mcp_prompt(Name, Description, Arguments)),
                      mcp_server:prompt(M, Name, Description, Arguments)) :-
    \+ current_prolog_flag(xref, true),
    prolog_load_context(module, M),
    must_be_atom(Name),
    must_be_string(Description),
    must_be(list, Arguments).

system:term_expansion((:- mcp_server_info(Dict)),
                      [ mcp_server:server_info(Dict)
                      ]) :-
    \+ current_prolog_flag(xref, true),
    must_be(dict, Dict).

                /*******************************
                *    SERVER-INITIATED EVENTS   *
                *******************************/

%!  mcp_notify(+Method, +Params:dict) is det.
%
%   Send a change notification to every  client that opted in to it on
%   a `subscriptions/listen` stream. Method is one of
%
%     - `notifications/tools/list_changed`
%     - `notifications/prompts/list_changed`
%     - `notifications/resources/list_changed`
%     - `notifications/resources/updated` (Params holds `uri`)
%
%   Since MCP 2026-07-28 the server MUST NOT send notification types the
%   client did not request, so other methods (and notifications nobody
%   subscribed to) are silently dropped.  Each delivered notification
%   carries the `io.modelcontextprotocol/subscriptionId` of the
%   subscription in `params._meta`.
%
%   Subscriptions whose stream turns out to be dead are removed.
%   Silently succeeds when nothing is subscribed (e.g. during unit
%   tests).

mcp_notify(Method0, Params) :-
    atom_string(Method, Method0),
    forall(subscription(Key, Id, Filter, Sink),
           (   wants_notification(Method, Params, Filter)
           ->  subscription_message(Method, Params, Id, Message),
               deliver(Sink, Key, Message)
           ;   true
           )).

wants_notification('notifications/tools/list_changed', _, Filter) :-
    true == Filter.get(toolsListChanged).
wants_notification('notifications/prompts/list_changed', _, Filter) :-
    true == Filter.get(promptsListChanged).
wants_notification('notifications/resources/list_changed', _, Filter) :-
    true == Filter.get(resourcesListChanged).
wants_notification('notifications/resources/updated', Params, Filter) :-
    is_dict(Params),
    URIs = Filter.get(resourceSubscriptions),
    URI = Params.get(uri),
    atom_string(URIA, URI),
    member(U, URIs),
    atom_string(URIA, U),
    !.

subscription_message(Method, Params0, Id, Message) :-
    (   is_dict(Params0) -> Params1 = Params0 ; Params1 = #{} ),
    Meta0 = Params1.get('_meta', #{}),
    put_dict('io.modelcontextprotocol/subscriptionId', Meta0, Id, Meta),
    put_dict('_meta', Params1, Meta, Params),
    atom_string(Method, MethodS),
    Message = #{jsonrpc:"2.0", method:MethodS, params:Params}.

deliver(stream(Stream), Key, Message) :-
    (   catch(rpc_reply(Stream, Message, []), E,
              ( print_message(silent, E), fail ))
    ->  true
    ;   mcp_subscription_remove(Key)
    ).
deliver(queue(Queue), Key, Message) :-
    (   catch(thread_send_message(Queue, notification(Message)), E,
              ( print_message(silent, E), fail ))
    ->  true
    ;   mcp_subscription_remove(Key)
    ).
