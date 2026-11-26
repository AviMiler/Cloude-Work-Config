#!/usr/bin/env bash
# Claude Code Stop hook: build/lint only the changed .cs/.ts/.tsx/.js/.jsx files; exit 2 on errors.
# Never blocks on hook bugs. Disable with CLAUDE_SKIP_CHECK=1.
[ "${CLAUDE_SKIP_CHECK:-}" = "1" ] && exit 0
set +e
input=$(cat 2>/dev/null)
# Already continuing because of a previous Stop block: do not loop.
printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && exit 0
command -v git >/dev/null 2>&1 || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$root" ] && cd "$root" 2>/dev/null || exit 0

# Changed, existing files (handles renames and quoted paths).
files=()
while IFS= read -r line; do
  [ ${#line} -gt 3 ] || continue
  p=${line:3}
  case "$p" in *' -> '*) p=${p##* -> } ;; esac
  case "$p" in \"*\") p=${p#\"}; p=${p%\"} ;; esac
  case "$p" in */node_modules/*|node_modules/*|*/dist/*|dist/*|*/build/*|build/*) continue ;; esac
  [ -f "$p" ] && files+=("$p")
done < <(git -c core.quotepath=off status --porcelain -uall 2>/dev/null)
[ ${#files[@]} -gt 0 ] || exit 0

# Print nearest ancestor dir (up to repo root) containing a file matching $2 (glob).
nearest() {
  local d; d=$(dirname "$1")
  while :; do
    compgen -G "$d/$2" >/dev/null 2>&1 && { echo "$d"; return; }
    [ "$d" = "." ] && return
    d=$(dirname "$d")
  done
}

out=""
cs_dirs=(); js_dirs=()
for f in "${files[@]}"; do
  case "$f" in
    *.cs) d=$(nearest "$f" '*.csproj'); [ -n "$d" ] && cs_dirs+=("$d") ;;
    *.ts|*.tsx|*.js|*.jsx) d=$(nearest "$f" 'package.json'); [ -n "$d" ] && js_dirs+=("$d") ;;
  esac
done

# .NET: build each affected project once, no restore.
if [ ${#cs_dirs[@]} -gt 0 ] && command -v dotnet >/dev/null 2>&1; then
  while IFS= read -r d; do
    proj=$(compgen -G "$d/*.csproj" | head -n 1)
    res=$(dotnet build "$proj" --no-restore -nologo -v:q -clp:ErrorsOnly 2>&1); rc=$?
    [ $rc -eq 0 ] && continue
    if printf '%s' "$res" | grep -Eq 'NETSDK1004|project\.assets\.json'; then
      out+=$'run dotnet restore first\n'
    else
      out+="$res"$'\n'
    fi
  done < <(printf '%s\n' "${cs_dirs[@]}" | awk '!s[$0]++')
fi

# JS/TS: local tsc and eslint only (no npx, no install, no network).
if [ ${#js_dirs[@]} -gt 0 ]; then
  while IFS= read -r d; do
    bin="$d/node_modules/.bin"
    if [ -f "$bin/tsc" ] && [ -f "$d/tsconfig.json" ]; then
      res=$(cd "$d" && node_modules/.bin/tsc --noEmit -p . 2>&1); [ $? -ne 0 ] && out+="$res"$'\n'
    fi
    if [ -f "$bin/eslint" ]; then
      rel=(); prefix="${d#./}/"; [ "$d" = "." ] && prefix=""
      for f in "${files[@]}"; do
        case "$f" in *.ts|*.tsx|*.js|*.jsx) [ "$(nearest "$f" 'package.json')" = "$d" ] && rel+=("${f#"$prefix"}") ;; esac
      done
      if [ ${#rel[@]} -gt 0 ]; then
        res=$(cd "$d" && node_modules/.bin/eslint --quiet "${rel[@]}" 2>&1); [ $? -ne 0 ] && out+="$res"$'\n'
      fi
    fi
  done < <(printf '%s\n' "${js_dirs[@]}" | awk '!s[$0]++')
fi

[ -n "$out" ] || exit 0
# Dedupe (keep order), drop blanks, cap at 30 lines.
lines=$(printf '%s\n' "$out" | sed 's/\r$//' | awk 'NF && !s[$0]++')
total=$(printf '%s\n' "$lines" | wc -l | tr -d ' ')
{
  echo "Build/lint errors in changed files (git status). Fix them before finishing:"
  printf '%s\n' "$lines" | head -n 30
  [ "$total" -gt 30 ] && echo "... $((total - 30)) more"
} >&2
exit 2
