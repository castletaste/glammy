#!/bin/sh

set -eu

fail() {
  printf '%s\n' "keyed-executor startup barrier check failed: $*" >&2
  exit 1
}

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$repo_dir"

[ -d build/dev/erlang/glammy/ebin ] ||
  fail "run gleam build before this check"

# One scheduler plus a max-priority tracer makes the pre-AttachTask window
# deterministic. The executor creates its outcome guard, then its startup
# worker; that worker creates the real task. Suspending the worker at the spawn
# trace freezes the task before attachment. ExecutorTerminated must remain
# unobservable until the worker resumes and confirms the real task is down.
erl +S 1:1 -noshell -pa build/dev/erlang/*/ebin -eval '
process_flag(priority, max),
Parent = self(),
Run = fun(KillTaskBeforeAttach) ->
    {ok, ExecutorHandle} = glammy@keyed_executor:start(1, 1),
    Executor = glammy@keyed_executor:process_id(ExecutorHandle),
    Outcome = gleam@erlang@process:new_subject(),
    erlang:trace(Executor, true, [procs, set_on_spawn, {tracer, self()}]),
    spawn(fun() ->
        Result = glammy@keyed_executor:submit(
            ExecutorHandle,
            <<"startup-race">>,
            fun() -> <<"unexpected">> end,
            Outcome),
        Parent ! {submit_result, Result}
    end),
    receive {trace, Executor, spawn, _Guard, _} -> ok
    after 1000 -> erlang:error(outcome_guard_spawn_timeout)
    end,
    Worker = receive {trace, Executor, spawn, WorkerPid, _} -> WorkerPid
    after 1000 -> erlang:error(worker_spawn_timeout)
    end,
    Task = receive {trace, Worker, spawn, TaskPid, _} -> TaskPid
    after 1000 -> erlang:error(task_spawn_timeout)
    end,
    true = erlang:suspend_process(Worker),
    case KillTaskBeforeAttach of
        true -> exit(Task, kill);
        false -> ok
    end,
    timer:sleep(1),
    exit(Executor, kill),
    {error, nil} = gleam@erlang@process:'"'"'receive'"'"'(Outcome, 50),
    case KillTaskBeforeAttach of
        true -> false = is_process_alive(Task);
        false -> true = is_process_alive(Task)
    end,
    true = erlang:resume_process(Worker),
    {ok, executor_terminated} =
        gleam@erlang@process:'"'"'receive'"'"'(Outcome, 1000),
    timer:sleep(20),
    false = is_process_alive(Task),
    false = is_process_alive(Worker),
    {error, nil} = gleam@erlang@process:'"'"'receive'"'"'(Outcome, 20),
    ok
end,
ok = Run(false),
ok = Run(true),

%% A startup-worker crash is a different boundary: the executor remains live,
%% the accepted job gets one typed crash, and the same key must be reusable.
{ok, RecoveryHandle} = glammy@keyed_executor:start(1, 1),
RecoveryExecutor = glammy@keyed_executor:process_id(RecoveryHandle),
CrashOutcome = gleam@erlang@process:new_subject(),
erlang:trace(
    RecoveryExecutor,
    true,
    [procs, set_on_spawn, {tracer, self()}]),
spawn(fun() ->
    Result = glammy@keyed_executor:submit(
        RecoveryHandle,
        <<"startup-worker-kill">>,
        fun() -> <<"unexpected">> end,
        CrashOutcome),
    Parent ! {recovery_submit_result, Result}
end),
receive {trace, RecoveryExecutor, spawn, _RecoveryGuard, _} -> ok
after 1000 -> erlang:error(recovery_guard_spawn_timeout)
end,
RecoveryWorker =
    receive {trace, RecoveryExecutor, spawn, WorkerPid, _} -> WorkerPid
    after 1000 -> erlang:error(recovery_worker_spawn_timeout)
    end,
RecoveryTask =
    receive {trace, RecoveryWorker, spawn, TaskPid, _} -> TaskPid
    after 1000 -> erlang:error(recovery_task_spawn_timeout)
    end,
true = erlang:suspend_process(RecoveryWorker),
exit(RecoveryWorker, kill),
{ok, {crashed, <<"exit">>, <<"killed">>, <<"[]">>}} =
    gleam@erlang@process:'"'"'receive'"'"'(CrashOutcome, 1000),
receive {recovery_submit_result, {ok, nil}} -> ok
after 1000 -> erlang:error(recovery_submit_result_timeout)
end,
timer:sleep(20),
false = is_process_alive(RecoveryWorker),
false = is_process_alive(RecoveryTask),
true = is_process_alive(RecoveryExecutor),
{error, nil} = gleam@erlang@process:'"'"'receive'"'"'(CrashOutcome, 20),
RecoveredOutcome = gleam@erlang@process:new_subject(),
{ok, nil} = glammy@keyed_executor:submit(
    RecoveryHandle,
    <<"startup-worker-kill">>,
    fun() -> <<"recovered">> end,
    RecoveredOutcome),
{ok, {completed, <<"recovered">>}} =
    gleam@erlang@process:'"'"'receive'"'"'(RecoveredOutcome, 1000),
{error, nil} = gleam@erlang@process:'"'"'receive'"'"'(RecoveredOutcome, 20),
{ok, nil} = glammy@keyed_executor:stop(RecoveryHandle),
false = is_process_alive(RecoveryExecutor),
io:format("Keyed-executor startup DOWN barrier OK~n"),
halt().
'
