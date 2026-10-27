const std = @import("std");
const Allocator = std.mem.Allocator;

const Version = struct { major: u32, minor: u32, patch: u32 };
const version: Version = .{ .major = 0, .minor = 1, .patch = 0 };

const StatusItem = struct {
    index: u8,
    worktree: u8,
    path: []u8,
};

const LineStats = struct {
    added: usize,
    removed: usize,
};

const hbar: []const u8 = "\xe2\x94\x80"; // U+2500, 3 bytes
const prefix: []const u8 = "\xe2\x94\x80 "; // "─ " = 4 bytes
const separator: []const u8 = " \xc2\xb7 "; // " · "

const ansi_reset: []const u8 = "\x1b[0m";
const ansi_dim: []const u8 = "\x1b[2m";
const ansi_red: []const u8 = "\x1b[31m";
const ansi_green: []const u8 = "\x1b[32m";
const ansi_yellow: []const u8 = "\x1b[33m";
const ansi_magenta: []const u8 = "\x1b[1;35m";
const ansi_bold_cyan: []const u8 = "\x1b[1;36m";

const merge_files_threshold: usize = 20;
const merge_folder_threshold: usize = 7;

fn statusColor(item: StatusItem) []const u8 {
    if (item.index == '?' or item.index == 'U' or item.worktree == 'U') return ansi_red;
    if (item.index == 'D' or item.worktree == 'D') return ansi_red;
    if (item.index != ' ' and item.index != '?') return ansi_green;
    if (item.worktree != ' ') return ansi_yellow;
    return ansi_dim;
}

fn formatLine(buf: []u8, item: StatusItem, stats: LineStats) []u8 {
    var offset: usize = 0;

    const printed = std.fmt.bufPrint(buf[offset..], "  {s}{c}{c}{s} {s}", .{
        statusColor(item),
        item.index,
        item.worktree,
        ansi_reset,
        item.path,
    }) catch unreachable;
    offset += printed.len;

    if (stats.added > 0) {
        const extra = std.fmt.bufPrint(buf[offset..], " {s}+{d}{s}", .{
            ansi_green, stats.added, ansi_reset,
        }) catch unreachable;
        offset += extra.len;
    }
    if (stats.removed > 0) {
        const extra = std.fmt.bufPrint(buf[offset..], " {s}-{d}{s}", .{
            ansi_red, stats.removed, ansi_reset,
        }) catch unreachable;
        offset += extra.len;
    }

    buf[offset] = '\n';
    offset += 1;

    return buf[0..offset];
}

fn folderOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[0..idx];
    return "";
}

fn formatFolderLine(buf: []u8, item: StatusItem, folder: []const u8, count: usize, stats: LineStats) []u8 {
    var offset: usize = 0;

    const printed = std.fmt.bufPrint(buf[offset..], "  {s}{c}{c}{s} {s}{s}{s}{s}/...({d} files){s}", .{
        statusColor(item),
        item.index,
        item.worktree,
        ansi_reset,
        ansi_bold_cyan,
        folder,
        ansi_reset,
        ansi_dim,
        count,
        ansi_reset,
    }) catch unreachable;
    offset += printed.len;

    if (stats.added > 0) {
        const extra = std.fmt.bufPrint(buf[offset..], " {s}+{d}{s}", .{
            ansi_green, stats.added, ansi_reset,
        }) catch unreachable;
        offset += extra.len;
    }
    if (stats.removed > 0) {
        const extra = std.fmt.bufPrint(buf[offset..], " {s}-{d}{s}", .{
            ansi_red, stats.removed, ansi_reset,
        }) catch unreachable;
        offset += extra.len;
    }

    buf[offset] = '\n';
    offset += 1;

    return buf[0..offset];
}

fn getFolderName(allocator: Allocator, io: std.Io) []const u8 {
    const dir = std.Io.Dir.cwd();
    const cwd = dir.realPathFileAlloc(io, ".", allocator) catch return "";
    defer allocator.free(cwd);

    var i: usize = cwd.len;
    while (i > 0) : (i -= 1) {
        if (cwd[i - 1] == '/') {
            return allocator.dupe(u8, cwd[i..cwd.len]) catch cwd[i..cwd.len];
        }
    }
    return allocator.dupe(u8, cwd) catch cwd;
}

// Get terminal width using ioctl (TIOCGWINSZ).
// Returns 30 on failure (pipe, non-TTY).
fn getTerminalWidth() u16 {
    var wsz: std.posix.winsize = undefined;
    const TIOCGWINSZ: u32 = 0x40087468;
    const rc: i32 = std.c.ioctl(1, TIOCGWINSZ, @intFromPtr(&wsz));
    if (rc == 0 and wsz.col > 0) return wsz.col;
    return 30;
}

fn getBranchName(allocator: Allocator, io: std.Io) []const u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "branch", "--show-current" },
        .stdout = .pipe,
    }) catch return "";

    if (child.stdout) |stdout| {
        var buf: [256]u8 = undefined;
        var reader = stdout.reader(io, &buf);
        var output = std.ArrayList(u8).initCapacity(allocator, 256) catch return "";
        defer output.deinit(allocator);

        std.Io.Reader.appendRemainingUnlimited(&reader.interface, allocator, &output) catch return "";
        _ = child.wait(io) catch {};

        const result = output.toOwnedSlice(allocator) catch return "";
        const trimmed = std.mem.trim(u8, result, " *\n");
        return allocator.dupe(u8, trimmed) catch return "";
    }

    _ = child.wait(io) catch {};
    return "";
}

fn getStatus(allocator: Allocator, io: std.Io) []const u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "status", "--porcelain=v1", "-z" },
        .stdout = .pipe,
    }) catch return "";

    if (child.stdout) |stdout| {
        var buf: [4096]u8 = undefined;
        var reader = stdout.reader(io, &buf);
        var output = std.ArrayList(u8).initCapacity(allocator, 4096) catch return "";
        defer output.deinit(allocator);

        std.Io.Reader.appendRemainingUnlimited(&reader.interface, allocator, &output) catch return "";
        _ = child.wait(io) catch {};
        return output.toOwnedSlice(allocator) catch return "";
    }

    _ = child.wait(io) catch {};
    return "";
}

fn parseStatus(allocator: Allocator, raw: []const u8) ![]StatusItem {
    var list = try std.ArrayList(StatusItem).initCapacity(allocator, 64);

    var pos: usize = 0;
    while (pos < raw.len) {
        if (pos + 3 >= raw.len) break;

        const index_char = raw[pos];
        const worktree_char = raw[pos + 1];
        const space = raw[pos + 2];
        if (space != ' ') break;

        var end = pos + 3;
        while (end < raw.len and raw[end] != 0) end += 1;

        if (end >= raw.len) break;

        var path = try allocator.dupe(u8, raw[pos + 3 .. end]);

        if (index_char == 'R' or index_char == 'C') {
            const arrow = std.mem.indexOf(u8, path, " -> ") orelse {
                allocator.free(path);
                pos = end + 1;
                continue;
            };
            allocator.free(path);
            path = try allocator.dupe(u8, raw[end + 1 + arrow + 4 .. raw.len]);
            path = @as([]u8, @constCast(std.mem.trim(u8, path, "\n")));
        }

        try list.append(allocator, StatusItem{
            .index = index_char,
            .worktree = worktree_char,
            .path = path,
        });

        pos = end + 1;
    }

    return try list.toOwnedSlice(allocator);
}

fn getLineChanges(allocator: Allocator, path: []const u8, io: std.Io) LineStats {
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "diff", "--numstat", "--", path },
        .stdout = .pipe,
    }) catch return LineStats{ .added = 0, .removed = 0 };

    if (child.stdout) |stdout| {
        var buf: [4096]u8 = undefined;
        var reader = stdout.reader(io, &buf);
        var output = std.ArrayList(u8).initCapacity(allocator, 4096) catch return LineStats{ .added = 0, .removed = 0 };
        defer output.deinit(allocator);

        std.Io.Reader.appendRemainingUnlimited(&reader.interface, allocator, &output) catch {};
        _ = child.wait(io) catch {};

        const content = output.toOwnedSlice(allocator) catch return LineStats{ .added = 0, .removed = 0 };

        var added: usize = 0;
        var removed: usize = 0;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, '\t');
            const a = parts.next() orelse continue;
            const r = parts.next() orelse continue;

            const added_num = std.fmt.parseInt(usize, a, 10) catch 0;
            const removed_num = std.fmt.parseInt(usize, r, 10) catch 0;

            if (added_num > 0) added += added_num;
            if (removed_num > 0) removed += removed_num;
        }

        return .{ .added = added, .removed = removed };
    }

    _ = child.wait(io) catch {};
    return LineStats{ .added = 0, .removed = 0 };
}

// Write a buffer to stdout using Zig 0.16.0 API
fn writeOut(io: std.Io, buf: []const u8) !void {
    const file = std.Io.File.stdout();
    try file.writeStreamingAll(io, buf);
}

// Fit "folder · branch · stats" into max_content bytes, truncating the branch
// (and dropping the stats if there is no room) so the header always fits.
fn truncateBranch(buf: []u8, folder: []const u8, branch: []const u8, stats: []const u8, stats_len: usize, max_content: usize) usize {
    const sep = separator;
    const stats_slice = stats[0..stats_len];
    const limit = @min(max_content, buf.len);

    var out: usize = 0;

    // Folder is kept verbatim unless it alone is too wide.
    const folder_len = @min(folder.len, limit);
    @memcpy(buf[out..][0..folder_len], folder[0..folder_len]);
    out += folder_len;
    if (folder_len < folder.len) return out;

    const stats_seg_len: usize = if (stats_slice.len > 0) sep.len + stats_slice.len else 0;

    if (branch.len > 0) {
        if (out + sep.len + stats_seg_len >= limit) return out;

        @memcpy(buf[out..][0..sep.len], sep);
        out += sep.len;

        const avail = limit - out - stats_seg_len;
        if (branch.len <= avail) {
            @memcpy(buf[out..][0..branch.len], branch);
            out += branch.len;
        } else if (avail > "…".len) {
            const take = avail - "…".len;
            @memcpy(buf[out..][0..take], branch[0..take]);
            out += take;
            @memcpy(buf[out..][0.."…".len], "…");
            out += "…".len;
        } else {
            out -= sep.len;
        }
    }

    if (stats_slice.len > 0 and out + sep.len + stats_slice.len <= limit) {
        @memcpy(buf[out..][0..sep.len], sep);
        out += sep.len;
        @memcpy(buf[out..][0..stats_slice.len], stats_slice);
        out += stats_slice.len;
    }

    return out;
}

fn appendStr(buf: []u8, offset: *usize, s: []const u8) void {
    @memcpy(buf[offset.*..][0..s.len], s);
    offset.* += s.len;
}

fn appendStatsColored(buf: []u8, offset: *usize, stats: []const u8) void {
    var it = std.mem.splitScalar(u8, stats, ' ');
    var first = true;
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (!first) appendStr(buf, offset, " ");
        first = false;

        const color = switch (token[0]) {
            '+' => ansi_green,
            '~' => ansi_yellow,
            '-' => ansi_red,
            else => ansi_dim,
        };
        appendStr(buf, offset, color);
        appendStr(buf, offset, token);
        appendStr(buf, offset, ansi_reset);
    }
}

// Write header line: dim "─ " prefix + colored content + dim "─" fill + "\n".
// Folder is cyan, branch magenta, and stats are green/yellow/red.
// The returned slice contains ANSI escape codes, so it is longer than `width`.
fn writeHeaderLine(buf: []u8, content: []const u8, folder: []const u8, stats: []const u8, stats_len: usize, width: usize) usize {
    var offset: usize = 0;
    var used: usize = 0;

    appendStr(buf, &offset, ansi_dim);
    appendStr(buf, &offset, prefix);
    used += 2;
    appendStr(buf, &offset, ansi_reset);

    const folder_len = @min(folder.len, content.len);
    appendStr(buf, &offset, ansi_bold_cyan);
    appendStr(buf, &offset, content[0..folder_len]);
    appendStr(buf, &offset, ansi_reset);
    used += folder_len;

    const rest = content[folder_len..];
    if (rest.len > 0 and std.mem.startsWith(u8, rest, separator)) {
        const body = rest[separator.len..];

        const stats_slice = stats[0..stats_len];
        var branch = body;
        var has_stats = false;

        if (stats_slice.len > 0) {
            const stats_seg_len = separator.len + stats_slice.len;
            if (body.len == stats_slice.len and std.mem.eql(u8, body, stats_slice)) {
                branch = body[0..0];
                has_stats = true;
            } else if (body.len >= stats_seg_len) {
                const tail = body[body.len - stats_seg_len ..];
                if (std.mem.eql(u8, tail[0..separator.len], separator) and
                    std.mem.eql(u8, tail[separator.len..], stats_slice))
                {
                    branch = body[0 .. body.len - stats_seg_len];
                    has_stats = true;
                }
            }
        }

        if (branch.len > 0) {
            appendStr(buf, &offset, ansi_dim);
            appendStr(buf, &offset, separator);
            appendStr(buf, &offset, ansi_reset);
            used += 3;

            appendStr(buf, &offset, ansi_magenta);
            appendStr(buf, &offset, branch);
            appendStr(buf, &offset, ansi_reset);
            used += branch.len;

            if (has_stats) {
                appendStr(buf, &offset, ansi_dim);
                appendStr(buf, &offset, separator);
                appendStr(buf, &offset, ansi_reset);
                used += 3;

                appendStatsColored(buf, &offset, stats_slice);
                used += stats_slice.len;
            }
        } else if (has_stats) {
            appendStr(buf, &offset, ansi_dim);
            appendStr(buf, &offset, separator);
            appendStr(buf, &offset, ansi_reset);
            used += 3;

            appendStatsColored(buf, &offset, stats_slice);
            used += stats_slice.len;
        } else if (body.len > 0) {
            appendStr(buf, &offset, ansi_dim);
            appendStr(buf, &offset, rest);
            appendStr(buf, &offset, ansi_reset);
            used += 3 + body.len;
        }
    } else {
        appendStr(buf, &offset, ansi_bold_cyan);
        appendStr(buf, &offset, rest);
        appendStr(buf, &offset, ansi_reset);
        used += rest.len;
    }

    appendStr(buf, &offset, ansi_dim);

    const line_width = @max(width, 6);
    while (used < line_width and offset + hbar.len + 1 + ansi_reset.len <= buf.len) : (used += 1) {
        appendStr(buf, &offset, hbar);
    }

    appendStr(buf, &offset, ansi_reset);

    buf[offset] = '\n';
    offset += 1;

    return offset;
}

// Zig 0.16.0 entry point
pub fn main(init: std.process.Init) !void {
    const args: []const [*:0]const u8 = init.minimal.args.vector;
    const io = init.io;

    var interval_ms: u32 = 1000;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            var ver_buf: [32]u8 = undefined;
            const ver = std.fmt.bufPrint(&ver_buf, "{}.{}.{}", .{ version.major, version.minor, version.patch }) catch unreachable;

            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "quick-diff v{s}\n", .{ver}) catch unreachable;
            writeOut(io, msg) catch {};

            const msg2 = std.fmt.bufPrint(&buf, "Usage: quick-diff [-s SECONDS] [-h]\n", .{}) catch unreachable;
            writeOut(io, msg2) catch {};

            const msg3 = std.fmt.bufPrint(&buf, "  -s, --interval SECONDS  Refresh interval (default: 1)\n", .{}) catch unreachable;
            writeOut(io, msg3) catch {};

            const msg4 = std.fmt.bufPrint(&buf, "  -h, --help              Show this help\n", .{}) catch unreachable;

            writeOut(io, msg4) catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--interval")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("missing value for -s\n", .{});
                return;
            }
            interval_ms = std.fmt.parseInt(u32, std.mem.sliceTo(args[i], 0), 10) catch 1000;
            if (interval_ms < 100) interval_ms = 100;
            interval_ms *= 1000;
        }
    }

    const allocator = init.gpa;

    const folder = getFolderName(allocator, io);
    defer allocator.free(folder);

    const branch = getBranchName(allocator, io);
    defer allocator.free(branch);

    var line_buf: [512]u8 = undefined;
    var header_buf: [1024]u8 = undefined;

    while (true) {
        // Clear screen for TTY
        const clear_buf: []const u8 = "\x1b[2J\x1b[H";
        writeOut(io, clear_buf) catch {};

        const status_raw = getStatus(allocator, io);

        // If not in a git repo, show error
        if (status_raw.len == 0 and branch.len == 0) {
            const msg = "not a git repository\n";
            writeOut(io, msg) catch {};
            std.Io.sleep(io, std.Io.Duration.fromNanoseconds(1 * std.time.ns_per_s), std.Io.Clock.awake) catch {};
            continue;
        }

        const items = parseStatus(allocator, status_raw) catch {
            allocator.free(status_raw);
            continue;
        };

        // Compute stats for all items first (no printing).
        var total_added: usize = 0;
        var total_removed: usize = 0;
        var total_changed: usize = 0;

        const item_stats_list = try allocator.alloc(LineStats, items.len);
        defer allocator.free(item_stats_list);

        for (items, 0..) |item, idx| {
            const item_stats = switch (item.path[0]) {
                '?' => LineStats{ .added = 0, .removed = 0 },
                else => getLineChanges(allocator, item.path, io),
            };
            item_stats_list[idx] = item_stats;

            total_added += item_stats.added;
            total_removed += item_stats.removed;
            if (item_stats.added > 0 and item_stats.removed > 0) {
                if (item_stats.added < item_stats.removed) {
                    total_changed += item_stats.added;
                } else {
                    total_changed += item_stats.removed;
                }
            }
        }

        // Build stats text: "+A ~C -R"
        var stats_buf: [64]u8 = undefined;
        var stats_len: usize = 0;
        var num_buf: [16]u8 = undefined;
        if (total_added > 0) {
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{total_added}) catch unreachable;
            if (stats_len > 0) {
                stats_buf[stats_len] = ' ';
                stats_len += 1;
            }
            stats_buf[stats_len] = '+';
            stats_len += 1;
            var n = s;
            while (n.len > 0) : (n = n[1..]) {
                stats_buf[stats_len] = n[0];
                stats_len += 1;
            }
        }
        if (total_changed > 0) {
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{total_changed}) catch unreachable;
            if (stats_len > 0) {
                stats_buf[stats_len] = ' ';
                stats_len += 1;
            }
            stats_buf[stats_len] = '~';
            stats_len += 1;
            var n = s;
            while (n.len > 0) : (n = n[1..]) {
                stats_buf[stats_len] = n[0];
                stats_len += 1;
            }
        }
        if (total_removed > 0) {
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{total_removed}) catch unreachable;
            if (stats_len > 0) {
                stats_buf[stats_len] = ' ';
                stats_len += 1;
            }
            stats_buf[stats_len] = '-';
            stats_len += 1;
            var n = s;
            while (n.len > 0) : (n = n[1..]) {
                stats_buf[stats_len] = n[0];
                stats_len += 1;
            }
        }
        const has_stats = stats_len > 0;

        // Build content: "folder · branch · +A ~C -R"
        var content_buf: [256]u8 = undefined;
        var content_len: usize = 0;

        var fp = folder;
        while (fp.len > 0) : (fp = fp[1..]) {
            content_buf[content_len] = fp[0];
            content_len += 1;
        }

        if (branch.len > 0 and has_stats) {
            std.mem.copyForwards(u8, content_buf[content_len..], separator);
            content_len += separator.len;

            var b = branch;
            while (b.len > 0) : (b = b[1..]) {
                content_buf[content_len] = b[0];
                content_len += 1;
            }
            std.mem.copyForwards(u8, content_buf[content_len..], separator);
            content_len += separator.len;

            var s = stats_buf[0..stats_len];
            while (s.len > 0) : (s = s[1..]) {
                content_buf[content_len] = s[0];
                content_len += 1;
            }
        } else if (branch.len > 0) {
            std.mem.copyForwards(u8, content_buf[content_len..], separator);
            content_len += separator.len;

            var b = branch;
            while (b.len > 0) : (b = b[1..]) {
                content_buf[content_len] = b[0];
                content_len += 1;
            }
        } else if (has_stats) {
            std.mem.copyForwards(u8, content_buf[content_len..], separator);
            content_len += separator.len;

            var s = stats_buf[0..stats_len];
            while (s.len > 0) : (s = s[1..]) {
                content_buf[content_len] = s[0];
                content_len += 1;
            }
        }

        // Get terminal width and compute truncation.
        const term_width = getTerminalWidth();
        const max_content = if (term_width > 4) term_width - 4 else 23;
        const header_content_len = if (content_len <= max_content) content_len else truncateBranch(
            &content_buf,
            folder,
            branch,
            &stats_buf,
            stats_len,
            max_content,
        );
        const header_len = writeHeaderLine(&header_buf, content_buf[0..header_content_len], folder, &stats_buf, stats_len, term_width);
        writeOut(io, header_buf[0..header_len]) catch {};

        // Print file lines (second pass).
        if (items.len > merge_files_threshold) {
            const handled = try allocator.alloc(bool, items.len);
            defer allocator.free(handled);
            @memset(handled, false);

            for (items, 0..) |item, idx| {
                if (handled[idx]) continue;

                const dir = folderOf(item.path);
                var count: usize = 0;
                var folder_stats = LineStats{ .added = 0, .removed = 0 };
                for (items, 0..) |other, other_idx| {
                    if (handled[other_idx]) continue;
                    if (!std.mem.eql(u8, folderOf(other.path), dir)) continue;

                    count += 1;
                    folder_stats.added += item_stats_list[other_idx].added;
                    folder_stats.removed += item_stats_list[other_idx].removed;
                }

                if (dir.len > 0 and count > merge_folder_threshold) {
                    for (items, 0..) |other, other_idx| {
                        if (!handled[other_idx] and std.mem.eql(u8, folderOf(other.path), dir)) {
                            handled[other_idx] = true;
                        }
                    }
                    const line = formatFolderLine(&line_buf, item, dir, count, folder_stats);
                    writeOut(io, line) catch {};
                } else {
                    handled[idx] = true;
                    const line = formatLine(&line_buf, item, item_stats_list[idx]);
                    writeOut(io, line) catch {};
                }
            }
        } else {
            for (items, 0..) |item, idx| {
                const line = formatLine(&line_buf, item, item_stats_list[idx]);
                writeOut(io, line) catch {};
            }
        }

        allocator.free(status_raw);
        for (items) |item| allocator.free(item.path);
        allocator.free(items);

        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@as(i96, @intCast(@as(u64, interval_ms) * std.time.ns_per_ms))), std.Io.Clock.awake) catch {};
    }
}
