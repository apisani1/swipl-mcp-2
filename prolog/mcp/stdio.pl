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

:- module(mcp_stdio,
          [ mcp_stdio_run/0,
            mcp_log/2                   % +Kind, +Term
          ]).
:- use_module(library(mcp/server),
              [ mcp_dispatch/3,
                mcp_current_tool/4,
                mcp_current_resource/4,
                mcp_current_prompt/4,
                mcp_subscription_remove/1
              ]).
:- use_module(library(json), [atom_json_dict/3, json_write_dict/3]).
:- use_module(library(readutil), [read_line_to_string/2]).
:- use_module(library(debug), [debug/3]).
:- use_module(library(aggregate), [aggregate_all/3]).

/** <module> stdio transport for MCP servers

Implements the stdio transport of MCP 2026-07-28.  Reads
newline-delimited JSON-RPC messages from stdin and writes responses
and notifications to stdout, one message per line. Before entering the
loop the original stdout stream is captured, Prolog's `user_output`  is
bound to a null stream and `user_error` is bound to a null stream if
writing an initial feedback message fails.

The protocol is stateless: there is no `initialize` handshake and each
request is validated on its own (see library(mcp/lifecycle)).  The
server never writes JSON-RPC _requests_ to stdout.  Besides responses
it only writes the change notifications a client opted in to with
`subscriptions/listen`; each carries the subscription id in `_meta`.
A subscription ends when the client sends `notifications/cancelled`
for the `subscriptions/listen` request or closes stdin.

A line that is not valid JSON is answered with a JSON-RPC `Parse error`
(-32700, `id: null`) and the server continues with the next line.  The
server exits when stdin is closed.

## Logging

If the environment variable `SWIPL_MCP_LOG` is set to a writable file
path, every incoming JSON-RPC request and, for target-driving tools,
the goal sent to the child plus the response returned, are appended to
that file with a fractional-second timestamp. Log-write failures are
swallowed so a full or missing filesystem cannot take the server down.

Typical use in an application file:

    :- module(my_server, []).
    :- use_module(library(mcp/server)).
    :- use_module(library(mcp/stdio)).

    :- mcp_tool(...).

    :- initialization(mcp_stdio_run, main).
*/

%!  mcp_stdio_run is det.
%
%   Run the MCP server on stdin/stdout until EOF.

mcp_stdio_run :-
    set_prolog_flag(verbose, silent),
    current_input(StdIn),
    current_output(StdOut),
    set_stream(StdIn,  encoding(utf8)),
    set_stream(StdOut, encoding(utf8)),
    redirect_user_io_to_null,
    open_request_log,
    catch(run_loop(StdIn, StdOut),
          Error,
          (   print_message(error, Error),
              halt(1)
          )),
    mcp_subscription_remove(sub(StdOut, _)),
    halt(0).

%!  open_request_log is det.
%
%   If the environment variable `SWIPL_MCP_LOG` is set, open the named
%   file in append mode, timestamp the session start, and stash the
%   handle for mcp_log/2. Otherwise leave logging disabled.

open_request_log :-
    (   getenv('SWIPL_MCP_LOG', Path),
        Path \== ''
    ->  catch(open(Path, append, Stream, [encoding(utf8), buffer(line)]),
              _, fail),
        assertz(mcp_log_stream(Stream)),
        get_time(T),
        format_time(string(TS), '%FT%T%z', T),
        current_prolog_flag(pid, PID),
        format(Stream, "~n=== session start ~w pid=~w ===~n", [TS, PID]),
        flush_output(Stream)
    ;   true
    ).

:- dynamic mcp_log_stream/1.

%!  mcp_log(+Kind, +Term) is det.
%
%   Write a single log record if logging is enabled. Kind is a short
%   atom (request, response, event); Term is the payload written with
%   ~q so it round-trips through read.

mcp_log(Kind, Term) :-
    (   mcp_log_stream(Stream)
    ->  get_time(T),
        format_time(string(TS), '%T.%3f', T),
        catch((   format(Stream, "~w ~w ~q.~n", [TS, Kind, Term]),
                  flush_output(Stream)
              ), _, true)
    ;   true
    ).

%!  redirect_user_io_to_null is det.
%
%   Bind user_input/user_output/user_error to null   streams  so nothing
%   accidentally writes to stdout (which IS the RPC channel) and so that
%   print_message/2 never short-circuits on a   stream-error flag, which
%   it would do if some earlier  write   to  user_error  failed. See the
%   second print_message/2 clause in boot/messages.pl   --  it skips ALL
%   hook dispatch when the destination has error(true).

redirect_user_io_to_null :-
    open_null_stream(NullOut),
    set_stream(NullOut, alias(user_output)),
    services(Tools, Resources, Prompts),
    (   catch(( format(user_error,
                       "Connected (~d tools, ~d resources, ~d prompts)\n",
                       [Tools, Resources, Prompts]),
                flush_output(user_error)
              ),
              error(_,_),
              fail)
    ->  true
    ;   open_null_stream(NullErr),
        set_stream(NullErr, alias(user_error))
    ).

services(Tools, Resources, Prompts) :-
    aggregate_all(count, mcp_current_tool(_,_,_,_), Tools),
    aggregate_all(count, mcp_current_resource(_,_,_,_), Resources),
    aggregate_all(count, mcp_current_prompt(_,_,_,_), Prompts).


%!  run_loop(+In, +Out) is det.
%
%   Process messages until end of file.  Messages are delimited by
%   newlines and may not contain embedded newlines, so we read a line
%   at a time.  This allows recovering from malformed input.

run_loop(In, Out) :-
    read_line_to_string(In, Line),
    (   Line == end_of_file
    ->  true
    ;   split_string(Line, "", " \t\r", [""])
    ->  run_loop(In, Out)                       % ignore empty lines
    ;   parse_message(Line, Result),
        (   Result = message(Message)
        ->  debug(mcp(stdio), 'received: ~p', [Message]),
            mcp_log(request, Message),
            catch(mcp_dispatch(user:Out, Message, []),
                  Error,
                  (   mcp_log(dispatch_error, Error),
                      print_message(error, Error)
                  ))
        ;   Result = error(ParseError),
            mcp_log(parse_error, Line),
            parse_error_reply(Out, ParseError)
        ),
        run_loop(In, Out)
    ).

parse_message(Line, Result) :-
    catch(atom_json_dict(Line, Message, [value_string_as(string)]),
          Error, true),
    (   var(Error)
    ->  Result = message(Message)
    ;   Result = error(Error)
    ),
    !.
parse_message(_, error(_)).

parse_error_reply(Out, Error) :-
    (   nonvar(Error)
    ->  message_to_string(Error, Msg)
    ;   Msg = "Invalid JSON"
    ),
    with_mutex(mcp_rpc_output,
               ( json_write_dict(Out,
                                 #{ jsonrpc:"2.0", id:null,
                                    error: #{ code: -32700,
                                              message: "Parse error",
                                              data: Msg }
                                  },
                                 [width(0)]),
                 nl(Out),
                 flush_output(Out)
               )).
