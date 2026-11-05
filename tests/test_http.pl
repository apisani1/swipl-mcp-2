/*  Integration tests for library(mcp/http).

    Boots an HTTP server with the MCP Streamable HTTP endpoint on an
    ephemeral port (the OS picks one via port(Var)), then drives it
    from the test process using library(http/http_open) -- the same
    code path Claude Code and any other HTTP client would take.

    Run as:

        swipl -g 'test_http,halt' tests/test_http.pl
*/

:- module(test_http,
          [ test_http/0
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/http)).
:- use_module(library(plunit)).
:- use_module(library(debug), [assertion/1]).
:- use_module(library(http/http_open), [http_open/3]).
:- use_module(library(http/http_server), [http_server/1, http_stop_server/2]).
:- use_module(library(json), [atom_json_dict/3, json_write_dict/3]).
:- use_module(library(lists), [append/3]).
:- use_module(library(readutil), [read_line_to_string/2]).
:- use_module(library(base64), [base64/2]).
:- use_module(test_utils, [with_request_meta/2, request_meta/1]).

:- mcp_server_info(#{name:"test-http", version:"0.0"}).

%  Trivial tools registered against THIS module so tools/list /
%  tools/call have something to find while the HTTP transport runs
%  inside the same process.

:- mcp_tool(http_echo,
            "Echo the input message.",
            #{ type: object,
               properties: #{ msg: #{ type: string } },
               required: [msg]
             }).

http_echo(Args, Args.msg).

:- mcp_tool(http_region,
            "Tool with an argument mirrored into an HTTP header.",
            #{ type: object,
               properties: #{ region: #{ type: string,
                                         'x-mcp-header': "Region" },
                              count:  #{ type: integer,
                                         'x-mcp-header': "Count" }
                            },
               required: [region]
             }).

http_region(Args, Args.region).

test_http :-
    run_tests([http]).

:- dynamic test_port/1.

start_test_server :-
    %  port(Var) asks tcp_bind to pick a free port and binds Var to
    %  it; we read it back via http_server's option list.
    http_server([port(Port), silent(true)]),
    assertz(test_port(Port)).

stop_test_server :-
    forall(retract(test_port(P)),
           catch(http_stop_server(P, []), error(_,_), true)).


:- begin_tests(http,
               [ setup(start_test_server),
                 cleanup(stop_test_server)
               ]).

test(discover) :-
    mcp_post(#{ jsonrpc: "2.0", id: 1, method: "server/discover" },
             Status, Reply),
    assertion(Status == 200),
    assertion(Reply.result.resultType == "complete"),
    assertion(Reply.result.supportedVersions == ["2026-07-28"]),
    assertion(Reply.result.'_meta'.'io.modelcontextprotocol/serverInfo'.name
              == "test-http").

test(tools_call_echo) :-
    mcp_post(#{ jsonrpc: "2.0", id: 2, method: "tools/call",
                params: #{ name: "http_echo",
                           arguments: #{ msg: "hi from http" } } },
             Status, Reply),
    assertion(Status == 200),
    [Item] = Reply.result.content,
    assertion(Item.text == "hi from http"),
    assertion(false == Reply.result.isError).

test(no_session_id) :-
    %  Sessions were removed: an Mcp-Session-Id header is ignored and
    %  never minted.
    test_port(Port),
    request(#{ jsonrpc: "2.0", id: 3, method: "tools/list" }, Request),
    std_headers(Request, Headers),
    raw_post(Port, Request,
             ['Mcp-Session-Id'-"old-session"|Headers],
             Status, _Reply, [header(mcp_session_id, Sid)]),
    assertion(Status == 200),
    assertion(Sid == '').

test(missing_protocol_version_header) :-
    test_port(Port),
    request(#{ jsonrpc: "2.0", id: 4, method: "tools/list" }, Request),
    raw_post(Port, Request, ['Mcp-Method'-"tools/list"], Status, Reply, []),
    assertion(Status == 400),
    assertion(Reply.error.code == -32020).

test(protocol_version_header_mismatch) :-
    test_port(Port),
    request(#{ jsonrpc: "2.0", id: 5, method: "tools/list" }, Request),
    raw_post(Port, Request,
             [ 'MCP-Protocol-Version'-"2025-11-25",
               'Mcp-Method'-"tools/list"
             ], Status, Reply, []),
    assertion(Status == 400),
    assertion(Reply.error.code == -32020).

test(method_header_mismatch) :-
    test_port(Port),
    request(#{ jsonrpc: "2.0", id: 6, method: "tools/list" }, Request),
    raw_post(Port, Request,
             [ 'MCP-Protocol-Version'-"2026-07-28",
               'Mcp-Method'-"prompts/list"
             ], Status, Reply, []),
    assertion(Status == 400),
    assertion(Reply.error.code == -32020).

test(name_header_mismatch) :-
    test_port(Port),
    request(#{ jsonrpc: "2.0", id: 7, method: "tools/call",
               params: #{ name: "http_echo", arguments: #{msg:"x"} } },
            Request),
    raw_post(Port, Request,
             [ 'MCP-Protocol-Version'-"2026-07-28",
               'Mcp-Method'-"tools/call",
               'Mcp-Name'-"other_tool"
             ], Status, Reply, []),
    assertion(Status == 400),
    assertion(Reply.error.code == -32020).

test(name_header_base64) :-
    test_port(Port),
    request(#{ jsonrpc: "2.0", id: 8, method: "tools/call",
               params: #{ name: "http_echo", arguments: #{msg:"x"} } },
            Request),
    base64("http_echo", Enc),
    atomic_list_concat(['=?base64?', Enc, '?='], Encoded),
    raw_post(Port, Request,
             [ 'MCP-Protocol-Version'-"2026-07-28",
               'Mcp-Method'-"tools/call",
               'Mcp-Name'-Encoded
             ], Status, Reply, []),
    assertion(Status == 200),
    [Item] = Reply.result.content,
    assertion(Item.text == "x").

test(param_header) :-
    %  The value of an argument annotated with x-mcp-header must be
    %  mirrored in a matching Mcp-Param-{Name} header.
    test_port(Port),
    request(#{ jsonrpc: "2.0", id: 9, method: "tools/call",
               params: #{ name: "http_region",
                          arguments: #{region:"us-west1", count:42} } },
            Request),
    std_headers(Request, Headers),
    raw_post(Port, Request, Headers, Status1, Reply1, []),
    assertion(Status1 == 400),
    assertion(Reply1.error.code == -32020),
    raw_post(Port, Request,
             ['Mcp-Param-Region'-"us-west1", 'Mcp-Param-Count'-"42"|Headers],
             Status2, Reply2, []),
    assertion(Status2 == 200),
    [Item] = Reply2.result.content,
    assertion(Item.text == "us-west1"),
    raw_post(Port, Request,
             ['Mcp-Param-Region'-"eu-west1", 'Mcp-Param-Count'-"42"|Headers],
             Status3, Reply3, []),
    assertion(Status3 == 400),
    assertion(Reply3.error.code == -32020).

test(unsupported_version) :-
    test_port(Port),
    request_meta(Meta0),
    Meta = Meta0.put('io.modelcontextprotocol/protocolVersion', "1900-01-01"),
    Request = #{ jsonrpc: "2.0", id: 10, method: "tools/list",
                 params: #{ '_meta': Meta } },
    raw_post(Port, Request,
             [ 'MCP-Protocol-Version'-"1900-01-01",
               'Mcp-Method'-"tools/list"
             ], Status, Reply, []),
    assertion(Status == 400),
    assertion(Reply.error.code == -32022),
    assertion(Reply.error.data.supported == ["2026-07-28"]).

test(unknown_method_is_404) :-
    mcp_post(#{ jsonrpc: "2.0", id: 11, method: "nope/list" },
             Status, Reply),
    assertion(Status == 404),
    assertion(-32601 == Reply.error.code).

test(notification_accepted) :-
    test_port(Port),
    Notification = #{ jsonrpc: "2.0", method: "notifications/cancelled",
                      params: #{ requestId: 99 } },
    raw_post(Port, Notification, [], Status, _, []),
    assertion(Status == 202).

test(get_not_allowed) :-
    %  The standalone GET SSE stream was removed in 2026-07-28.
    test_port(Port),
    format(atom(URL), "http://localhost:~w/mcp", [Port]),
    catch(http_open(URL, In, [status_code(Status)]),
          error(_,_),
          Status = -1),
    (   nonvar(In) -> close(In) ; true ),
    assertion(Status == 405).

test(foreign_origin_forbidden) :-
    test_port(Port),
    request(#{ jsonrpc: "2.0", id: 12, method: "tools/list" }, Request),
    std_headers(Request, Headers),
    raw_post(Port, Request, ['Origin'-"http://evil.example"|Headers],
             Status, _, []),
    assertion(Status == 403),
    raw_post(Port, Request, ['Origin'-"http://localhost:3000"|Headers],
             Status2, _, []),
    assertion(Status2 == 200).

test(subscriptions_listen) :-
    %  subscriptions/listen answers with an SSE stream that starts with
    %  the acknowledgement and then carries the opted-in notifications.
    test_port(Port),
    request(#{ jsonrpc: "2.0", id: "listen-1",
               method: "subscriptions/listen",
               params: #{ notifications: #{ toolsListChanged: true,
                                            resourcesListChanged: true } }
             }, Request),
    std_headers(Request, Headers),
    post_options(Request, Headers, Options),
    format(atom(URL), "http://localhost:~w/mcp", [Port]),
    setup_call_cleanup(
        http_open(URL, In, [ status_code(Status),
                             header(content_type, ContentType)
                           | Options
                           ]),
        ( assertion(Status == 200),
          assertion(sub_atom(ContentType, 0, _, _, 'text/event-stream')),
          read_sse_data(In, Ack),
          assertion(Ack.method == "notifications/subscriptions/acknowledged"),
          dict_pairs(Ack.params.notifications, _, AckPairs),
          assertion(AckPairs == [toolsListChanged-true]),
          assertion(Ack.params.'_meta'.'io.modelcontextprotocol/subscriptionId'
                    == "listen-1"),
          mcp_notify('notifications/tools/list_changed', #{}),
          read_sse_data(In, Changed),
          assertion(Changed.method == "notifications/tools/list_changed"),
          assertion(Changed.params.'_meta'.'io.modelcontextprotocol/subscriptionId'
                    == "listen-1")
        ),
        close(In)).

:- end_tests(http).


%!  mcp_post(+Request, -Status, -Reply) is det.
%
%   POST Request (adding the mandatory `_meta`) to /mcp with the
%   standard MCP request headers.

mcp_post(Request0, Status, Reply) :-
    test_port(Port),
    request(Request0, Request),
    std_headers(Request, Headers),
    raw_post(Port, Request, Headers, Status, Reply, []).

request(Request0, Request) :-
    with_request_meta(Request0, Request).

%!  std_headers(+Request, -Headers) is det.
%
%   The standard Streamable HTTP request headers for Request.

std_headers(Request, Headers) :-
    Meta = Request.params.'_meta',
    Version = Meta.'io.modelcontextprotocol/protocolVersion',
    Headers0 = [ 'MCP-Protocol-Version'-Version,
                 'Mcp-Method'-Request.method
               ],
    (   (   Name = Request.params.get(name)
        ;   Name = Request.params.get(uri)
        )
    ->  append(Headers0, ['Mcp-Name'-Name], Headers)
    ;   Headers = Headers0
    ).

%!  raw_post(+Port, +Request, +Headers, -Status, -Reply, +Extra) is det.

raw_post(Port, Request, Headers, Status, Reply, Extra) :-
    format(atom(URL), "http://localhost:~w/mcp", [Port]),
    post_options(Request, Headers, Options0),
    append(Extra, [status_code(Status)|Options0], Options),
    setup_call_cleanup(
        http_open(URL, In, Options),
        read_string(In, _Len, Body),
        close(In)),
    (   Body == ""
    ->  Reply = #{}
    ;   atom_json_dict(Body, Reply, [value_string_as(string)])
    ).

post_options(Request, Headers, Options) :-
    with_output_to(string(JsonText),
                   json_write_dict(current_output, Request, [width(0)])),
    findall(request_header(Name=Value), member(Name-Value, Headers),
            HeaderOptions),
    append(HeaderOptions,
           [ method(post),
             request_header('Accept'='application/json, text/event-stream'),
             post(atom('application/json', JsonText))
           ],
           Options).

%!  read_sse_data(+In, -Dict) is det.
%
%   Read the next SSE event with a `data:` line and decode it.

read_sse_data(In, Dict) :-
    read_line_to_string(In, Line),
    (   Line == end_of_file
    ->  fail
    ;   string_concat("data: ", JSON, Line)
    ->  atom_json_dict(JSON, Dict, [value_string_as(string)])
    ;   read_sse_data(In, Dict)
    ).
