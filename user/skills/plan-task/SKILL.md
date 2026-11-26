---
name: plan-task
description: Turn a coding task into a small-step PLAN.md (no code edits). Runs only when the user types /plan-task.
disable-model-invocation: true
argument-hint: "<task description>"
---

# Plan a task

Task: $ARGUMENTS

Write `PLAN.md` at the project root. Make NO code edits.

1. If `PLAN.md` exists, ask before replacing it.
2. Read `PROJECT_MAP.md` and the project `CLAUDE.md` if present.
3. Locate code with Grep/Glob first. Then Read only the needed line ranges, never whole big files.
4. If something is genuinely unclear, ask ONE short list of questions. Never guess internal names.
5. Write `PLAN.md`:

```
# Plan: <short title>
Goal: <1 sentence>
Files to change: <paths>
Do not touch: <paths/areas>
Example to copy: <existing file/function in the same style>
Done when: <command or test>

## Steps
- [ ] 1. <small change> | files: <1-2 files> | check: <bash command>
- [ ] 2. ...
```

Step rules:
- Each step is small: 1-2 files.
- Each step names its files and one fast bash check, for example `dotnet build <csproj> -nologo -v:q -clp:ErrorsOnly`, `dotnet test --filter <Name>`, `npm test -- <file>`.
- Order steps so the build stays green after each one.

Finish: show the plan briefly, then tell the user: run /clear, then /next-step.
