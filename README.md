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
  skills/        -> ~/.claude/skills/        (סקילים)
```

## סקילים
| סקיל | מה עושה |
|---|---|
| `tfs-access` | עבודה מול שרת ה-TFS (Azure DevOps Server) הפנימי דרך REST מ-PowerShell |
| `project-map` | יצירת `PROJECT_MAP.md` – מפה קצרה של הפרויקט לסוכן |
| `microservices-logging-placement` | איפה, באיזו רמה ומה לרשום בלוגים במיקרו-שירותים |
| `outlook-access` | שליחה, קריאה וחיפוש מיילים דרך Outlook הקלאסי (COM) מ-PowerShell. הסקריפטים מצורפים ב-`scripts/` |

כל הסקילים מוגדרים **לא ליצור קבצים אם אפשר** – להריץ פקודות ישירות. סקריפטים נדרשים מגיעים מוכנים בתיקיית `scripts/` של הסקיל.

### פרטים למלא במחשב העבודה
פרטים ספציפיים של הארגון הוחלפו ב-placeholders. יש להחליף אותם אחרי ההעתקה:

| Placeholder | מה לשים | איפה |
|---|---|---|
| `<TFS_HOST>` | שם השרת של ה-TFS | `tfs-access` (כל הקבצים) |
| `<COLLECTION>` | שם ה-collection (בדרך כלל `DefaultCollection`) | `tfs-access` |
| `<PROJECT>` | שם הפרויקט ב-TFS | `tfs-access` |
| `<N>` | גודל השרת (מספר repos / branches / definitions) – אופציונלי | `tfs-access/SKILL.md`, `references/git-and-prs.md` |
| `<WORK_EMAIL>` | כתובת המייל בעבודה (נמען ברירת מחדל) | `outlook-access/SKILL.md`, `outlook-access/scripts/send-mail.ps1` |

## התקנה במחשב העבודה
**Windows (PowerShell):**
```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude" | Out-Null
Copy-Item user\CLAUDE.md     "$env:USERPROFILE\.claude\CLAUDE.md"
Copy-Item user\settings.json "$env:USERPROFILE\.claude\settings.json"
Copy-Item user\skills "$env:USERPROFILE\.claude\" -Recurse -Force
```

**Linux / macOS:**
```bash
mkdir -p ~/.claude
cp user/CLAUDE.md user/settings.json ~/.claude/
cp -r user/skills ~/.claude/
```

> אם כבר קיים `settings.json` במחשב (למשל עם הגדרות חיבור ל-API הפנימי), אל תדרוס אותו – מזג ידנית את `env` ו-`permissions`.
