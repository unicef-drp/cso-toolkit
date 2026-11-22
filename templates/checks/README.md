# Check records

Each `<content-hash>.json` here records that `tools/check.R` passed, on someone's machine, for one exact state of the repository's content. Make one with `sh tools/check --record`: it runs the checks on a clean working tree and, if none fails, writes the record and commits it.

- **Content hash:** git's tree ID of the repository with this folder left out (`git ls-tree HEAD | grep -v .checks | git mktree`). A record certifies content, not a commit ID, so the commit that adds the record has the same content hash as the commit that was checked.
- **What a record holds:** the result of each check (`pass`, `advisory`, `skipped`), the commit and branch checked, the R and toolkit versions, the platform, who ran it, when, and the hash of `tools/check.R` itself.
- **Enforced:** the pre-push hook (`.githooks/pre-push`) refuses to push a tip without a passing record. The workflow `.github/workflows/check-record.yml` verifies the record of every pull request's latest commit; it runs no R and takes about 10 seconds. Branch protection requires it, and requires branches to be up to date, so what merges is what was checked.
- **After merging `develop` into a branch,** its content changes: record again before pushing. A pull request whose content is identical to an already recorded state, such as `develop` into `main` right after a feature merge, reuses that record.
- **One file per checked state,** so records never conflict between branches, and history keeps every checked state (about 1 KB each).
- **Limits:** a record can be written by hand. It prevents forgotten checks, not deliberate forgery.
