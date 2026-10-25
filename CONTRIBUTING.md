# Contributing

The rules this project follows. They are written down so the repo stays consistent and so anyone (including future me) can pick it up.

## 1. One-time setup per clone

```bash
pre-commit install
```

This activates the checks in `.pre-commit-config.yaml` so they run before every commit. You need `pre-commit` and `gitleaks` installed (`sudo pacman -S pre-commit gitleaks` on Arch/CachyOS).

## 2. Workflow

- Work happens on `main`. There are no long-lived branches.
- A commit is made only when a piece of work is **finished and checked**: it builds, its tests pass, and its docs are updated.
- Before committing, review what will go in:

  ```bash
  git status
  git diff
  ```

- Then commit and push in one line:

  ```bash
  git add -A && git commit -m "type(scope): short summary" && git push origin main
  ```

  `git push origin main` means "push to the remote called `origin`, branch `main`". The remote always comes first.

## 3. Commit messages: Conventional Commits

Format: `type(scope): summary in the imperative, lower case, no full stop`

| Type | Use for | Example |
|---|---|---|
| `feat` | A new feature | `feat(api): add customer search endpoint` |
| `fix` | A bug fix | `fix(api): bind search parameters (S-04)` |
| `docs` | Documentation only | `docs: add backup runbook` |
| `chore` | Tooling, config, moving files | `chore: move legacy app to legacy/` |
| `refactor` | Code change with no behaviour change | `refactor(db): extract posting package` |
| `test` | Tests only | `test(api): cover account opening approval` |
| `build` / `ci` | Docker, dependencies, GitHub Actions | `build(db): add Oracle 26ai Free compose file` |

Scopes used here: `db`, `api`, `ui`, `backup`, `docs`, `legacy`. When a commit fixes a known legacy problem, reference its ID from the limitations register (kept with the project docs, outside this repo), e.g. `(S-04)`.

## 4. Secrets: never in git

- No passwords, keys, tokens, wallets or real connection strings in any committed file.
- Real values go in `.env` (gitignored). The committed `.env.example` lists the variable **names** with placeholder values.
- SQL scripts that create users read passwords from variables, never literals.
- `gitleaks` runs before every commit, and GitHub push protection is a second safety net.
- If a secret is ever committed: treat it as leaked. Change it first, then clean up.

## 5. Code style

| Language | Tooling | Rules |
|---|---|---|
| Python | Ruff (lint + format), config in `ruff.toml` | Type hints on public functions; Google-style docstrings on every module, class and public function |
| SQL / PL/SQL | Reviewed by hand | Upper-case keywords; one object per file under `database/`; scripts safe to re-run where possible; every package and procedure has a header comment |
| Svelte / TypeScript | Prettier + ESLint (added with the frontend) | Components small and named by what they show |

Comments explain **why**, not what the code obviously does.

## 6. Documentation

- **In the repo:** `README.md`, this file, folder READMEs, and documentation inside the code: docstrings on every module, class and public function, and header comments on SQL and PL/SQL.
- **Outside the repo:** project documentation (design, limitations register, engineering log, guides) lives in the maintainer's separate docs folder. Update it in the same work session as the code it describes.
- When you introduce a new engineering practice, record it in the engineering log so the reasoning is kept.
- **Markdown style:** one paragraph (or list item) per line, with no manual line breaks inside a sentence. Your editor wraps long lines to the window; this repo's `.vscode/settings.json` turns that on for Markdown.

## 7. The `legacy/` folder

`legacy/desktop-pyqt6/` holds the original 2024 desktop app for reference. It is **frozen**: no new features, and it is excluded from linting and formatting. The only changes since v1 were removing secrets and adding its README.
