# minidiff

`minidiff` is a small terminal UI that shows the state of the current Git working tree at a glance. It polls `git status`, summarizes changed files, and displays addition/removal counts for each file.

## Features

- Live-refreshing working tree view in an alternate terminal screen
- Raw-mode keyboard input; press `q` or `Ctrl+C` to quit
- Header showing the repository folder, current branch, and aggregate `+ ~ -` stats
- Per-file Git status and line changes
- Color-coded statuses:
  - green: staged
  - yellow: modified in the working tree
  - red: untracked, deleted, or unmerged
  - dim: unchanged/other
- Collapses noisy folders when there are more than 20 changed files in total and more than 7 files in one folder, e.g. `data/binance/...(9 files)`
- Single small Zig binary with no third-party dependencies

## Requirements

- [Zig](https://ziglang.org/) 0.16.0
- Git
- [just](https://github.com/casey/just) (optional, but recommended)
- A terminal that supports ANSI escape codes

## Build

With `just`:

```sh
just build          # ReleaseFast build
just debug          # Debug build
```

Or directly with Zig:

```sh
zig build -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/minidiff`.

```sh
./zig-out/bin/minidiff
```

Clean build artifacts with:

```sh
just clean
```

Install to `~/.local/bin`:

```sh
just install
just uninstall
```

## Usage

```text
minidiff [-s SECONDS] [-h]
  -s, --interval SECONDS  Refresh interval (default: 1)
  -h, --help              Show this help
  q                       Quit
```

Run it from inside a Git repository. Press `q` or `Ctrl+C` to quit and restore the terminal.

## Example output

```text
─ minidiff · main · +25 ~1 -1────────
   M data/binance/...(9 files) +9
   M data/foo/f1 +1 -1
   M root1 +2
```

The status columns follow `git status --porcelain=v1` (index and worktree status). Files are grouped by folder only when the total change count exceeds 20 and a folder contains more than 7 files.

## Version management

The version lives in `src/version.zig`:

```sh
just version        # print the current version
just major          # 0.1.0 -> 1.0.0
just minor          # 0.1.0 -> 0.2.0
just patch          # 0.1.0 -> 0.1.1
just set 1.2.3      # set an explicit version
```

## Development

```sh
just fmt            # format Zig sources
just fmt-check      # verify formatting
just test           # run the Zig test step
```

CI runs on every push and pull request via `.github/workflows/ci.yml`. It checks formatting and performs Debug, ReleaseFast, and test builds with Zig 0.16.0.

## Project layout

```text
.
├── build.zig
├── justfile
├── src
│   ├── main.zig
│   └── version.zig
└── .github
    └── workflows
        └── ci.yml
```

- `src/main.zig` contains the CLI, Git polling, parsing, formatting, and rendering.
- `src/version.zig` is the single source of truth for the version string.
- `build.zig` defines the `minidiff` executable plus `run` and `test` steps.
