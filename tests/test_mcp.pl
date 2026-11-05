/*  Smoke tests for the MCP framework.

    Drives the dispatcher by handing it decoded request dicts and
    inspecting the reply written to a memory stream.  Covers the
    stateless MCP 2026-07-28 protocol: per-request `_meta`, version
    negotiation, `server/discover`, `resultType`, caching hints and
    `subscriptions/listen`.

    Run as:

        swipl -g 'test_mcp,halt' tests/test_mcp.pl
*/

:- module(test_mcp,
          [ test_mcp/0
          ]).
:- use_module(library(mcp/server)).
:- use_module(library(mcp/content)).
:- use_module(library(plunit)).
:- use_module(library(debug)).
:- use_module(library(lists)).
:- use_module(library(readutil), [read_line_to_string/2]).
:- use_module(library(json), [atom_json_dict/3]).
:- use_module(test_utils,
              [ dispatch/2,
                dispatch_raw/2,
                with_request_meta/2,
                request_meta/1
              ]).

:- mcp_server_info(#{ name:"test", version:"0.1",
                      instructions:"Use echo to echo."
                    }).

:- mcp_tool(
       echo,
       "Echo the input message.",
       #{ type:object,
          properties: #{msg: #{type:string}},
          required: [msg]
        }).

echo(Args, Args.msg).

:- mcp_tool(
       add,
       "Add two integers.",
       #{ type:object,
          properties: #{ a: #{type:integer}, b: #{type:integer} },
          required: [a, b]
        }).

add(#{a:A, b:B}, Result) :-
    Sum is A + B,
    format(string(Result), "~w", [Sum]).

:- mcp_prompt(
       greet,
       "Greet someone.",
       [ #{name:"who", description:"Who to greet", required:true} ]).

greet(Args, [#{role:"user", content:Content}]) :-
    format(string(Text), "Hello ~w", [Args.who]),
    mcp_text(Text, Content).

:- mcp_resource("test://static", "A static resource.",
                [ name("static"), handler(static_resource) ]).

static_resource(_URI, "static text").

:- mcp_resource_template("test://item/{id}", "Items by id.",
                         [ name("item"), handler(item_resource) ]).

item_resource(_URI, Bindings, Text) :-
    format(string(Text), "item ~w", [Bindings.id]).

test_mcp :-
    run_tests([mcp]).


:- begin_tests(mcp).

test(discover) :-
    dispatch(#{jsonrpc:"2.0", id:1, method:"server/discover"}, Reply),
    Result = Reply.result,
    assertion(Result.resultType == "complete"),
    assertion(Result.supportedVersions == ["2026-07-28"]),
    assertion(true == Result.capabilities.tools.listChanged),
    assertion(Result.instructions == "Use echo to echo."),
    Info = Result.'_meta'.'io.modelcontextprotocol/serverInfo',
    assertion(Info.name == "test"),
    assertion(\+ get_dict(instructions, Info, _)),
    assertion(Result.ttlMs == 0),
    assertion(Result.cacheScope == "public").

test(initialize_rejected) :-
    %  Legacy clients get an error naming the supported versions.
    dispatch_raw(#{ jsonrpc:"2.0", id:1, method:"initialize",
                    params: #{protocolVersion:"2025-11-25",
                              capabilities: #{},
                              clientInfo: #{name:"tester", version:"0"}} },
                 Reply),
    assertion(Reply.error.code == -32022),
    assertion(Reply.error.data.supported == ["2026-07-28"]),
    assertion(Reply.error.data.requested == "2025-11-25").

test(missing_meta) :-
    dispatch_raw(#{jsonrpc:"2.0", id:2, method:"tools/list"}, Reply),
    assertion(Reply.error.code == -32602).

test(unsupported_version) :-
    request_meta(Meta0),
    Meta = Meta0.put('io.modelcontextprotocol/protocolVersion', "1900-01-01"),
    dispatch(#{jsonrpc:"2.0", id:3, method:"tools/list",
               params: #{'_meta':Meta}}, Reply),
    assertion(Reply.error.code == -32022),
    assertion(Reply.error.data.requested == "1900-01-01"),
    assertion(Reply.error.data.supported == ["2026-07-28"]).

test(missing_client_capabilities) :-
    request_meta(Meta0),
    del_dict('io.modelcontextprotocol/clientCapabilities', Meta0, _, Meta),
    dispatch(#{jsonrpc:"2.0", id:4, method:"tools/list",
               params: #{'_meta':Meta}}, Reply),
    assertion(Reply.error.code == -32602).

test(invalid_log_level) :-
    request_meta(Meta0),
    Meta = Meta0.put('io.modelcontextprotocol/logLevel', "loud"),
    dispatch(#{jsonrpc:"2.0", id:5, method:"tools/list",
               params: #{'_meta':Meta}}, Reply),
    assertion(Reply.error.code == -32602).

test(tools_list) :-
    dispatch(#{jsonrpc:"2.0", id:2, method:"tools/list"},
             Reply),
    Result = Reply.result,
    Tools = Result.tools,
    findall(N, ( member(T, Tools), N = T.name ), Names0),
    sort(Names0, Names),
    assertion(Names == ["add","echo"]),
    assertion(Result.resultType == "complete"),
    assertion(Result.ttlMs == 0),
    assertion(Result.cacheScope == "public"),
    assertion(Result.'_meta'.'io.modelcontextprotocol/serverInfo'.name
              == "test"),
    forall(member(T, Tools), assertion(T.inputSchema.type == "object")).

test(invalid_cursor) :-
    dispatch(#{jsonrpc:"2.0", id:2, method:"tools/list",
               params: #{cursor:"page-2"}},
             Reply),
    assertion(Reply.error.code == -32602).

test(tools_call_echo) :-
    dispatch(#{ jsonrpc:"2.0", id:3, method:"tools/call",
                params: #{name:"echo", arguments: #{msg:"hi there"}} },
             Reply),
    [Item] = Reply.result.content,
    assertion(Item.text == "hi there"),
    assertion(Reply.result.isError == false),
    assertion(Reply.result.resultType == "complete"),
    assertion(\+ get_dict(ttlMs, Reply.result, _)).

test(tools_call_add) :-
    dispatch(#{ jsonrpc:"2.0", id:4, method:"tools/call",
                params: #{name:"add", arguments: #{a:3, b:4}} },
             Reply),
    [Item] = Reply.result.content,
    assertion(Item.text == "7").

test(tools_call_bad_args) :-
    %  Input validation errors are tool execution errors so the model
    %  can self-correct.
    dispatch(#{ jsonrpc:"2.0", id:5, method:"tools/call",
                params: #{name:"add", arguments: #{a:"oops", b:1}} },
             Reply),
    assertion(true == Reply.result.isError),
    assertion(Reply.result.resultType == "complete").

test(method_not_found) :-
    dispatch(#{jsonrpc:"2.0", id:6, method:"nope/list"},
             Reply),
    Code = Reply.error.code,
    assertion(Code == -32601).

test(ping_removed) :-
    dispatch(#{jsonrpc:"2.0", id:6, method:"ping"}, Reply),
    assertion(Reply.error.code == -32601).

test(unknown_tool) :-
    dispatch(#{ jsonrpc:"2.0", id:7, method:"tools/call",
                params: #{name:"missing", arguments: #{}} },
             Reply),
    assertion(Reply.error.code == -32602).

test(batch_rejected) :-
    dispatch_raw([#{jsonrpc:"2.0", id:8, method:"tools/list"}], Reply),
    assertion(Reply.error.code == -32600),
    assertion(Reply.id == null).

test(notification_no_reply) :-
    with_output_to(string(Out),
                   mcp_dispatch(user:current_output,
                                #{jsonrpc:"2.0",
                                  method:"notifications/initialized"},
                                [])),
    assertion(Out == "").

test(prompts) :-
    dispatch(#{jsonrpc:"2.0", id:9, method:"prompts/list"}, List),
    [P] = List.result.prompts,
    assertion(P.name == "greet"),
    assertion(List.result.ttlMs == 0),
    dispatch(#{jsonrpc:"2.0", id:10, method:"prompts/get",
               params: #{name:"greet", arguments: #{who:"Bob"}}}, Get),
    [Msg] = Get.result.messages,
    assertion(Msg.content.text == "Hello Bob"),
    assertion(Get.result.resultType == "complete").

test(prompt_missing_argument) :-
    dispatch(#{jsonrpc:"2.0", id:11, method:"prompts/get",
               params: #{name:"greet"}}, Reply),
    assertion(Reply.error.code == -32602).

test(resources) :-
    dispatch(#{jsonrpc:"2.0", id:12, method:"resources/list"}, List),
    [R] = List.result.resources,
    assertion(R.uri == "test://static"),
    dispatch(#{jsonrpc:"2.0", id:13, method:"resources/templates/list"},
             Templates),
    [T] = Templates.result.resourceTemplates,
    assertion(T.uriTemplate == "test://item/{id}"),
    dispatch(#{jsonrpc:"2.0", id:14, method:"resources/read",
               params: #{uri:"test://item/42"}}, Read),
    [C] = Read.result.contents,
    assertion(C.text == "item 42"),
    assertion(Read.result.cacheScope == "private"),
    assertion(Read.result.ttlMs == 0).

test(resource_not_found) :-
    dispatch(#{jsonrpc:"2.0", id:15, method:"resources/read",
               params: #{uri:"test://nope"}}, Reply),
    assertion(Reply.error.code == -32602).

test(resource_link) :-
    mcp_resource_link("file:///a.pl", [mime_type("text/x-prolog")], Link),
    assertion(Link.type == "resource_link"),
    assertion(Link.name == "file:///a.pl"),
    assertion(Link.mimeType == "text/x-prolog").

test(subscriptions_listen,
     [ setup(tmp_file_stream(text, File, Out)),
       cleanup(delete_file(File))
     ]) :-
    Listen = #{ jsonrpc:"2.0", id:"sub-1", method:"subscriptions/listen",
                params: #{ notifications:
                             #{ toolsListChanged:true,
                                promptsListChanged:true } } },
    with_request_meta(Listen, Request),
    mcp_dispatch(user:Out, Request, []),
    mcp_notify('notifications/tools/list_changed', #{}),
    mcp_notify('notifications/prompts/list_changed', #{}), % not honoured
    mcp_notify('notifications/test', #{}),                 % not deliverable
    mcp_dispatch(user:Out,
                 #{ jsonrpc:"2.0", method:"notifications/cancelled",
                    params: #{requestId:"sub-1"} }, []),
    mcp_notify('notifications/tools/list_changed', #{}),   % cancelled
    close(Out),
    read_json_lines(File, [Ack, Changed]),
    assertion(Ack.method == "notifications/subscriptions/acknowledged"),
    dict_pairs(Ack.params.notifications, _, AckPairs),
    assertion(AckPairs == [toolsListChanged-true]),
    assertion(Ack.params.'_meta'.'io.modelcontextprotocol/subscriptionId'
              == "sub-1"),
    assertion(Changed.method == "notifications/tools/list_changed"),
    assertion(Changed.params.'_meta'.'io.modelcontextprotocol/subscriptionId'
              == "sub-1"),
    assertion(\+ mcp_current_subscription(_, "sub-1", _, _)).

test(subscription_graceful_close,
     [ setup(tmp_file_stream(text, File, Out)),
       cleanup(delete_file(File))
     ]) :-
    with_request_meta(#{ jsonrpc:"2.0", id:77,
                         method:"subscriptions/listen",
                         params: #{notifications: #{toolsListChanged:true}}
                       }, Request),
    mcp_dispatch(user:Out, Request, []),
    mcp_subscription_close(sub(Out, 77)),
    close(Out),
    read_json_lines(File, [_Ack, Closed]),
    assertion(Closed.id == 77),
    assertion(Closed.result.resultType == "complete"),
    assertion(Closed.result.'_meta'.'io.modelcontextprotocol/subscriptionId'
              == 77).

:- end_tests(mcp).

read_json_lines(File, Dicts) :-
    setup_call_cleanup(
        open(File, read, In),
        read_json_lines_(In, Dicts),
        close(In)).

read_json_lines_(In, Dicts) :-
    read_line_to_string(In, Line),
    (   Line == end_of_file
    ->  Dicts = []
    ;   atom_json_dict(Line, Dict, [value_string_as(string)]),
        Dicts = [Dict|Rest],
        read_json_lines_(In, Rest)
    ).
