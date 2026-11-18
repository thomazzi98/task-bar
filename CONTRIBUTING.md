# Contributing to TaskBar

Thanks for taking the time. Bug reports, ideas and pull requests are all welcome.

## Getting started

```sh
git clone https://github.com/thomazzi98/task-bar.git
cd task-bar
make test    # should pass in about a second
make run     # builds dist/TaskBar.app and launches it
```

You need macOS 14 or later and the Swift 6.2 toolchain. There is no Xcode project and no dependency
to fetch.

To experiment without touching your own tasks and notes, run against a scratch folder:

```sh
TASKBAR_DATA_DIR=/tmp/taskbar-playground dist/TaskBar.app/Contents/MacOS/TaskBar
```

## What a good change looks like

TaskBar has two goals that every change is weighed against: **stay light** and **stay simple to use**.

- **Logic goes in `TaskBarCore`, with tests.** The core module has no UI and no AppKit, which is what
  keeps it testable. If you find yourself wanting to test something in the app target, the logic
  probably belongs in the core.
- **No work while the popover is closed.** Prefer events (file-system notifications, hooks,
  observers) to timers. If something must be sampled, sample it only while it is on screen, and say
  in the pull request what it costs. `top -pid $(pgrep -x TaskBar)` is enough to check.
- **No new dependencies.** System frameworks only. If a feature seems to need a library, open an
  issue first so we can talk about it.
- **No new permissions at launch.** A permission is requested when the user first uses the feature
  that needs it, with a clear reason.
- **Builds without warnings.** CI compiles with warnings treated as errors, under Swift 6 strict
  concurrency.
- **Comments explain why, not what.** Especially for anything that works around platform behaviour.

## Checking UI changes

`make screenshots` renders every screen with sample data, in light and dark, into `docs/screenshots`.
It is the quickest way to review a layout change, and the README uses those images, so commit them
when a screen changes.

## Reporting a bug

Please include your macOS version and, when relevant, the output of the matching self-test command:

```sh
TaskBar=/Applications/TaskBar.app/Contents/MacOS/TaskBar
$TaskBar --agents     # problems with the Claude Code tab
$TaskBar --system     # problems with the System tab or Docker
$TaskBar --calendar   # problems with the Calendar tab
```

These print project names and conversation titles, so read the output before posting it.

## Commit messages

Short imperative subject line ("Add drag-to-reorder for subtasks"), then a body explaining the reason
for the change when it is not obvious.

By contributing you agree that your work is released under the [MIT License](LICENSE).
