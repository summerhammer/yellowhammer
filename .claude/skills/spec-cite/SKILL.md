---
name: spec-cite
description: Build the mandated `Spec: <epic>/<story> @ <sha>` traceability line for a commit message or PR body, and verify the cited spec version is actually resolvable. Use when committing or opening a PR for spec'd behavior, or when asked for the spec version a change was built against.
---

# Spec citation line

`../yellowhammer-spec/CONSUMING.md` mandates this line on every pull request that
implements spec'd behavior — it is the only mechanism that makes spec drift
detectable later:

```
Spec: <epic>/<story> @ <spec commit sha>
```

Story IDs go in commit messages too. One line per story if a change covers several.

## Steps

1. **Resolve the story ID.** Prefer `$ARGUMENTS`. Otherwise take it from the
   conversation, or from the branch name. The ID is the story's *path* under
   `../yellowhammer-spec/docs/requirements/epics/`, as `<epic>/<story>` — no
   `.md`, no `stories/` segment. Confirm it exists:

   ```
   ls ../yellowhammer-spec/docs/requirements/epics/<epic>/stories/<story>.md
   ```

   If it does not resolve, stop and ask — do not guess an ID. A wrong ID is worse
   than no line, because it reads as a verified citation.

2. **Resolve the spec version.**

   ```
   git -C ../yellowhammer-spec rev-parse --short=12 HEAD
   ```

3. **Check the citation is resolvable, and report any of these that is true.** Do
   not silently emit a line that nobody else can resolve.

   ```
   git -C ../yellowhammer-spec status --porcelain -- docs/
   git -C ../yellowhammer-spec rev-parse --abbrev-ref HEAD
   git -C ../yellowhammer-spec rev-list --count origin/main..HEAD
   ```

   - **Uncommitted changes under `docs/`** — the spec you read does not match any
     commit, so the sha under-describes what you built against. Say so and name
     the modified files.
   - **HEAD is not on `main`** — the sha lives on a spec branch and may be rebased
     away. Name the branch.
   - **Commits ahead of `origin/main`** — the sha is local-only and will not
     resolve for anyone else until it is pushed. Give the count.

   Report the condition; do not fix it and do not commit in the spec repo. Editing
   the spec from this repo is forbidden.

4. **Emit the line**, then state any caveat from step 3 alongside it so the
   operator decides whether to proceed.

## Notes

- Cite the story's **path-derived** ID. Renaming a story file changes its ID and
  breaks every existing citation, so a citation that no longer resolves may mean a
  rename, not a mistake.
- If the work implements an ADR rather than a story, cite the ADR the same way:
  `Spec: tech/decisions/001-ports-for-external-dependencies @ <sha>`.
