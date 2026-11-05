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

:- module(mcp_http, []).
:- use_module(library(mcp/server),
              [ mcp_dispatch/3,
                mcp_subscription_add/4,
                mcp_subscription_remove/1,
                mcp_current_tool_raw_schema/3
              ]).
:- use_module(library(http/thread_httpd), [http_spawn/2]).
:- use_module(library(http/http_dispatch), [http_handler/3, http_404/2]).
:- use_module(library(http/http_json), [http_read_json_dict/2]).
:- use_module(library(http/sse), [sse_open/1, sse_send/1, sse_comment/1]).
:- use_module(library(http/http_cors), [cors_enable/2, cors_enable/0]).
:- use_module(library(option), [option/2]).
:- use_module(library(uuid), [uuid/1]).
:- use_module(library(json), [json_write_dict/3, atom_json_dict/3]).
:- use_module(library(base64), [base64/2]).
:- use_module(library(utf8), [utf8_codes//1]).
:- use_module(library(lists), [member/2, append/3]).
:- use_module(library(apply), [maplist/2]).
:- use_module(library(uri), [uri_components/2, uri_authority_components/2]).
:- use_module(library(settings), [setting/4, setting/2]).
:- use_module(library(debug), [debug/3]).

/** <module> MCP Streamable HTTP transport (2026-07-28)

Implements the Streamable HTTP transport of the stateless MCP 2026-07-28
revision on a single endpoint, `/mcp` (the location `root(mcp)`).

  - POST /mcp
    The body is a single JSON-RPC request or notification.  Requests
    are answered with a single `application/json` JSON-RPC response.
    Notifications are answered with `202 Accepted`.

    The request headers `MCP-Protocol-Version`, `Mcp-Method` and, for
    `tools/call`, `resources/read` and `prompts/get`, `Mcp-Name` are
    required and must match the body.  So must any `Mcp-Param-{Name}`
    header designated by an `x-mcp-header` annotation in the tool's
    input schema.  Violations are answered with `400 Bad Request` and
    a `HeaderMismatch` (-32020) error.

    A `subscriptions/listen` request is answered with a long-lived
    `text/event-stream` response that carries the subscription's
    acknowledgement followed by the change notifications the client
    opted in to (for example `notifications/tools/list_changed` after
    mcp_notify/2).  Closing the stream ends the subscription.

  - GET and DELETE /mcp
    These were used by the 2024-11-05 HTTP+SSE and the 2025-xx
    session-based Streamable HTTP transports; they are answered with
    `405 Method Not Allowed`.  The `Mcp-Session-Id` and `Last-Event-ID`
    request headers are ignored: there are no sessions and streams are
    not resumable.

HTTP status codes follow the specification: modern protocol errors
(`UnsupportedProtocolVersion`, `MissingRequiredClientCapability`,
`HeaderMismatch`) and malformed messages map to `400`, an unknown method
to `404`, other JSON-RPC errors are returned with `200`.

## Origin validation

To protect locally running servers against DNS rebinding, a request
with an `Origin` header is only accepted if the origin is a loopback
address (`localhost`, `127.0.0.1`, `[::1]`) or is listed in the setting
`mcp_http:allowed_origins`; other origins get `403 Forbidden`.  Use
`*` to allow any origin, e.g.  for a public, read-only server:

    :- set_setting_default(mcp_http:allowed_origins, ['*']).

The HTTP server itself is started by the application, typically using
library(http/http_unix_daemon) or http_server/1.
*/

:- setting(allowed_origins, list(atom), [],
           'Origins (scheme://host[:port]) allowed to access the MCP \c
            endpoint besides loopback origins.  `*` allows any origin.').

%  library(pldoc) (pulled in transitively by mcp/servers/prolog_help
%  for manual_section's renderer) declares HTTP handlers under
%  the path aliases `pldoc`, `pldoc_man` and `pldoc_pkg`.  Those
%  aliases are normally registered when one loads library(doc_http)
%  to host a pldoc web frontend, which we do not.  Provide the same
%  declarations here so http_dispatch can resolve the aliases at
%  worker boot; the pldoc handlers themselves remain unused.

:- multifile http:location/3.
http:location(mcp,       root(mcp),         [priority(10)]).
% Hide PlDoc
http:location(pldoc,     root(pldoc),       [priority(-10)]).
http:location(pldoc_man, pldoc(refman),     [priority(-10)]).
http:location(pldoc_pkg, pldoc(package),    [priority(-10)]).

%  Catch-all 404 under /pldoc/* so the pldoc handlers, which we
%  loaded only for their renderer, do not accidentally serve.
%  hide_children(true) masks every more-specific pldoc handler the
%  imported pldoc modules also register, so we don't have to
%  http_delete_handler them and the masking survives reloads
%  cleanly.
:- http_handler(root(pldoc), http_404([]),
                [prefix, hide_children(true), priority(10)]).

:- http_handler(root(mcp), handle_mcp,
                [ methods([post, get, delete, options]),
                  id(mcp_http)
                ]).

%!  handle_mcp(+Request)
%
%   HTTP handler for the MCP endpoint.

handle_mcp(Request) :-
    \+ origin_allowed(Request),
    !,
    memberchk(origin(Origin), Request),
    debug(mcp(http), 'Rejected request from origin ~w', [Origin]),
    format('Status: 403 Forbidden~n'),
    reply_json(#{ jsonrpc:"2.0",
                  error: #{ code: -32600,
                            message: "Forbidden: origin not allowed",
                            data: Origin } }).
handle_mcp(Request) :-
    option(method(options), Request),
    !,
    cors_enable(Request,
                [ methods([post])
                ]),
    format('~n').
handle_mcp(Request) :-
    option(method(post), Request),
    !,
    handle_post(Request).
handle_mcp(_Request) :-
    %  GET (standalone SSE stream) and DELETE (session termination)
    %  were removed in MCP 2026-07-28.
    format('Status: 405 Method Not Allowed~n'),
    format('Allow: POST, OPTIONS~n'),
    reply_json(#{ jsonrpc:"2.0",
                  error: #{ code: -32600,
                            message: "Method not allowed: use POST" } }).


                /*******************************
                *             POST             *
                *******************************/

handle_post(Request) :-
    catch(http_read_json_dict(Request, Message), Err, true),
    (   var(Err)
    ->  handle_message(Request, Message)
    ;   message_to_string(Err, Msg),
        reply_status(400,
                     #{ jsonrpc:"2.0", id:null,
                        error: #{ code: -32700,
                                  message: "Parse error",
                                  data: Msg } })
    ).

handle_message(Request, Message) :-
    is_dict(Message),
    get_dict(method, Message, Method),
    get_dict(id, Message, Id),
    !,
    (   catch(check_headers(Request, Message), header_mismatch(Why), true),
        nonvar(Why)
    ->  debug(mcp(http), 'Header mismatch: ~w', [Why]),
        reply_status(400,
                     #{ jsonrpc:"2.0", id:Id,
                        error: #{ code: -32020,
                                  message: Why } })
    ;   debug(mcp(http), 'POST ~w id=~p', [Method, Id]),
        dispatch(Message, Reply, Listen),
        (   nonvar(Listen)
        ->  start_listen(Listen)
        ;   reply_rpc(Reply)
        )
    ).
handle_message(_Request, Message) :-
    %  Notifications (and anything invalid, which mcp_dispatch/3
    %  answers with an `Invalid Request` error).
    dispatch(Message, Reply, _),
    reply_rpc(Reply).

dispatch(Message, Reply, Listen) :-
    with_output_to(string(Reply),
                   mcp_dispatch(user:current_output, Message,
                                [subscription(Listen)])).

%!  reply_rpc(+Reply:string) is det.
%
%   Send the HTTP response for a message that has been dispatched.
%   A notification produces an empty Reply, for which the transport
%   requires `202 Accepted` and no body.

reply_rpc("") :-
    !,
    format('Status: 202 Accepted~n~n').
reply_rpc(Reply) :-
    catch(atom_json_dict(Reply, Dict, [value_string_as(string)]), _, fail),
    !,
    (   get_dict(error, Dict, Error),
        get_dict(code, Error, Code),
        error_status(Code, Status)
    ->  true
    ;   Status = 200
    ),
    reply_raw(Status, Reply).
reply_rpc(Reply) :-
    reply_raw(500, Reply).

error_status(-32700, 400).                      % Parse error
error_status(-32600, 400).                      % Invalid Request
error_status(-32601, 404).                      % Method not found
error_status(-32020, 400).                      % HeaderMismatch
error_status(-32021, 400).                      % MissingRequiredClientCapability
error_status(-32022, 400).                      % UnsupportedProtocolVersion

reply_status(Status, Dict) :-
    status_line(Status),
    reply_json(Dict).

reply_raw(Status, Text) :-
    status_line(Status),
    cors_enable,
    format('Content-Type: application/json; charset=UTF-8~n~n'),
    write(Text).

status_line(200) :- !.
status_line(Status) :-
    status_reason(Status, Reason),
    format('Status: ~d ~w~n', [Status, Reason]).

status_reason(400, 'Bad Request').
status_reason(404, 'Not Found').
status_reason(500, 'Internal Server Error').

reply_json(Dict) :-
    cors_enable,
    format('Content-Type: application/json; charset=UTF-8~n~n'),
    json_write_dict(current_output, Dict, [width(0)]).


                /*******************************
                *       HEADER VALIDATION      *
                *******************************/

%!  check_headers(+Request, +Message) is det.
%
%   Validate the MCP request headers against Message.  Raises
%   header_mismatch(Message) if they are missing, malformed or do not
%   match the body.
%
%   Note that http_read_request/2 canonicalises HTTP header names by
%   lowercasing and mapping `-` to `_`, so `MCP-Protocol-Version`
%   arrives as mcp_protocol_version(Value).

check_headers(Request, Message) :-
    Params = Message.get(params, #{}),
    check_protocol_version_header(Request, Params),
    get_dict(method, Message, MethodS),
    required_header(Request, mcp_method, 'Mcp-Method', MethodHdr),
    (   atom_string(MethodHdr, MethodS)
    ->  true
    ;   mismatch('Mcp-Method', MethodHdr, MethodS)
    ),
    atom_string(Method, MethodS),
    check_name_header(Method, Request, Params),
    check_param_headers(Method, Request, Params).

check_protocol_version_header(Request, Params) :-
    required_header(Request, mcp_protocol_version, 'MCP-Protocol-Version',
                    Version),
    (   is_dict(Params),
        get_dict('_meta', Params, Meta),
        is_dict(Meta),
        get_dict('io.modelcontextprotocol/protocolVersion', Meta, BodyVersion)
    ->  (   atom_string(Version, BodyVersion)
        ->  true
        ;   mismatch('MCP-Protocol-Version', Version, BodyVersion)
        )
    ;   true                % missing in body: reported by the dispatcher
    ).

name_method('tools/call',     name).
name_method('prompts/get',    name).
name_method('resources/read', uri).

check_name_header(Method, Request, Params) :-
    name_method(Method, Field),
    !,
    required_header(Request, mcp_name, 'Mcp-Name', Encoded),
    decode_header_value('Mcp-Name', Encoded, Name),
    (   is_dict(Params),
        get_dict(Field, Params, BodyName),
        string(BodyName),
        Name == BodyName
    ->  true
    ;   is_dict(Params),
        get_dict(Field, Params, BodyName)
    ->  mismatch('Mcp-Name', Name, BodyName)
    ;   format(string(Why),
               "Header mismatch: Mcp-Name header value '~w' does not \c
                match body: missing params.~w", [Name, Field]),
        throw(header_mismatch(Why))
    ).
check_name_header(_, _, _).

required_header(Request, Key, Name, Value) :-
    Term =.. [Key, Value],
    (   memberchk(Term, Request)
    ->  valid_header_value(Name, Value)
    ;   format(string(Why), "Header mismatch: missing required ~w header",
               [Name]),
        throw(header_mismatch(Why))
    ).

mismatch(Header, HeaderValue, BodyValue) :-
    format(string(Why),
           "Header mismatch: ~w header value '~w' does not match body \c
            value '~w'", [Header, HeaderValue, BodyValue]),
    throw(header_mismatch(Why)).

%!  valid_header_value(+Header, +Value) is det.
%
%   Header values must consist of visible ASCII, space and tab.

valid_header_value(Header, Value) :-
    atom_codes(Value, Codes),
    (   maplist(header_value_code, Codes)
    ->  true
    ;   format(string(Why),
               "Header mismatch: ~w header contains invalid characters",
               [Header]),
        throw(header_mismatch(Why))
    ).

header_value_code(0'\t) :- !.
header_value_code(C) :- between(0x20, 0x7e, C).

%!  decode_header_value(+Header, +Value, -String) is det.
%
%   Decode the `=?base64?...?=` sentinel encoding used by `Mcp-Name`
%   and `Mcp-Param-{Name}` for values that are not plain ASCII.

decode_header_value(Header, Value, String) :-
    atom_concat('=?base64?', Rest, Value),
    atom_concat(Encoded, '?=', Rest),
    !,
    (   catch(base64(Latin1, Encoded), _, fail),
        atom_codes(Latin1, Bytes),
        phrase(utf8_codes(Codes), Bytes)
    ->  string_codes(String, Codes)
    ;   format(string(Why),
               "Header mismatch: invalid Base64 encoding in ~w header",
               [Header]),
        throw(header_mismatch(Why))
    ).
decode_header_value(_, Value, String) :-
    atom_string(Value, String).

%!  check_param_headers(+Method, +Request, +Params) is det.
%
%   Validate the `Mcp-Param-{Name}` headers for the `x-mcp-header`
%   annotations in the input schema of the called tool.  A header
%   is required if the annotated argument has a non-null value.

check_param_headers('tools/call', Request, Params) :-
    is_dict(Params),
    get_dict(name, Params, NameS),
    string(NameS),
    atom_string(Name, NameS),
    mcp_current_tool_raw_schema(_, Name, Schema),
    !,
    Args = Params.get(arguments, #{}),
    x_mcp_headers(Schema, Headers),
    maplist(check_param_header(Request, Args), Headers).
check_param_headers(_, _, _).

check_param_header(Request, Args, header(HName, Path, Type)) :-
    (   arg_value(Path, Args, Value),
        Value \== null
    ->  atom_concat('Mcp-Param-', HName, Header),
        header_key(HName, Key),
        required_header(Request, Key, Header, Encoded),
        decode_header_value(Header, Encoded, HValue),
        (   header_matches(Type, HValue, Value)
        ->  true
        ;   mismatch(Header, HValue, Value)
        )
    ;   true
    ).

header_key(HName, Key) :-
    downcase_atom(HName, Lower),
    atomic_list_concat(Parts, '-', Lower),
    atomic_list_concat([mcp, param|Parts], '_', Key).

arg_value([], Value, Value).
arg_value([H|T], Dict, Value) :-
    is_dict(Dict),
    get_dict(H, Dict, Value0),
    arg_value(T, Value0, Value).

header_matches(integer, HValue, Value) :-
    !,
    catch(number_string(N, HValue), _, fail),
    N =:= Value.
header_matches(boolean, HValue, Value) :-
    !,
    atom_string(Value, HValue).
header_matches(_, HValue, Value) :-
    (   string(Value) -> HValue == Value
    ;   format(string(HValue), '~w', [Value])
    ).

%!  x_mcp_headers(+Schema, -Headers:list) is det.
%
%   Find the `x-mcp-header` annotations on properties that are
%   statically reachable from the root of Schema through `properties`
%   keys only.  Headers is a list of header(Name, Path, Type).

x_mcp_headers(Schema, Headers) :-
    phrase(x_mcp_headers(Schema, []), Headers).

x_mcp_headers(Schema, Path) -->
    { is_dict(Schema),
      get_dict(properties, Schema, Props),
      is_dict(Props),
      dict_pairs(Props, _, Pairs)
    },
    !,
    x_mcp_property_headers(Pairs, Path).
x_mcp_headers(_, _) -->
    [].

x_mcp_property_headers([], _) -->
    [].
x_mcp_property_headers([Key-Prop|T], Path) -->
    { append(Path, [Key], PropPath) },
    (   { is_dict(Prop),
          get_dict('x-mcp-header', Prop, HName0)
        }
    ->  { atom_string(HName, HName0),
          (   get_dict(type, Prop, Type0)
          ->  atom_string(Type, Type0)
          ;   Type = string
          )
        },
        [ header(HName, PropPath, Type) ]
    ;   []
    ),
    x_mcp_headers(Prop, PropPath),
    x_mcp_property_headers(T, Path).


                /*******************************
                *     subscriptions/listen     *
                *******************************/

%!  start_listen(+Listen) is det.
%
%   Serve a `subscriptions/listen` request.  The subscription is
%   registered with a fresh message queue that receives the
%   notifications sent by mcp_notify/2.  The response is an SSE stream
%   that is handed to a dedicated thread, so it is not subject to the
%   HTTP handler time limit and does not block an HTTP worker.

start_listen(listen(Id, Ack)) :-
    uuid(UUID),
    Key = http(UUID),
    message_queue_create(Queue),
    %  Register before the stream is opened so no notification sent
    %  after acknowledgement can be lost.  The acknowledgement is
    %  written before the queue is read, so it is always the first
    %  message on the stream.
    mcp_subscription_add(Key, Id, Ack, queue(Queue)),
    http_spawn(listen_stream(Key, Id, Ack, Queue), []).

listen_stream(Key, Id, Ack, Queue) :-
    debug(mcp(http), 'subscriptions/listen ~p (id ~p) opened', [Key, Id]),
    call_cleanup(
        catch(listen_stream_(Id, Ack, Queue), E,
              debug(mcp(http), 'subscription ~p closed: ~p', [Key, E])),
        end_subscription(Key, Queue)).

listen_stream_(Id, Ack, Queue) :-
    sse_open([]),
    Acknowledged = #{ jsonrpc:"2.0",
                      method:"notifications/subscriptions/acknowledged",
                      params: #{ '_meta':
                                   #{ 'io.modelcontextprotocol/subscriptionId':Id },
                                 notifications:Ack
                               }
                    },
    send_json_event(Acknowledged),
    listen_loop(Queue).

listen_loop(Queue) :-
    %  15 s heartbeat (an SSE comment) keeps idle reverse proxies from
    %  killing the stream and detects clients that went away.
    %  thread_get_message/3 with timeout/1 *fails* on expiry.
    (   thread_get_message(Queue, Event, [timeout(15)])
    ->  listen_event(Event, Queue)
    ;   sse_comment("keep-alive"),
        listen_loop(Queue)
    ).

listen_event(notification(Message), Queue) :-
    !,
    send_json_event(Message),
    listen_loop(Queue).
listen_event(close(Message), _Queue) :-
    !,
    send_json_event(Message).
listen_event(_, Queue) :-
    listen_loop(Queue).

send_json_event(Dict) :-
    with_output_to(string(JSON),
                   json_write_dict(current_output, Dict, [width(0)])),
    sse_send(#{event:"message", data:JSON}).

%  Stream closed by either side -- forget the subscription so
%  mcp_notify/2 stops enqueueing to a dead queue.
end_subscription(Key, Queue) :-
    mcp_subscription_remove(Key),
    catch(message_queue_destroy(Queue), error(_,_), true).


                /*******************************
                *        ORIGIN CHECK          *
                *******************************/

%!  origin_allowed(+Request) is semidet.
%
%   True if Request has no `Origin` header or the origin is allowed.

origin_allowed(Request) :-
    (   memberchk(origin(Origin), Request)
    ->  allowed_origin(Origin)
    ;   true
    ).

allowed_origin(Origin) :-
    setting(allowed_origins, Allowed),
    (   memberchk('*', Allowed)
    ;   memberchk(Origin, Allowed)
    ),
    !.
allowed_origin(Origin) :-
    catch(uri_components(Origin, uri_components(Scheme, Authority, _, _, _)),
          _, fail),
    memberchk(Scheme, [http, https]),
    nonvar(Authority),
    uri_authority_components(Authority, uri_authority(_, _, Host, _)),
    loopback_host(Host),
    !.

loopback_host(localhost).
loopback_host('127.0.0.1').
loopback_host('::1').
loopback_host('[::1]').
