# Git workflow

The `unicef-drp/cso-toolkit` repo follows a **two-trunk gitflow**: `main` is
the published trunk, `develop` is the integration trunk, and all task work
happens on short-lived `feature/*` (or `feat/*`) branches off `develop`.
Hotfix pushes directly to `develop` are permitted for admins only.

## Branches at a glance

| Branch | Role | Default | PR required | Force push | Deletion | Admin bypass |
|---|---|---|---|---|---|---|
| `main` | Published trunk — tagged releases live here | no | yes | blocked | blocked | **no** (`enforce_admins=true`) |
| `develop` | Integration trunk — what new work targets | **yes** | yes (0 approvals) | blocked | blocked | **yes** (hotfix path) |
| `feature/*` · `feat/*` | Short-lived task branches off `develop` | no | n/a | allowed (own branch) | allowed | n/a |
| `hotfix/*` (optional) | Same shape as `feat/*` but signalling intent | no | n/a | allowed (own branch) | allowed | n/a |

## Flow

```mermaid
flowchart LR
    subgraph Protected
        Main[main<br/>published trunk<br/>tagged releases]
        Develop[develop<br/>integration trunk<br/>DEFAULT branch]
    end

    subgraph Task
        Feat1[feat/task-A]
        Feat2[feat/task-B]
        Hotfix[hotfix push<br/>admin only]
    end

    Develop -->|branch off| Feat1
    Develop -->|branch off| Feat2

    Feat1 -->|PR · 0 approvals required| Develop
    Feat2 -->|PR · 0 approvals required| Develop

    Hotfix -.->|direct push<br/>admin bypass| Develop

    Develop -->|release PR<br/>enforce_admins=true| Main
    Main -->|tag vX.Y.Z| Main

    classDef trunk fill:#cce5ff,stroke:#0066cc,stroke-width:2px
    classDef integ fill:#d4edda,stroke:#28a745,stroke-width:2px
    classDef task  fill:#fff3cd,stroke:#856404
    classDef hot   fill:#f8d7da,stroke:#721c24

    class Main trunk
    class Develop integ
    class Feat1,Feat2 task
    class Hotfix hot
```

## The contract these rules enforce

1. **Nothing reaches `main` except via a release PR from `develop`.**
   `enforce_admins=true` on `main` means even repo admins must open the PR;
   the protection has no admin escape hatch. This keeps the public-facing
   trunk auditable and tag-able.
2. **All task work targets `develop`.** Open a `feat/<topic>` (or
   `feature/<topic>`) branch off `develop`, push commits, open a PR back to
   `develop`. Required-approvals count is `0` so a solo author can self-merge
   — but the PR itself is mandatory, which gives CI and reviewers a stable
   target to look at.
3. **Hotfix exception on `develop` only.** `enforce_admins=false` on
   `develop` means repo admins can push directly when a fix is urgent enough
   that the PR ceremony would do more harm than good. Use sparingly; record
   the rationale in the commit message so the audit trail survives.
4. **Force pushes and branch deletion are blocked on both trunks.** The
   `allow_force_pushes=false` and `allow_deletions=false` settings prevent
   rewriting published history or accidentally dropping a trunk.

## Standard recipes

### Task work (the 95% case)

```bash
git checkout develop
git pull
git checkout -b feat/short-topic

# ... work, commit atomically ...

git push -u origin feat/short-topic
gh pr create --base develop --head feat/short-topic \
    --title "feat(area): short description" \
    --body-file pr-body.md
gh pr merge --merge   # preserves "Y"-shape lineage; do not squash by default
```

### Release `develop` → `main`

```bash
git checkout develop
git pull
gh pr create --base main --head develop \
    --title "release: vX.Y.Z" \
    --body-file release-notes.md
# ... merge via UI or:
gh pr merge --merge

git checkout main && git pull
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

### Hotfix (admin path)

For genuinely urgent fixes that cannot wait for a PR cycle:

```bash
git checkout develop
git pull
# ... make the minimal fix, commit with a clear "hotfix:" prefix ...
git push origin develop
```

The admin bypass on `develop` lets this push through. The same commit must
then be carried into the next release PR to `main` so the public trunk
catches up — the hotfix does **not** automatically reach `main`.

### Recovering from a wrong-branch commit

If you accidentally commit on `develop` (instead of a feature branch):

```bash
git branch feat/recover-work      # save the work on a new branch
git reset --hard origin/develop   # reset develop to the remote tip
git checkout feat/recover-work    # continue work on the new branch
```

The protection settings will refuse a force push to `develop`, so even an
admin cannot rewrite its history — the recovery above is local-only.

## See also

- [`roles_and_workflow.md`](roles_and_workflow.md) — the parallel role
  contract on the data side (PRODUCER / REVIEWER / INGESTOR).
- [`toolkit_strategy.md`](toolkit_strategy.md) — vendoring model and version
  cadence; explains why `main` tags matter for downstream consumers.
