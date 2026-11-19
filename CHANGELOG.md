# Changelog

All notable changes to TaskBar are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-11-19

### Added

- **Links** tab: folders of bookmarks with a color and an icon; paste a link to add it.
- **Clipboard** tab: searchable copy history with pins. Secrets marked by password managers are
  never recorded, and the history can be turned off in Settings.
- **Git** tab: the repositories of your Claude Code sessions plus any you add, with branch,
  ahead/behind, pending changes, recent commits, branches and open pull requests (via `gh`).
- **Usage** view in Agents: Claude Code tokens, estimated cost at API list prices, cache hit rate,
  and the breakdown by model, project, session and day.
- System tab: **Devices** (battery of keyboards, mice and headphones, including Bluetooth LE devices
  through the GATT battery service), **Drives** (mounted volumes, open in Finder, eject) and
  **Ports** (listening TCP ports with their process, a likely service name, Open and Stop).
- Dictation language switch next to the microphone; with no explicit choice, dictation follows the
  first preferred language the speech engine supports.
- Self-test commands `--ports`, `--drives`, `--devices`, `--usage`, `--git` and `--render-live`.

### Changed

- The header fits eight tabs; ⌘1…⌘9 switch between them.

## [0.1.0] - 2026-11-18

First release.

### Added

- Menu bar popover that opens on hover, click or a global shortcut, with a pin and a rule that keeps
  it open while you are typing.
- Hierarchical tasks with notes, subtasks to any depth, priorities, `#tags` and drag-to-reorder.
- Free-standing notes and prompt drafts, with a Markdown preview.
- On-device voice dictation, and "Tidy up" / "Refine prompt" backed by Apple Intelligence or by
  Claude through the Claude Code CLI.
- Claude Code agent monitor: live status, recent conversation, focus-window, and optional hooks for
  instant "needs approval" alerts.
- Calendar tab reading the system calendars, with join buttons for video calls.
- System tab: CPU, memory, disk, battery, network, open apps, top processes and Docker containers.
- Search across tasks and notes, `taskbar://` URL scheme, launch at login.
- Headless self-test commands and a sample-data screenshot renderer.

[0.2.0]: https://github.com/thomazzi98/task-bar/releases/tag/v0.2.0
[0.1.0]: https://github.com/thomazzi98/task-bar/releases/tag/v0.1.0
