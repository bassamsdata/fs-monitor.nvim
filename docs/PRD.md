# Worktree Integration Feature

## Overview

Add a **worktree integration** to `fs-monitor.nvim` that allows users to quickly create a Git worktree containing the changes tracked in the current monitoring session. The workflow is:

1. Triggered via a keymap (e.g., `<leader>ww`).
2. The plugin checks whether the changes recorded in the current session are the **only** uncommitted changes in the repository.
3. If they are the only changes, a new worktree is created and the changes are copied into it.
4. If other untracked/uncommitted changes exist, the user is prompted to either:
   - **Cancel** the operation, or
   - **Include all** repository changes in the worktree.
   The user is then asked to provide a name for the new worktree.

## Implementation Tasks

- [x] **Define default keymaps**
  - Extend `lua/fs-monitor/config.lua` `ui.keymaps` with entries:
    - `create_worktree = { key = "<leader>ww", desc = "Create worktree from session changes" }`
    - Optionally, `delete_worktree = { key = "<leader>wd", desc = "Delete worktree" }`
  - Ensure the keys are user‑customisable via `setup()`.

- [x] **Create worktree module** (`lua/fs-monitor/worktree.lua`)
  - Export a function `create_worktree(session_id)`.
  - Use `vim.system` to run Git commands (asynchronous):
    - Verify the repository root (`git rev-parse --show-toplevel`).
    - Get the list of uncommitted changes (`git status --porcelain`).
    - Compare with the session's tracked changes (`session.changes`).
  - Prompt the user with `vim.ui.select` when extra changes are present.
  - Prompt for worktree name with `vim.ui.input`.
  - Create the worktree using `git worktree add <path> <branch>` (branch can be a temporary one based on the name).
  - Apply the session changes to the worktree by copying the changed files (using the plugin's internal file‑write utilities). This avoids creating a new commit or stash and aligns with the plugin's non‑destructive tracking model.
  - Notify the user on success/failure via `fs-monitor.utils.util.notify`.

- [x] **Expose command/subcommand**
  - Add a new subcommand `worktree` to the `:FSMonitor` command in `plugin/fs-monitor.lua`.
  - Usage: `:FSMonitor worktree <session_id>` (session id optional – defaults to the most recent active session).
  - Connect the subcommand to the function in the worktree module.

- [x] **Integrate keymap**
  - In the plugin's setup, after loading the config, register the keymaps with `vim.keymap.set` using the values from `config.ui.keymaps`.
  - The keymap should call the new subcommand, e.g., `vim.cmd('FSMonitor worktree ' .. session_id)`.

- [x] **Testing**
  - Add unit tests in `tests/test_worktree.lua` covering:
    - Detection of exclusive session changes.
    - Prompt handling when extra changes exist.
    - Creation of a worktree (mock `vim.fn.systemlist`).
    - Correct user notifications.
  - Use the existing test harness (MiniTest) to simulate a session with mocked Git output.

- [x] **Documentation (internal)**
  - Add comments in the new module describing the workflow.
  - Update the README `# Keymaps` section if it exists (optional, as per project policy).

- [x] **Styling**
  - Run `stylua .` to ensure the new code follows the project's 2‑space indentation rule.

## Notes & Edge Cases

- **Non‑Git repos**: If `git rev-parse` fails, the function should abort with a warning.
- **Worktree name collisions**: If a directory with the requested name already exists, append a numeric suffix or ask the user again.
- **Untracked files**: `git status --porcelain` includes untracked files (`??`). These should be considered when checking "only session changes".
- **Session without changes**: If the session has no recorded changes, inform the user and abort.
- **Error handling**: All Git command failures must be caught and presented to the user via `vim.notify` with appropriate log level.

---

*Implementation of this feature follows the plugin’s existing conventions for configuration, async handling, and user interaction.*