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
tests/           (בדיקות Pester ו-PSScriptAnalyzer לפיתוח בלבד; לא מועתקות למחשב העבודה)
spec.md          (דרישות הפרויקט והסקילים)
```

## סקילים
| סקיל | מה עושה |
|---|---|
| `tfs-access` | עבודה מול שרת ה-TFS (Azure DevOps Server) הפנימי דרך REST מ-PowerShell. מודול `scripts/Tfs.psm1` עם פונקציות מוכנות (פריטים שלי, PR, בילדים, deployments, סיכום יומי ועוד) והגדרות ב-`scripts/tfs-config.psd1` |
| `project-map` | יצירת `PROJECT_MAP.md` – מפה קצרה של הפרויקט לסוכן |
| `microservices-logging-placement` | איפה, באיזו רמה ומה לרשום בלוגים במיקרו-שירותים |
| `outlook-access` | שליחה, קריאה וחיפוש מיילים דרך Outlook הקלאסי (COM) מ-PowerShell. הסקריפטים מצורפים ב-`scripts/` |

כל הסקילים מוגדרים **לא ליצור קבצים אם אפשר** – להריץ פקודות ישירות. סקריפטים נדרשים מגיעים מוכנים בתיקיית `scripts/` של הסקיל.

### פרטים למלא במחשב העבודה
פרטים ספציפיים של הארגון הוחלפו ב-placeholders. יש להחליף אותם אחרי ההעתקה:

| Placeholder | מה לשים | איפה |
|---|---|---|
| `<TFS_HOST>` | שם השרת של ה-TFS | רק `tfs-access/scripts/tfs-config.psd1` |
| `<COLLECTION>` | שם ה-collection (בדרך כלל `DefaultCollection`) | רק `tfs-access/scripts/tfs-config.psd1` |
| `<PROJECT>` | שם הפרויקט ב-TFS | רק `tfs-access/scripts/tfs-config.psd1` |
| `<N>` | גודל השרת (מספר repos / branches / definitions) – אופציונלי | `tfs-access/SKILL.md`, `tfs-access/references/git-and-prs.md` |
| `<WORK_EMAIL>` | כתובת המייל בעבודה (נמען ברירת מחדל) | `outlook-access/SKILL.md`, `outlook-access/scripts/send-mail.ps1` |

### הפעלה ראשונה של tfs-access
1. ב-`tfs-access\scripts\tfs-config.psd1` להחליף את שלוש ה-placeholders. אם שם הפרויקט בעברית, לשמור את הקובץ כ-UTF-8 **with BOM** (אחרת PowerShell 5.1 יקרא אותו שגוי).
2. להריץ ב-PowerShell:
```powershell
Import-Module "$env:USERPROFILE\.claude\skills\tfs-access\scripts\Tfs.psm1" -Force
Test-TfsSetup
```
הפלט קצר בכוונה: שלוש עמודות בלבד – Area, Result (PASS/FAIL/SKIP), Code – בלי שמות שרת, פרויקט או משתמש. אי אפשר להעתיק החוצה מהמחשב, לכן קוראים את הטבלה במחשב העבודה ומעבירים אליי במילים (למשל "Auth נכשל עם 401").
3. אם Windows חוסם את הקבצים שהועתקו (מסומנים כ"הורדו מהאינטרנט") או שהרצת `Import-Module` נחסמת – להריץ `Unblock-File "$env:USERPROFILE\.claude\skills\tfs-access\scripts\*"`. לא משנים את ה-execution policy.

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
