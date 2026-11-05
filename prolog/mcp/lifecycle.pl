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

:- module(mcp_lifecycle,
          [ check_request_meta/1,       % +Params
            discover/1,                 % -Result
            server_implementation/1     % -Implementation
          ]).
:- use_module(library(debug), [debug/3]).
:- use_module(server,
              [ mcp_supported_protocol_versions/1,
                mcp_get_server_info/1,
                mcp_server_capabilities/1
              ]).

/** <module> MCP per-request lifecycle: version negotiation and discovery

Since revision 2026-07-28 MCP is stateless.  There is no `initialize`
handshake; instead every request carries, in `params._meta`:

  - `io.modelcontextprotocol/protocolVersion` (required)
  - `io.modelcontextprotocol/clientCapabilities` (required)
  - `io.modelcontextprotocol/clientInfo` (optional, informational)
  - `io.modelcontextprotocol/logLevel` (optional, deprecated)

check_request_meta/1 validates this metadata for each request and
discover/1 produces the result of the mandatory `server/discover`
request.
*/

%!  check_request_meta(+Params:dict) is det.
%
%   Validate the protocol metadata in Params.  Raises
%   mcp_error(Code, Message, Data) if the request cannot be served:
%
%     - `-32022` (UnsupportedProtocolVersion) if the requested version
%       is not one we implement.  Data holds `supported` and
%       `requested` as required by the specification.
%     - `-32602` (Invalid params) if required metadata is missing or
%       malformed.
%
%   Servers must not rely on prior requests to establish context, so
%   nothing is remembered from the metadata.

check_request_meta(Params) :-
    mcp_supported_protocol_versions(Versions),
    (   get_dict('_meta', Params, Meta),
        is_dict(Meta)
    ->  true
    ;   throw(mcp_error(-32602,
                        "Invalid params: missing _meta with protocol version \c
                         and client capabilities",
                        #{supported:Versions}))
    ),
    check_protocol_version(Meta, Versions),
    check_client_capabilities(Meta),
    check_log_level(Meta).

check_protocol_version(Meta, Versions) :-
    (   get_dict('io.modelcontextprotocol/protocolVersion', Meta, Requested)
    ->  (   string(Requested)
        ->  (   atom_string(Version, Requested),
                memberchk(Version, Versions)
            ->  debug(mcp(lifecycle), 'protocol version ~w', [Version])
            ;   throw(mcp_error(-32022, "Unsupported protocol version",
                                #{supported:Versions, requested:Requested}))
            )
        ;   throw(mcp_error(-32602,
                            "Invalid params: io.modelcontextprotocol/protocolVersion \c
                             must be a string",
                            #{supported:Versions}))
        )
    ;   throw(mcp_error(-32602,
                        "Invalid params: missing _meta field \c
                         io.modelcontextprotocol/protocolVersion",
                        #{supported:Versions}))
    ).

check_client_capabilities(Meta) :-
    (   get_dict('io.modelcontextprotocol/clientCapabilities', Meta, Caps),
        is_dict(Caps)
    ->  true
    ;   throw(mcp_error(-32602,
                        "Invalid params: missing _meta field \c
                         io.modelcontextprotocol/clientCapabilities",
                        _))
    ).

%   We never emit notifications/message (the logging capability is
%   not advertised), but an invalid level SHOULD still be rejected.

check_log_level(Meta) :-
    (   get_dict('io.modelcontextprotocol/logLevel', Meta, Level)
    ->  (   string(Level),
            atom_string(L, Level),
            log_level(L)
        ->  true
        ;   throw(mcp_error(-32602, "Invalid params: invalid log level",
                            #{logLevel:Level}))
        )
    ;   true
    ).

log_level(debug).
log_level(info).
log_level(notice).
log_level(warning).
log_level(error).
log_level(critical).
log_level(alert).
log_level(emergency).

%!  discover(-Result:dict) is det.
%
%   Result for `server/discover`: the protocol versions we support,
%   our capability set and, optionally, natural-language instructions.
%   The `_meta.serverInfo`, `resultType` and caching hints are added by
%   the dispatcher.

discover(Result) :-
    mcp_supported_protocol_versions(Versions),
    mcp_server_capabilities(Caps),
    Result0 = #{ supportedVersions: Versions,
                 capabilities: Caps
               },
    (   mcp_get_server_info(Info),
        get_dict(instructions, Info, Instructions)
    ->  Result = Result0.put(instructions, Instructions)
    ;   Result = Result0
    ).

%!  server_implementation(-Implementation:dict) is det.
%
%   The `Implementation` object describing this server, as declared by
%   mcp_server_info/1, without the `instructions` (which belong in
%   the `server/discover` result).

server_implementation(Info) :-
    mcp_get_server_info(Info0),
    (   del_dict(instructions, Info0, _, Info)
    ->  true
    ;   Info = Info0
    ).
