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

:- module(mcp_tools,
          [ list_tools/1,               % -Tools
            call_tool/2                 % +Params, -Result
          ]).
:- use_module(library(mcp/content), [mcp_to_content_list/2]).
:- use_module(library(json_schema), [json_check/3]).
:- use_module(library(debug), [debug/3]).
:- use_module(server, [mcp_current_tool/4, mcp_current_tool_raw_schema/3]).

/** <module> tools/list and tools/call

Builds the `tools/list` response from the global tool registry and
dispatches `tools/call` to the registered handler in its declaring
module.

Handler contract:

    Handler(+Args:dict, -Content)

Following the MCP 2026-07-28 error model:

  - An unknown tool or a malformed `tools/call` request is a protocol
    error (JSON-RPC `Invalid params`, -32602).
  - Arguments that do not validate against the tool's `inputSchema`
    and exceptions raised by the handler are _tool execution errors_:
    they are reported in a normal result with `isError:true` so the
    LLM can see them and self-correct.
*/

%!  list_tools(-Tools:list) is det.
%
%   Tools are listed in registration order, which is deterministic for
%   a given server configuration (the specification asks for a
%   deterministic order to support client-side and prompt caching).

list_tools(Tools) :-
    findall(Tool, current_tool(Tool), Tools).

current_tool(#{name:NameS, description:Desc, inputSchema:Schema}) :-
    mcp_current_tool(Module, Name, Desc, _Compiled),
    mcp_current_tool_raw_schema(Module, Name, Schema0),
    object_schema(Schema0, Schema),
    atom_string(Name, NameS).

%!  object_schema(+Schema0, -Schema) is det.
%
%   Tool arguments are always objects and the specification requires
%   `type: "object"` at the root of `inputSchema`.  Add it if the
%   declaration left it implicit.

object_schema(Schema0, Schema) :-
    is_dict(Schema0),
    \+ get_dict(type, Schema0, _),
    !,
    put_dict(type, Schema0, object, Schema).
object_schema(Schema, Schema).


%!  call_tool(+Params, -Result) is det.
%
%   Params is `#{name:Name, arguments:Args}`.

call_tool(Params, Result) :-
    (   get_dict(name, Params, NameS),
        string(NameS)
    ->  true
    ;   throw(mcp_error(-32602, "Invalid params",
                        "tools/call requires a string name"))
    ),
    atom_string(Name, NameS),
    Args = Params.get(arguments, #{}),
    (   is_dict(Args)
    ->  true
    ;   throw(mcp_error(-32602, "Invalid params",
                        "tools/call arguments must be an object"))
    ),
    (   mcp_current_tool(Module, Name, _Desc, CompiledSchema)
    ->  validate_args(CompiledSchema, Args, Status),
        (   Status == ok
        ->  run_tool(Module, Name, Args, Result)
        ;   Status = invalid(Message),
            tool_error_result(Message, Result)
        )
    ;   format(string(Msg), "Unknown tool: ~w", [NameS]),
        throw(mcp_error(-32602, Msg, #{name: NameS}))
    ).

%!  validate_args(+CompiledSchema, +Args, -Status) is det.
%
%   Status is `ok` if Args is valid against the tool's input schema
%   and invalid(Message) otherwise.

validate_args(CompiledSchema, Args, Status) :-
    Error = error(Formal,_),
    (   catch(json_check(CompiledSchema, Args, []),
              Error,
              true)
    ->  true
    ;   Error = error(failed(json_check), _)
    ),
    (   var(Formal)
    ->  Status = ok
    ;   message_to_string(Error, Msg),
        format(string(Message), "Invalid arguments: ~w", [Msg]),
        Status = invalid(Message)
    ).

run_tool(Module, Name, Args, Result) :-
    debug(mcp(tools), 'call ~w:~w(~p)', [Module, Name, Args]),
    %  once/1: tool predicates routinely use a two-clause
    %  primary/fallback pattern (`tool(_, "failed"). `) and leave a
    %  choice point on success.  Without committing here mcp_dispatch
    %  itself is non-det, which breaks setup_call_cleanup callers --
    %  cleanup defers past following operations and a memory_file
    %  write stream stays open into the read step.
    catch(once(call(Module:Name, Args, Raw)),
          Error,
          tool_error(Error, Result)),
    (   nonvar(Result)
    ->  true
    ;   mcp_to_content_list(Raw, Content),
        Result = #{content:Content, isError:false}
    ).

tool_error(Error, Result) :-
    message_to_string(Error, Msg),
    debug(mcp(tools), 'tool raised: ~w', [Msg]),
    tool_error_result(Msg, Result).

tool_error_result(Msg, #{content:[#{type:"text", text:Msg}], isError:true}).
