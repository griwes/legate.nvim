# Plugin Repo Template

This template is the common source for new plugin repositories in this workspace.

## Goals

- keep the Apache-2.0 baseline consistent
- keep tests, CI, style rules, and basic plugin structure aligned
- reduce ad hoc drift across repositories

## Placeholder Tokens

- `legate.nvim`
- `legate.nvim`
- `acp`
- `Neovim-native ACP client focused on a single chat buffer and explicit terminal/session seams.`

## Expected Scaffold Flow

1. Copy this directory into the new plugin repo directory.
2. Rename placeholder directories and files containing `acp`.
3. Replace placeholder tokens in file contents.
4. Initialize the repo as its own git repository.
5. Verify the baseline before the first commit.

## Baseline Contents

- Apache-2.0 license
- Stylua configuration
- GitHub Actions CI
- top-level `tests/` directory
- `lazy.nvim`-friendly plugin layout
- minimal README and load test
