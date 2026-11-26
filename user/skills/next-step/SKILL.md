---
name: next-step
description: Do exactly the next unchecked step of PLAN.md, check it, then stop. Runs only when the user types /next-step.
disable-model-invocation: true
---

# Do the next step

1. Read `PLAN.md`. If missing, tell the user to run /plan-task and stop.
2. Take ONLY the first `- [ ]` step. Read the Goal, Do not touch and Example lines.
3. Make the change. Edit only the step's files. If another file is needed, ask first.
4. Run the step's check command. Keep output short.
5. On failure: fix and re-run, at most 2 fix attempts.
   Still failing: stop. Report the error in 5 lines or less and what you tried.
   Leave the step unchecked and add one line under it: `note: <what is blocking>`.
6. On success: mark the step `- [x]`. Add one `note:` line under it only if later steps need what you learned.
7. STOP. Never start the next step.

Finish:
- Steps remain: tell the user: run /clear, then /next-step.
- No unchecked steps remain: run the Done-when check, say done, and suggest deleting `PLAN.md`.
