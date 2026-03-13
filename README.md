# Symphony

Sternberg-maintained fork of [openai/symphony](https://github.com/openai/symphony) with current Linear compatibility fixes, better defaults for production-style use, and a complete onboarding flow. Push tickets to a Linear board, agents ship the code.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

## Quick start

If you have an AI coding agent, one command:

```
npx skills add davidste/symphony -s symphony-setup -y
```

Then ask your agent to set up Symphony for your repo.

## How it works

Symphony polls a Linear project for active tickets. Each ticket gets an isolated workspace clone and a Codex agent. The agent reads the ticket, writes a plan, implements, validates, and opens a PR. You review PRs and move tickets through states — the agents handle the rest.

The state machine lives in `WORKFLOW.md` — a markdown file with YAML frontmatter for config and a prompt body that defines agent behavior. Hot-reloads in under a second, no restart needed.

## What's different from upstream

- **Cheaper Linear calls** — agents no longer burn tokens on schema introspection before every GraphQL call, and workpad sync is a single dynamic tool instead of a hand-rolled mutation
- **Correct sandbox** — the workflow is git + GitHub PR centric. Upstream's default sandbox blocks `.git/` writes, which silently breaks the entire flow. Fixed.
- **Media uploads via Linear** — upstream references a GitHub media upload skill that doesn't ship. The workflow and Linear skill now use Linear's native `fileUpload` mutation for screenshots and recordings
- **Setup skill** — auto-detects your repo, installs worker skills, creates Linear workflow states, and verifies everything before launch
- **Current Linear comment schema** — the bundled `linear` skill uses `resolvedAt` for comment resolution state, which matches current Linear GraphQL behavior

## Project-specific workflow overrides

The shared repo should stay generic. Put product- or repo-specific policy into the target
repository's `WORKFLOW.md`, not into the shared Symphony fork.

Common examples:

- override `hooks.after_create` for the real source repo and setup commands
- lower concurrency or turn limits for a cautious first rollout
- explicitly override legacy repo-local instructions that conflict with Symphony's control plane
  (for example, another tracker or mandatory local automation)
- teach workers how to launch and validate your app via a repo-local skill such as `launch-app`

## Manual setup

1. Build: `git clone https://github.com/davidste/symphony && cd symphony/elixir && mise trust && mise install && mise exec -- mix setup && mise exec -- mix build`
2. Install skills: `npx skills add davidste/symphony -a codex -s linear land commit push pull debug --copy -y` and copy `elixir/WORKFLOW.md` to your repo
3. In WORKFLOW.md, set `tracker.project_slug` and `hooks.after_create` (clone your repo + setup commands)
4. Add **Rework**, **Human Review**, **Merging** as custom states in Linear (Team Settings → Workflow)
5. Commit, push, then: `mise exec -- ./bin/symphony /path/to/your-repo/WORKFLOW.md`

For a fully owned setup, rely on this repo's README, `elixir/README.md`, and the bundled `symphony-setup` skill rather than any third-party walkthrough.

## License

[Apache License 2.0](LICENSE)
