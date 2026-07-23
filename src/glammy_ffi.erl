%%% Minimal Erlang FFI for glammy. Anything that needs raw BEAM
%%% primitives (try/catch, etc.) lives here so the Gleam source stays
%%% clean.

-module(glammy_ffi).
-export([try_run/1, try_run_redacted/1]).

%% Run a thunk and catch synchronous error/exit/throw exceptions. Preserve the
%% successful value and return a typed, safely rendered caught exception.
%% Untrappable process exit signals are observed by the Gleam-side monitor.
try_run(F) ->
    try
        {ok, F()}
    catch
        Class:Reason:Stack ->
            {error,
                {caught_exception,
                    exception_class(Class),
                    format_term(Reason),
                    format_term(Stack)}}
    end.

%% Callback diagnostics intentionally discard application exception details.
%% Keep this path allocation-light and do not render potentially secret terms.
try_run_redacted(F) ->
    try
        F(),
        {ok, nil}
    catch
        _:_ ->
            {error, nil}
    end.

exception_class(error) -> error_class;
exception_class(exit) -> exit_class;
exception_class(throw) -> throw_class.

format_term(Term) ->
    unicode:characters_to_binary(io_lib:format("~0tp", [Term])).
