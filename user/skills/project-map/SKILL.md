---
name: project-map
description: Generate or refresh a compact PROJECT_MAP.md (React/JS/TS and .NET/C#) so a small-context AI agent knows what is in the project and in each file. Use when asked to map, index or summarize a codebase for an agent.
---

# Project Map

Produces `PROJECT_MAP.md` at the project root: a dense, token-cheap index an agent with a small context window reads FIRST, instead of opening files blindly.

Two stages: a script extracts structure (deterministic, offline, stdlib only), then the agent adds short human descriptions.

## Files rule
If possible, do not create files: run commands directly. The only files this skill writes are `PROJECT_MAP.md` itself (and the temporary `PROJECT_MAP.new.md` during a refresh, which replaces it). No helper scripts, no scratch files.

## Stage 1 — Run the script

1. The script ships ready-made at `scripts/map_project.py` (next to this SKILL.md). Do not write or recreate it.
2. Run: `python scripts/map_project.py <project-root>` (options: `--out FILE`, `--max-symbols N`, default 8).
3. It prints the size in chars/~tokens. Target: under ~4k tokens for the whole map. If larger, rerun with `--max-symbols 4`, and/or add generated/irrelevant folders to `SKIP_DIRS`.

What it captures per file:
- JS/TS/JSX/TSX: `cmp` React components, `exp` exports, `hooks` custom hooks used, `api` HTTP URLs (fetch/axios/api.x), `routes` <Route path>, `uses` local imports.
- C#: `C/I/R/E/S` types with `<base`, `ep` endpoints ([Route]/[HttpX]), `m` public methods, `di` injected interfaces, `db` DbSet entities.
- Config: package.json (deps, scripts), .csproj (framework, packages, project refs), appsettings (top-level keys).

Skipped: node_modules, bin, obj, dist, build, .git, Migrations, lib, *.min.js, *.d.ts, *.Designer.cs, generated files.

## Stage 2 — Agent fills descriptions

Replace every `⟨?⟩` marker:
- `## Overview`: 3–6 lines — purpose, stack, entry points (Program.cs, main.tsx/index.js), how to run/build, where config lives.
- Each `### dir/ ⟨?⟩`: ≤10 words on the folder's role.
- Only for non-obvious files: append ` — <≤8 words>` to the line. Do NOT describe files whose name + symbols already say it.

Rules for this stage:
- Read files only as needed to understand them (head of file, signatures). Never paste code into the map.
- Keep the legend lines intact.
- Add a final `## Flows` section with 2–5 one-line key flows, e.g. `UI EmployeeList → GET /api/employees → EmployeesController.GetAll → IEmployeeService → AppDb.Employees`.
- Add `## Conventions` (≤5 lines) only if there are clear project patterns (naming, folder-per-feature, DTO mapping, etc.).

## Refresh

When the map exists and code changed: rerun the script to a temp file (`--out PROJECT_MAP.new.md`), carry over existing descriptions for unchanged dirs/files, fill `⟨?⟩` only for new ones, then replace the old map.

## Using the map (tell the consuming agent)

Add to the agent's instructions / CLAUDE.md: "Read PROJECT_MAP.md before exploring. Use it to pick the exact files to open; do not scan directories."
