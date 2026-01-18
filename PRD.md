# Worktree Integration Feature

## Tasks

- [x] **Worktree pane**
  - Implement floating pane triggered by `gwt` with overlay behavior.
- [x] **Keymap conventions**
  - Add `g...` mappings (`gwt`, `gcc`) and expose config.
- [x] **UI for file selection**
  - Create component with selectable checkboxes for files/hunks.
- [x] **Inline commit message**
  - Provide textbox for commit message within UI.
- [x] **Commit actions**
  - Support "commit all" and "commit selected".
- [x] **Feedback UI**
  - Show success/error messages after commit.
- [x] **Testing**
  - Write unit/integration tests for pane toggle, selection, commit flow.
- [ ] **Documentation**
  - Update README with new keymaps and usage instructions.
- [x] **Styling**
  - Run `stylua .` to ensure the new code follows the project's 2‑space indentation rule.

## Notes & Edge Cases

- **Non‑Git repos**: If `git rev-parse` fails, the function should abort with a warning.
- **Worktree name collisions**: If a directory with the requested name already exists, append a numeric suffix or ask the user again.
- **Untracked files**: `git status --porcelain` includes untracked files (`??`). These should be considered when checking "only session changes".
- **Session without changes**: If the session has no recorded changes, inform the user and abort.
- **Error handling**: All Git command failures must be caught and presented to the user via `vim.notify` with appropriate log level.
