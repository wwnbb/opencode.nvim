Each scenario below targets specific opencode.nvim plugin surfaces; paste the prompt into a fresh agent session inside this directory and watch which widgets light up.

## S1 — Exploration

- Surfaces: read widget, rg widget.

```
Find every reference to `finished` across this project. Read each hit in context and summarize why the flag is inconsistent with `completed`: who sets it, who reads it, and where the semantics diverge. Do not change any files yet.
```

## S2 — Multi-file rename

- Surfaces: edit widget / inline diffs, clarifying questions.

```
Replace the deprecated `finished` flag with a new `archived: bool` field everywhere in this project while keeping API responses backward compatible for old clients that still send and expect `finished`. Update models, stores, routes, scripts, and tests consistently.
```

(Deliberately ambiguous: whether responses should include both fields, how `finished` maps to `archived`, etc. A good agent asks clarifying questions before editing.)

## S3 — Implement FileStore

- Surfaces: edit widget.

```
Unskip the three tests in tests/test_file_store.py, then implement FileStore in store.py so those tests pass. Keep the method signatures identical to MemoryStore, persist todos as JSON at the given path, and outline the steps before executing.
```

## S4 — Ambiguous feature

- Surfaces: question widget (clarifying questions).

```
Add due dates to todos.
```

(Intentionally underspecified: date format? timezone? required or optional? overdue handling? A good agent asks instead of guessing.)

## S5 — Bash workflow

- Surfaces: bash widget.

```
Start the API server in the background on port 8000, seed it using scripts/seed.py, fetch /stats/summary with curl, show me the JSON result, then stop the server cleanly.
```

## S6 — Destructive cleanup

- Surfaces: permission widget.

```
Remove all cached artifacts (__pycache__ and .pytest_cache) in this project, then rerun the full test suite and report the summary line.
```

(The rm step should surface a destructive-command approval.)

## S7 — Planned storage change

- Surfaces: edit widget.

```
Plan first, then execute: add a use_file_store: bool = False keyword argument to create_app() in main.py. When True, wire FileStore("todos.json") into both routers instead of MemoryStore. Default behavior must stay identical; add a test covering both modes.
```

## S8 — Parallel subtasks

- Surfaces: task/subagent widget.

```
Implement two independent scripts that consume GET /todos from the local server: scripts/export_csv.py writes todos.csv and scripts/report_md.py writes report.md. Work on them as parallel subtasks; they must not touch each other's files.
```

## S9 — Behavior change

- Surfaces: rg widget, read widget, edit widget.

```
Make GET /todos return todos sorted by id descending instead of insertion order. Update the implementation AND every affected test in the same change so the suite stays green afterwards.
```

## S10 — Large reviewable diff

- Surfaces: edit review flow, diff widgets.

```
In one session, perform Scenario S2 (replace `finished` with `archived`) and Scenario S3 (implement FileStore). When both are done, produce the complete unified diff of every file you changed so I can review it end to end.
```

## S11 — TDD feature

- Surfaces: bash widget, edit widget.

```
Add GET /stats/daily returning the number of completions per day for the last 7 days (todos will need a completion timestamp). Write failing tests first, run pytest to show red, then implement until green.
```
