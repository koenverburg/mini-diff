# quick-diff Justfile
# Build, test, and version management for the git-diff CLI tool.

# Default build
build:
    zig build --release-fast

# Debug build
debug:
    zig build

# Clean build artifacts
clean:
    rm -rf zig-out build .zig-cache bin

# Run the tool
run *args:
    zig build run -- {{args}}

# Test
test:
    zig build test

# Version management
# Print current version
version:
    @echo "Current version: $(VERSION)"

# Bump major version
major:
    @echo "Bumping major version..."
    @zig build run -- -V major

# Bump minor version
minor:
    @echo "Bumping minor version..."
    @zig build run -- -V minor

# Bump patch version
patch:
    @echo "Bumping patch version..."
    @zig build run -- -V patch

# Set version explicitly
set *ver:
    @echo "Setting version to {{ver}}..."
    @zig build run -- -V set {{ver}}

# Install
install:
    zig build install

# Uninstall
uninstall:
    zig build uninstall

# Format code
fmt:
    zig fmt src/

# Check formatting
fmt-check:
    zig fmt --check src/
