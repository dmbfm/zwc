// zwc -- A `wc` clone written in zig.
//
// TODO:
// - [ ] utf8 support
//
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const stdin = std.io.getStdIn().reader();

const WcConfig = struct {
    chars: bool = true,
    lines: bool = true,
    words: bool = true,
};

const WcResult = struct {
    num_chars: ?usize = null,
    num_lines: ?usize = null,
    num_words: ?usize = null,
};

const usage =
    \\usage: zwc [-clmw] [file ...]
    \\
;

fn wcFile(comptime buf_size: comptime_int, filename: []const u8, config: WcConfig) !WcResult {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    return wcFileHandle(buf_size, file.handle, config);
}

fn wcFileHandle(comptime buf_size: comptime_int, fileHandle: std.fs.File.Handle, config: WcConfig) !WcResult {
    var buf: [buf_size]u8 = undefined;

    if (!config.words and !config.lines) {
        var bytes: usize = 0;
        while (true) {
            var bytes_read = try std.os.read(fileHandle, &buf);
            if (bytes_read == 0) break;
            bytes += bytes_read;
        }

        return .{ .num_chars = bytes };
    }

    var num_chars: usize = 0;
    var num_lines: usize = 0;
    var num_words: usize = 0;
    var is_in_middle_of_word = false;

    while (true) {
        var bytes_read = try std.os.read(fileHandle, &buf);
        if (bytes_read == 0) break;

        num_chars += bytes_read;

        var ch: u8 = undefined;
        var cursor: usize = 0;
        var eat: bool = true;

        outer: while (true) {
            if (eat) {
                if (cursor >= bytes_read) break;
                ch = buf[cursor];
                cursor += 1;
            } else {
                eat = true;
            }

            if (ch == ' ') {
                if (is_in_middle_of_word) {
                    is_in_middle_of_word = false;
                }

                while (ch == ' ') {
                    if (cursor >= bytes_read) break :outer;
                    ch = buf[cursor];
                    cursor += 1;
                }

                eat = false;
                continue;
            }

            if (ch == '\n') {
                if (is_in_middle_of_word) {
                    is_in_middle_of_word = false;
                }
                num_lines += 1;
                continue;
            }

            if (is_in_middle_of_word) {
                num_words -= 1;
                is_in_middle_of_word = false;
            }

            while (true) {
                if (cursor >= bytes_read) {
                    is_in_middle_of_word = true;
                    num_words += 1;
                    break :outer;
                }

                ch = buf[cursor];
                cursor += 1;

                if (ch == ' ') {
                    num_words += 1;
                    break;
                } else if (ch == '\n') {
                    num_words += 1;
                    num_lines += 1;
                    break;
                }
            }
        }
    }

    return .{
        .num_chars = if (config.chars) num_chars else null,
        .num_lines = if (config.lines) num_lines else null,
        .num_words = if (config.words) num_words else null,
    };
}

fn printResult(result: WcResult, filename: ?[]const u8) !void {
    if (result.num_lines) |num_lines| {
        try stdout.print("    {}", .{num_lines});
    }

    if (result.num_words) |num_words| {
        try stdout.print("    {}", .{num_words});
    }

    if (result.num_chars) |num_chars| {
        try stdout.print("    {}", .{num_chars});
    }

    if (filename) |_filename| {
        try stdout.print(" {s}\n", .{_filename});
    } else {
        try stdout.writeByte('\n');
    }
}

pub fn main() !void {
    var arena_instance = ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    const arena = arena_instance.allocator();

    var args = try std.process.argsAlloc(arena);

    var config = WcConfig{};

    // var filenames: [args.len - 1][:0]u8 = undefined;
    var filenames = try arena.alloc([:0]u8, args.len - 1);
    var num_files: usize = 0;

    var flag_c: bool = false;
    var flag_l: bool = false;
    var flag_m: bool = false;
    var flag_w: bool = false;

    var cursor: usize = 1;
    while (cursor < args.len) {
        var arg = args[cursor];
        cursor += 1;

        if (arg.len == 0) {
            continue;
        }

        if (arg[0] == '-') {
            // Fail if no flag
            if (arg.len == 1) {
                try stdout.writeAll(usage);
                std.os.exit(0);
            }

            for (arg[1..]) |ch| {
                switch (ch) {
                    'c' => {
                        flag_c = true;
                    },
                    'l' => {
                        flag_l = true;
                    },
                    'm' => {
                        flag_m = true;
                    },
                    'w' => {
                        flag_w = true;
                    },
                    else => {
                        try stderr.print("zwc: illegal option -- {c}\n", .{ch});
                        try stdout.writeAll(usage);
                        std.os.exit(0);
                    },
                }
            }
        } else {
            filenames[num_files] = arg;
            num_files += 1;
        }
    }

    if (!flag_c and !flag_l and !flag_w and !flag_m) {
        flag_c = true;
        flag_l = true;
        flag_w = true;
    }

    config.chars = flag_c or flag_m;
    config.lines = flag_l;
    config.words = flag_w;

    var i: usize = 0;

    while (i < num_files) : (i += 1) {
        var result: ?WcResult = wcFile(1024, filenames[i], config) catch |err|
            blk: {
            switch (err) {
                std.fs.File.OpenError.FileNotFound => {
                    try stderr.print("zwc: {s}: open: no such file or directory\n", .{filenames[i]});
                },
                else => {},
            }

            break :blk null;
        };

        if (result) |_result| {
            try printResult(_result, filenames[i]);
        }
    }

    if (num_files == 0) {
        var result = try wcFileHandle(1024, std.io.getStdIn().handle, config);
        try printResult(result, null);
    }
}
