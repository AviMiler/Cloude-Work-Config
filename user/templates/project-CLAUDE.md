# <Project name>
<One line: what this project is and its stack.>

## Commands (keep output quiet)
- Build: <.NET: `dotnet build <sln> -nologo -v:q -clp:ErrorsOnly` | React: `npm run build`>
- Test all: <`dotnet test <sln> -nologo -v:q` | `npm test`>
- Single test: <`dotnet test --filter <Name>` | `npm test -- <file>`>
- Lint: <`node_modules/.bin/eslint --quiet <file>`> (never `npx`)

## Where things are
- <API / backend code: path>
- <UI code: path>
- <Tests: path>
- <Config / settings: path>

## Conventions
- <Naming style>
- <Folder-per-feature or layer rule>
- <Error handling / logging rule>

## Examples to copy
- New endpoint: like <path/File.cs>
- New component: like <path/Component.tsx>
- New test: like <path/Tests.cs>

## Rules
- Grep before Read. Read line ranges, not whole files.
- Keep command output short (quiet flags, `| tail -20`).
- Do not add dependencies without asking.
