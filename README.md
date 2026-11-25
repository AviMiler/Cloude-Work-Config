# Claude Work Config

הגדרות Claude Code למחשב העבודה (לא למחשב הפרטי).

## מגבלות הסביבה
| מגבלה | איך זה מטופל |
|---|---|
| אין אינטרנט – רשת פנימית בלבד | `WebFetch`/`WebSearch` חסומים; `curl`/`wget`/`git clone` דורשים אישור; תעבורה לא-חיונית (עדכונים אוטומטיים, טלמטריה) כבויה |
| לא מתקינים ספריות אלא אם אין ברירה | כל פקודת התקנה (npm/pip/nuget/choco/winget...) דורשת אישור, ו-`CLAUDE.md` מחייב לבדוק חלופות ולשאול לפני הוספת תלות |

## מבנה
```
user/
  CLAUDE.md      -> ~/.claude/CLAUDE.md      (הנחיות שחלות על כל הפרויקטים)
  settings.json  -> ~/.claude/settings.json  (הרשאות ומשתני סביבה)
```

## התקנה במחשב העבודה
**Windows (PowerShell):**
```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude" | Out-Null
Copy-Item user\CLAUDE.md     "$env:USERPROFILE\.claude\CLAUDE.md"
Copy-Item user\settings.json "$env:USERPROFILE\.claude\settings.json"
```

**Linux / macOS:**
```bash
mkdir -p ~/.claude
cp user/CLAUDE.md user/settings.json ~/.claude/
```

> אם כבר קיים `settings.json` במחשב (למשל עם הגדרות חיבור ל-API הפנימי), אל תדרוס אותו – מזג ידנית את `env` ו-`permissions`.
