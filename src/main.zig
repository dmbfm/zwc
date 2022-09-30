// zwc -- A `wc` clone written in zig.
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

fn iswspace(codepoint: u21) bool {
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

const Utf8ChunkedIterator = struct {
    chunk: []const u8,
    i: usize = 0,
    brokenCodepointBuffer: [4]u8 = [_]u8{ 0, 0, 0, 0 },
    brokenCodepointSlice: ?[]u8 = null,
    mendingBuffer: [4]u8 = [_]u8{ 0, 0, 0, 0 },

    const Self = @This();

    pub fn init(chunk: []const u8) Utf8ChunkedIterator {
        return .{
            .chunk = chunk,
            .i = 0,
        };
    }

    pub fn setChunk(self: *Self, chunk: []const u8) void {
        if (self.i < self.chunk.len) unreachable;

        self.chunk = chunk;
        self.i = 0;
    }

    pub fn nextCodepointSlice(self: *Self) ?[]const u8 {
        if (self.brokenCodepointSlice) |slice| {
            std.debug.assert(self.i == 0);

            if (self.i >= self.chunk.len) {
                return null;
            }

            var cplen = std.unicode.utf8ByteSequenceLength(slice[0]) catch unreachable;

            var i: usize = 0;
            while (i < slice.len) {
                self.mendingBuffer[i] = slice[i];
                i += 1;
            }

            while (i < cplen) {
                self.mendingBuffer[i] = self.chunk[i - slice.len];
                i += 1;
            }

            self.i += cplen - slice.len;
            self.brokenCodepointSlice = null;

            return self.mendingBuffer[0..cplen];
        }

        if (self.i >= self.chunk.len) {
            return null;
        }

        var cplen = std.unicode.utf8ByteSequenceLength(self.chunk[self.i]) catch unreachable;
        var cp_will_overflow: bool = (self.i + cplen - 1) >= self.chunk.len;

        if (cp_will_overflow) {
            var i: usize = self.i;
            var count: usize = 0;
            while (i < self.chunk.len) : (i += 1) {
                self.brokenCodepointBuffer[i - self.i] = self.chunk[i];
                count += 1;
            }

            self.brokenCodepointSlice = self.brokenCodepointBuffer[0..count];
            self.i = self.chunk.len;
            return null;
        }

        self.i += cplen;
        return self.chunk[self.i - cplen .. self.i];
    }

    pub fn nextCodepoint(self: *Self) ?u21 {
        if (self.nextCodepointSlice()) |slice| {
            var cp = std.unicode.utf8Decode(slice) catch unreachable;
            return cp;
        }

        return null;
    }
};

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

    // 0 -> ouside word
    // 1 -> inside word
    var state: i32 = 0;

    var it = Utf8ChunkedIterator.init(&[_]u8{});

    while (true) {
        var bytes_read = try std.os.read(fileHandle, &buf);
        if (bytes_read == 0) break;

        num_bytes += bytes_read;

        it.setChunk(buf[0..bytes_read]);

        while (it.nextCodepoint()) |c| {
            num_chars += 1;
            switch (state) {
                0 => {
                    if (c == '\n') {
                        num_lines += 1;
                    } else if (!iswspace(c)) {
                        state = 1;
                    }
                },
                1 => {
                    if (iswspace(c)) {
                        if (c == '\n') {
                            num_lines += 1;
                        }
                        num_words += 1;
                        state = 0;
                    }
                },
                else => unreachable,
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
        try stdout.print(" {:>7}", .{num_lines});
    }

    if (result.num_words) |num_words| {
        try stdout.print(" {:>7}", .{num_words});
    }

    if (result.num_bytes) |num_bytes| {
        try stdout.print(" {:>7}", .{num_bytes});
    }

    if (result.num_chars) |num_chars| {
        try stdout.print(" {:>7}", .{num_chars});
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
        var result: ?WcResult = wcFile(4096, filenames[i], config) catch |err|
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
        var result = try wcFileHandle(4096, std.io.getStdIn().handle, config);
        try printResult(result, null);
    }
}
