%%% Minimal Erlang FFI for glammy. Anything that needs raw BEAM
%%% primitives (try/catch, etc.) lives here so the Gleam source stays
%%% clean.

-module(glammy_ffi).
-export([try_run/1]).

%% Run a thunk and catch synchronous error/exit/throw exceptions. Returns `ok`
%% on successful completion, or `{error, Reason}` for a caught exception.
%% Untrappable process exit signals are observed by the Gleam-side monitor.
%% Foreign terms are formatted here so the Gleam FFI boundary can expose an
%% exact String contract rather than pretending arbitrary BEAM values are a
%% concrete Gleam type.
try_run(F) ->
    try
        F(),
        {ok, nil}
    catch
        Class:Reason:Stack ->
            {error,
                {atom_to_binary(Class, utf8),
                    format_term(Reason),
                    format_term(Stack)}}
    end.

format_term(Term) ->
    unicode:characters_to_binary(io_lib:format("~0tp", [Term])).
