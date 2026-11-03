# minidiff Justfile
# Build, test, and version management for the minidiff CLI.

# Default build (ReleaseFast)
build optimize="ReleaseFast":
    zig build -Doptimize={{optimize}}

# Debug build
debug:
    zig build

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache bin

# Run the tool
run *args:
    zig build run -- {{args}}

# Test
test:
    zig build test

# Print the current version
version:
    @sed -n 's/.*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' src/version.zig | head -n1

# Bump major version
major:
    @just _bump major

# Bump minor version
minor:
    @just _bump minor

# Bump patch version
patch:
    @just _bump patch

# Set version explicitly, e.g. `just set 1.2.3`
set ver:
    @just _bump set {{ver}}

_bump mode value="":
    #!/usr/bin/env bash
    set -euo pipefail

    current=$(sed -n 's/.*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' src/version.zig | head -n1)
    if [ -z "$current" ]; then
        echo "could not read version from src/version.zig" >&2
        exit 1
    fi

    IFS=. read -r major minor patch <<< "$current"

    case "{{mode}}" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        set) IFS=. read -r major minor patch <<< "{{value}}" ;;
        *) echo "unknown version bump: {{mode}}" >&2; exit 1 ;;
    esac

    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]]; then
        echo "version must be MAJOR.MINOR.PATCH" >&2
        exit 1
    fi

    new="$major.$minor.$patch"
    printf 'pub const version = "%s";\n' "$new" > src/version.zig
    echo "version: $current -> $new"

# Install to ~/.local
install optimize="ReleaseFast":
    zig build -Doptimize={{optimize}} --prefix "$HOME/.local"

# Uninstall from ~/.local
uninstall:
    rm -f "$HOME/.local/bin/minidiff"

# Format code
fmt:
    zig fmt src build.zig

# Check formatting
fmt-check:
    zig fmt --check src build.zig
