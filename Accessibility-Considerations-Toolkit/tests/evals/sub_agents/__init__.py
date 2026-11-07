"""Sub-agent harness for per-heuristic focused evaluation.

This package contains the building blocks for evaluations that fan out
one sub-task per Nielsen heuristic, with each sub-task seeing only the
heuristics index plus the one heuristic file it is responsible for.
This is the pattern that motivated the heuristics-file split: an
orchestrator decides which heuristics are in scope, then dispatches
focused sub-tasks that pay only for the content they need.

Modules:

- ``_loaders`` — focused system-prompt builders (index + one heuristic
  + one consideration).
- ``heuristic_subtask`` — factory for a single per-heuristic
  inspect-ai ``Task``.
- ``orchestrator`` — factory for the full set of per-heuristic tasks
  for a given consideration.
- ``eval_pack_smoke`` — smoke eval verifying the harness wires up
  correctly and the focused payload stays small.
"""
