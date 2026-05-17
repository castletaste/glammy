%%% Minimal Erlang FFI for glammy. Anything that needs raw BEAM
%%% primitives (try/catch, etc.) lives here so the Gleam source stays
%%% clean.

-module(glammy_ffi).
-export([try_run/1]).

%% Run a thunk and catch any error/exit/throw. Returns `ok` on
%% successful completion, or `{error, Reason}` on any kind of failure.
%% `Reason` is a 3-tuple `{Class, Value, Stacktrace}` that callers can
%% destructure or stringify.
try_run(F) ->
    try
        F(),
        {ok, nil}
    catch
        Class:Reason:Stack -> {error, {Class, Reason, Stack}}
    end.
