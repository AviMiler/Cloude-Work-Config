---
name: project-map
description: Generate or refresh a compact PROJECT_MAP.md (React/JS/TS and .NET/C#) so a small-context AI agent knows what is in the project and in each file. Use when asked to map, index or summarize a codebase for an agent.
---

# Project Map

Produces `PROJECT_MAP.md` at the project root: a dense, token-cheap index an agent with a small context window reads FIRST, instead of opening files blindly.

Two stages: a script extracts structure (deterministic, offline, stdlib only), then the agent adds short human descriptions.

## Stage 1 — Run the script

1. If `scripts/map_project.py` (next to this SKILL.md) does not exist, write it from the "Script source" section below.
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

## Script source

```python
#!/usr/bin/env python3
"""Generate a compact code map (PROJECT_MAP.md) for React/JS/TS and .NET/C# projects.
Stdlib only - works offline.

Usage: python map_project.py <root> [--out PROJECT_MAP.md] [--max-symbols 8]
"""
import argparse
import json
import os
import re
import sys
from collections import defaultdict

SKIP_DIRS = {
    "node_modules", ".git", "bin", "obj", "dist", "build", "out", ".vs", ".vscode",
    ".idea", "coverage", ".next", "packages", "TestResults", "__pycache__", ".angular",
    "lib", "Migrations",
}
JS_EXT = {".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"}
CS_EXT = {".cs"}
CONFIG_FILES = {"package.json", "appsettings.json", "tsconfig.json", "vite.config.ts",
                "vite.config.js", "webpack.config.js"}
SKIP_FILE_RE = re.compile(r"(\.min\.js|\.d\.ts|\.designer\.cs|AssemblyInfo\.cs|\.g\.cs|GlobalUsings\.cs)$", re.I)

# ---------- JS / TS ----------
JS_IMPORT = re.compile(r"""^\s*import\s+(?:[^'"]*?\s+from\s+)?['"]([^'"]+)['"]""", re.M)
JS_REQUIRE = re.compile(r"""require\(\s*['"]([^'"]+)['"]\s*\)""")
JS_EXPORT_DEFAULT = re.compile(r"^\s*export\s+default\s+(?:async\s+)?(?:function|class)?\s*\*?\s*([A-Za-z_$][\w$]*)?", re.M)
JS_EXPORT_NAMED = re.compile(r"^\s*export\s+(?:async\s+)?(?:const|let|var|function\*?|class|interface|type|enum)\s+([A-Za-z_$][\w$]*)", re.M)
JS_EXPORT_LIST = re.compile(r"^\s*export\s*\{([^}]+)\}", re.M)
JS_COMPONENT = re.compile(r"^\s*(?:export\s+)?(?:default\s+)?(?:const|function)\s+([A-Z][\w$]*)\s*(?:=\s*(?:\([^)]*\)|[\w$]+)?\s*(?::[^=]+)?=>|\()", re.M)
JS_HOOK_USE = re.compile(r"\b(use[A-Z]\w*)\s*\(")
JS_API = re.compile(r"""\b(?:fetch|axios(?:\.(?:get|post|put|delete|patch))?|(?:api|http|client)\.(?:get|post|put|delete|patch))\s*\(\s*[`'"]([^`'"]+)[`'"]""")
JS_ROUTE = re.compile(r"""<Route\s+[^>]*path\s*=\s*[{'"]+([^'"}]+)""")

# ---------- C# ----------
CS_NS = re.compile(r"^\s*namespace\s+([\w.]+)", re.M)
CS_TYPE = re.compile(r"^\s*(?:\[[^\]]*\]\s*)*(?:public|internal|protected|private)?\s*(?:static\s+|abstract\s+|sealed\s+|partial\s+)*(class|interface|record|enum|struct)\s+(\w+)(?:<[^>]+>)?(?:\s*\([^)]*\))?(?:\s*:\s*([^{\n]+))?", re.M)
CS_METHOD = re.compile(r"^\s*(?:\[[^\]]*\]\s*)*public\s+(?:static\s+|virtual\s+|override\s+|async\s+|abstract\s+)*(?:[\w<>\[\],.?\s]+?)\s+(\w+)\s*\(([^)]*)\)", re.M)
CS_ROUTE = re.compile(r"""\[(Route|Http(?:Get|Post|Put|Delete|Patch))(?:\(\s*"([^"]*)"\s*\))?\]""")
CS_INJECT = re.compile(r"\b(I[A-Z]\w+)\s+_?\w+\s*[,)]")
CS_DBSET = re.compile(r"DbSet<(\w+)>")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            return f.read()
    except OSError:
        return ""


def short(items, n):
    items = list(dict.fromkeys(i for i in items if i))
    return items[:n] + ([f"+{len(items) - n}"] if len(items) > n else [])


def map_js(text, n):
    parts = []
    exports = JS_EXPORT_NAMED.findall(text)
    for grp in JS_EXPORT_LIST.findall(text):
        exports += [x.split(" as ")[-1].strip() for x in grp.split(",")]
    d = JS_EXPORT_DEFAULT.search(text)
    comps = [c for c in JS_COMPONENT.findall(text)]
    if comps:
        parts.append("cmp:" + ",".join(short(comps, n)))
    other = [e for e in exports if e not in comps]
    if other:
        parts.append("exp:" + ",".join(short(other, n)))
    if d and d.group(1) and d.group(1) not in comps:
        parts.append("default:" + d.group(1))
    hooks = [h for h in JS_HOOK_USE.findall(text) if h not in ("useState", "useEffect", "useRef", "useCallback", "useMemo")]
    if hooks:
        parts.append("hooks:" + ",".join(short(hooks, n)))
    apis = JS_API.findall(text)
    if apis:
        parts.append("api:" + ",".join(short(apis, n)))
    routes = JS_ROUTE.findall(text)
    if routes:
        parts.append("routes:" + ",".join(short(routes, n)))
    local = [m for m in JS_IMPORT.findall(text) + JS_REQUIRE.findall(text) if m.startswith((".", "@/", "~/"))]
    if local:
        parts.append("uses:" + ",".join(short([os.path.basename(x) for x in local], n)))
    return parts


def map_cs(text, n):
    parts = []
    for kind, name, bases in CS_TYPE.findall(text):
        tag = {"class": "C", "interface": "I", "record": "R", "enum": "E", "struct": "S"}[kind]
        s = f"{tag}:{name}"
        if bases:
            b = [x.strip().split("<")[0] for x in bases.split(",") if x.strip() and "where" not in x]
            if b:
                s += "<" + ",".join(b[:3])
        parts.append(s)
    routes = [f"{v.replace('Http', '').upper()} {p}".strip() if v != "Route" else f"route:{p}" for v, p in CS_ROUTE.findall(text)]
    if routes:
        parts.append("ep:[" + "; ".join(short(routes, n)) + "]")
    type_names = {t[1] for t in CS_TYPE.findall(text)}
    methods = [m for m, _ in CS_METHOD.findall(text) if m not in type_names]
    if methods:
        parts.append("m:" + ",".join(short(methods, n)))
    dbsets = CS_DBSET.findall(text)
    if dbsets:
        parts.append("db:" + ",".join(short(dbsets, n)))
    deps = CS_INJECT.findall(text)
    if deps:
        parts.append("di:" + ",".join(short(deps, n)))
    return parts


def map_config(path, text):
    name = os.path.basename(path)
    try:
        if name == "package.json":
            j = json.loads(text)
            deps = list(j.get("dependencies", {}).keys())
            scripts = list(j.get("scripts", {}).keys())
            return [f"name:{j.get('name', '?')}", "deps:" + ",".join(short(deps, 15)), "scripts:" + ",".join(scripts[:8])]
        if name.startswith("appsettings"):
            j = json.loads(re.sub(r"//.*", "", text))
            return ["keys:" + ",".join(j.keys())]
    except (ValueError, AttributeError):
        pass
    if name.endswith(".csproj"):
        tf = re.findall(r"<TargetFramework>([^<]+)", text)
        pk = re.findall(r'PackageReference\s+Include="([^"]+)"', text)
        refs = re.findall(r'ProjectReference\s+Include="([^"]+)"', text)
        out = []
        if tf:
            out.append("fw:" + tf[0])
        if pk:
            out.append("pkgs:" + ",".join(short(pk, 12)))
        if refs:
            out.append("refs:" + ",".join(os.path.basename(r) for r in refs))
        return out
    return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--out", default="PROJECT_MAP.md")
    ap.add_argument("--max-symbols", type=int, default=8)
    a = ap.parse_args()
    root = os.path.abspath(a.root)

    by_dir = defaultdict(list)
    stats = defaultdict(int)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and not d.startswith("."))
        rel_dir = os.path.relpath(dirpath, root).replace("\\", "/")
        for fn in sorted(filenames):
            if SKIP_FILE_RE.search(fn):
                continue
            ext = os.path.splitext(fn)[1].lower()
            full = os.path.join(dirpath, fn)
            if ext in JS_EXT:
                parts = map_js(read(full), a.max_symbols)
                stats["js/ts"] += 1
            elif ext in CS_EXT:
                parts = map_cs(read(full), a.max_symbols)
                stats["cs"] += 1
            elif fn in CONFIG_FILES or fn.endswith(".csproj") or fn.startswith("appsettings"):
                parts = map_config(full, read(full))
            else:
                continue
            by_dir[rel_dir].append((fn, parts))

    lines = [
        f"# PROJECT MAP: {os.path.basename(root)}",
        "<!-- generated by map_project.py; descriptions marked ⟨?⟩ to be filled by agent -->",
        "Legend: cmp=React component, exp=exports, hooks=custom hooks, api=HTTP calls, uses=local imports,",
        "C/I/R/E=class/interface/record/enum (<base), ep=endpoints, m=public methods, di=injected, db=DbSet",
        f"Files: {dict(stats)}",
        "",
        "## Overview",
        "⟨?⟩ purpose, stack, entry points, how to run",
        "",
        "## Map",
    ]
    for d in sorted(by_dir):
        lines.append(f"\n### {d}/  ⟨?⟩")
        for fn, parts in by_dir[d]:
            lines.append(f"- {fn}: " + " | ".join(parts) if parts else f"- {fn}")
    out = "\n".join(lines) + "\n"
    out_path = a.out if os.path.isabs(a.out) else os.path.join(root, a.out)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(out)
    print(f"Wrote {out_path}: {len(out)} chars (~{len(out) // 4} tokens), {sum(stats.values())} code files")


if __name__ == "__main__":
    sys.exit(main())
```
