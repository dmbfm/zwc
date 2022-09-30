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
    bytes: bool = true,
    lines: bool = true,
    words: bool = true,
};

const WcResult = struct {
    num_chars: ?usize = null,
    num_bytes: ?usize = null,
    num_lines: ?usize = null,
    num_words: ?usize = null,
};

const usage =
    \\usage: zwc [-clmw] [file ...]
    \\
;

fn iswspace(ch: u8) bool {
    switch (ch) {
        ' ', 0x0c, 0x0a, 0x0d, 0x09, 0x0b => return true,
        else => return false,
    }
}

fn wcFile(comptime buf_size: comptime_int, filename: []const u8, config: WcConfig) !WcResult {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    return wcFileHandle(buf_size, file.handle, config);
}

fn wcFileHandle(comptime buf_size: comptime_int, fileHandle: std.fs.File.Handle, config: WcConfig) !WcResult {
    var buf: [buf_size]u8 = undefined;

    if (config.bytes and !config.words and !config.lines and !config.chars) {
        var bytes: usize = 0;
        while (true) {
            var bytes_read = try std.os.read(fileHandle, &buf);
            if (bytes_read == 0) break;
            bytes += bytes_read;
        }

        return .{ .num_bytes = bytes };
    }

    var num_bytes: usize = 0;
    var num_chars: usize = 0;
    var num_lines: usize = 0;
    var num_words: usize = 0;
    var is_in_middle_of_word = false;
    var is_in_middle_of_char = false;
    var char_remaining_size: usize = 0;

    while (true) {
        var bytes_read = try std.os.read(fileHandle, &buf);
        if (bytes_read == 0) break;

        num_bytes += bytes_read;

        var ch: u8 = undefined;
        var cursor: usize = char_remaining_size;
        var eat: bool = true;

        char_remaining_size = 0;

        outer: while (true) {
            if (eat) {
                if (cursor >= bytes_read) break;
                ch = buf[cursor];
                cursor += characterLenUtf8(ch);
            } else {
                eat = true;
            }

            if (iswspace(ch)) {
                if (is_in_middle_of_word) {
                    is_in_middle_of_word = false;
                }

                while (iswspace(ch)) {
                    num_chars += 1;
                    if (cursor >= bytes_read) break :outer;
                    ch = buf[cursor];
                    cursor += characterLenUtf8(ch);
                }

                eat = false;
                continue;
            }

            if (ch == '\n') {
                if (is_in_middle_of_word) {
                    is_in_middle_of_word = false;
                }
                num_lines += 1;
                num_chars += 1;
                continue;
            }

            if (is_in_middle_of_word) {
                num_words -= 1;
                is_in_middle_of_word = false;
            }

            if (is_in_middle_of_char) {
                cursor += char_remaining_size - 1;
                char_remaining_size = 0;
                is_in_middle_of_char = false;

                if (cursor >= bytes_read) {
                    break :outer;
                }
            }

            while (true) {
                num_chars += 1;
                // var char_len = characterLenUtf8(ch);
                // cursor += (char_len - 1);

                if (cursor >= bytes_read) {
                    char_remaining_size = cursor - bytes_read;
                    is_in_middle_of_word = true;
                    num_words += 1;
                    break :outer;
                }

                ch = buf[cursor];
                cursor += characterLenUtf8(ch);

                if (iswspace(ch)) {
                    num_words += 1;
                    num_chars += 1;
                    break;
                } else if (ch == '\n') {
                    num_words += 1;
                    num_lines += 1;
                    num_chars += 1;
                    break;
                }
            }
        }
    }

    return .{
        .num_chars = if (config.chars) num_chars else null,
        .num_bytes = if (config.bytes) num_bytes else null,
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

    if (result.num_bytes) |num_bytes| {
        try stdout.print("    {}", .{num_bytes});
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

    config.bytes = flag_c and !flag_m;
    config.chars = flag_m;
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

const wchar = u32;

fn iswspace2(codepoint: u21) bool {
    switch (codepoint) {
        ' ',
        '\t',
        '\n',
        '\r',
        11,
        12,
        0x0085,
        0x2000,
        0x2001,
        0x2002,
        0x2003,
        0x2004,
        0x2005,
        0x2006,
        0x2008,
        0x2009,
        0x200a,
        0x2028,
        0x2029,
        0x205f,
        0x3000,
        0,
        => return true,
        else => return false,
    }
}

fn characterLenUtf8(c: u8) usize {
    if (c & 0b1000_0000 == 0) {
        return 1;
    } else if (c & 0b1110_0000 == 0b1100_0000) {
        return 2;
    } else if (c & 0b1111_0000 == 0b1110_0000) {
        return 3;
    } else if (c & 0b1111_1000 == 0b1111_0000) {
        return 4;
    }

    unreachable;
}

const testing = std.testing;
test "characterLenUtf8" {
    try testing.expect(characterLenUtf8('a') == 1);
    try testing.expect(characterLenUtf8(0xC2) == 2);
    try testing.expect(characterLenUtf8(0xE0) == 3);
    try testing.expect(characterLenUtf8(0xF0) == 4);
}

test "wchar" {
    var unicode_char = "🤯";
    var unicode_char2 = "ࠀ";
    var unicode_char3 = " ";

    var codepoint = try std.unicode.utf8Decode(unicode_char);
    var codepoint2 = try std.unicode.utf8Decode(unicode_char2);
    var codepoint3 = try std.unicode.utf8Decode(unicode_char3);

    try testing.expect(!iswspace2(codepoint));
    try testing.expect(!iswspace2(codepoint2));
    try testing.expect(iswspace2(codepoint3));
}
