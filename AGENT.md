# AGENT.md

Guidance for AI coding agents working on `minidiff`.

## Project overview

`minidiff` is a dependency-free Zig 0.16.0 CLI that renders a live view of the current Git working tree. It shells out to Git, parses `git status --porcelain=v1 -z`, computes per-file line stats with `git diff --numstat`, and redraws the terminal on an interval.

## Prerequisites

- Zig 0.16.0
- Git
- `just` (optional; the Zig commands work without it)

## Essential commands

| Task | Command |
| --- | --- |
| Release build | `just build` or `zig build -Doptimize=ReleaseFast` |
| Debug build | `just debug` or `zig build` |
| Run | `just run` or `zig build run -- <args>` |
| Test step | `just test` or `zig build test` |
| Format | `just fmt` or `zig fmt src build.zig` |
| Check format | `just fmt-check` or `zig fmt --check src build.zig` |
| Clean | `just clean` |
| Print version | `just version` |
| Bump version | `just major`, `just minor`, `just patch`, `just set X.Y.Z` |

The executable is installed to `zig-out/bin/minidiff`.

## Verification before finishing

Run at minimum:

```sh
zig fmt --check src build.zig
zig build
zig build -Doptimize=ReleaseFast
zig build test
```

If `just` is available, also run `just build` and `just version`. Confirm the CLI starts and that `./zig-out/bin/minidiff --help` prints `minidiff v<version>`.

`zig build test` currently compiles/runs the test step; there is no dedicated test suite. Add tests when changing parsing, grouping, or formatting logic.

## Code layout

- `build.zig` — declares the `minidiff` executable and the `run`/`test` steps. Do not revert to the old empty build file or `zig build-exe`; the justfile and CI rely on `zig build`.
- `src/main.zig` — argument parsing, Git subprocesses, status parsing, stats, grouping, ANSI rendering, and the refresh loop.
- `src/version.zig` — single source of truth for the version string. `main.zig` imports it; never hardcode a second version.
- `justfile` — developer entry points, including version bumping.
- `.github/workflows/ci.yml` — CI for pushes and pull requests using Zig 0.16.0.

## Implementation notes

- This project uses Zig 0.16 `std.Io` APIs such as `std.Io.Dir.cwd()`, `std.process.spawn(io, ...)`, `std.Io.Reader`, `std.Io.File.stdout()`, and `std.Io.sleep`. Follow the existing API style when making changes.
- `main.zig` owns allocations from `parseStatus`; each `item.path` and the `items` slice are freed at the end of each refresh iteration. Keep new allocations balanced.
- `item_stats_list` is allocated per refresh to avoid running `git diff` twice per file. Reuse it when changing rendering.
- Folder collapsing thresholds are `merge_files_threshold` (20 total files) and `merge_folder_threshold` (7 files in one folder). Only collapse folders when the total change count is strictly greater than 20 and the folder count is strictly greater than 7.
- Header rendering in `writeHeaderLine` parses the plain header string into folder, branch, and stats segments so each can be colored independently. Preserve that structure and the terminal-width calculation when editing the header.
- Header stats are built as `+A ~C -R` with spaces between segments; `appendStatsColored` depends on those spaces. Do not remove them.
- Color/style constants are ANSI escape slices near the top of `main.zig`. Status colors come from `statusColor`.
- `Terminal.enter` puts stdin into raw mode, switches to the alternate screen, and hides the cursor. `Terminal.leave` restores the original termios settings and screen/cursor state via `defer`. Keep this cleanup path working when changing input or rendering.
- `waitForQuit` polls stdin for the refresh interval and returns true on `q`, `Q`, or Ctrl+C (`0x03`). `waitOrQuit` falls back to a normal sleep when stdin is not a TTY.
- ANSI colors and the clear-screen sequence are emitted unconditionally; alternate-screen/raw-mode handling only activates on a TTY. The tool is intended for interactive terminals.

## Behavior to preserve

- Default refresh interval: 1 second.
- `-s`/`--interval` accepts seconds; `-h`/`--help` prints usage and exits.
- `q`, `Q`, and Ctrl+C quit the TUI and restore the terminal.
- Running outside a Git repository prints an error and keeps polling.
- Files from the same folder collapse to `folder/...(N files)` using aggregated stats.
- The footer and bottom border were intentionally removed; do not reintroduce them without an explicit request.

## Common tasks

- Adding a flag: parse it in the argument loop in `main`, update the help text, and document it in `README.md`.
- Changing grouping: update the threshold constants and the grouping block in the print phase; keep README behavior in sync.
- Changing colors: update the ANSI constants, `statusColor`, and/or `writeHeaderLine`, then verify output in a temporary Git repository.
- Version changes: prefer the `just` recipes, which update `src/version.zig`, over editing by hand.

## Testing the TUI manually

Create a temporary repository with tracked files and modifications, run `minidiff` from inside it, and press `q` to exit:

```sh
mkdir -p /tmp/minidiff-test && cd /tmp/minidiff-test
git init
# create and commit files
/path/to/minidiff
```

For a non-interactive smoke test, feed `q` through a pseudo-terminal (macOS example):

```sh
printf 'q' | script -q /dev/null /path/to/minidiff
```

Use `--help` for a normal non-interactive smoke test. Do not commit generated `zig-out/`, `.zig-cache/`, or `bin/` contents; they are gitignored.
