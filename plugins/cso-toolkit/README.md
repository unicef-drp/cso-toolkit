# cso-toolkit plugin for Claude Code

Five skills that walk an agent, and the person working with it, through the main cso-toolkit procedures. Each skill is a short procedure that points to the handbook chapter holding the rules, so the skills do not drift from the handbook: <https://unicef-drp.github.io/cso-toolkit/handbook/>. The handbook chapter "Working with AI coding agents" sets out the rules every agent follows in a toolkit repository; they live in the repository's `AGENTS.md`, not here.

| Skill | What it does |
|---|---|
| `/cso-toolkit:new-project` | Choose research project or official statistics, run `create_research_project()` / `create_official_stats_project()`, set the collaboration model, make the first commit |
| `/cso-toolkit:provenance` | Add an input with its provenance; explain a hash mismatch, a sidecar failure or an output that did not reproduce |
| `/cso-toolkit:check` | Run `sh tools/check`, explain each failure, fix the routine ones, record a passing run (`--record`) before a push |
| `/cso-toolkit:review` | Reviewer workflow: reproduce in the sandbox, compare with `dw_provenance_diff()` and `dw_compare()`, write the review note |
| `/cso-toolkit:update-toolkit` | Update the vendored copy with `cso_toolkit_sync()`: read the release notes (a dry run first), update from the tag, re-run the checks |

Claude also uses a skill on its own when a request matches its description; the slash command is for calling one by name.

## Install

Once per machine, or once per clone with `--scope project`:

```sh
claude plugin marketplace add unicef-drp/cso-toolkit
claude plugin install cso-toolkit@unicef-cso
```

Inside a session, the same with `/plugin marketplace add unicef-drp/cso-toolkit` and `/plugin install cso-toolkit@unicef-cso`. To pin a release, add the marketplace as `unicef-drp/cso-toolkit#<tag>`.

A repository can declare the marketplace and the plugin in its shared `.claude/settings.json`, so that members who trust the folder are offered it:

```json
{
  "extraKnownMarketplaces": {
    "unicef-cso": {
      "source": { "source": "github", "repo": "unicef-drp/cso-toolkit" }
    }
  },
  "enabledPlugins": {
    "cso-toolkit@unicef-cso": true
  }
}
```

Enabling a plugin in a committed file may not install it for every member: if `/plugin` reports that the plugin is not installed, run `claude plugin install cso-toolkit@unicef-cso --scope project` once in that clone.

## Test prompts

Run each in a session started in a toolkit repository (for `new-project`, in an empty folder). The skill should load, and the agent should follow its steps.

| Skill | Prompt | What to look for |
|---|---|---|
| `new-project` | "Set up a new research repository for a paper on school closures." | Asks which kind, the name, and single- or multi-producer before creating anything; does not vendor; does not touch `user_config.yml` |
| `provenance` | "I put a new survey file in data/external. Add it properly." | Checks the file is ignored, records a manifest row, commits no data, prints no rows |
| `check` | "Run the checks before I push." | Runs `sh tools/check`, explains each FAIL, ends with `sh tools/check --record`, never suggests `--no-verify` or a hand-written record |
| `review` | "Review the outputs on this branch." | Confirms `dw_mode` is reviewer, compares with `dw_provenance_diff()` / `dw_compare()`, writes a note with a verdict |
| `update-toolkit` | "Is our toolkit copy out of date? Update it." | Runs `cso_toolkit_check()`, then `cso_toolkit_sync(dry_run = TRUE)` on a branch, reports the `!!` entries and asks which tag before updating, re-runs the checks |

## Validate

From the repository root:

```sh
claude plugin validate .
```

The plugin has no `version` on purpose: Claude Code then treats each commit as a new version, so members get updates when the marketplace refreshes.

To try the plugin without installing it: `claude --plugin-dir ./plugins/cso-toolkit`.
