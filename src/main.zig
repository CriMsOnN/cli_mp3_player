const std = @import("std");

const PlayListErrors = error{ FilesPopulated, StdinUnavailable, FileNotFoundInList, PlayerNotPaused };

const PlaylistCommands = enum(u8) {
    PLAY,
    PAUSE,
    NEXT,
    PREV,
    RESUME,
};

const PlayList = struct {
    files: std.ArrayList([]const u8),
    directory: []const u8,
    allocator: *std.mem.Allocator,
    selected: u8,
    process: std.process.Child,
    is_playing: bool,
    is_paused: bool,
    progress: u32,
    total_frames: u32,
    stdout: std.fs.File.Writer,
    fn parseDirectory(self: *PlayList) !void {
        var mp3_dir = try std.fs.cwd().openDir(self.directory, .{ .iterate = true });
        defer mp3_dir.close();
        var files_iterator = mp3_dir.iterate();
        while (try files_iterator.next()) |file| {
            if (std.mem.endsWith(u8, file.name, ".mp3")) {
                std.debug.print("Append file: {s}\n", .{file.name});
                const file_copy = try self.allocator.*.alloc(u8, file.name.len);
                std.mem.copyForwards(u8, file_copy, file.name);
                try self.files.append(file_copy);
            }
        }
    }

    fn capture_output(self: *PlayList) !void {
        if (self.process.stdout) |out_stream| {
            var buf: [1024]u8 = undefined;
            while (true) {
                const bytes_read = try out_stream.read(&buf);
                if (bytes_read == 0) break;
                const output = buf[0..bytes_read];
                try self.processOutput(output);
            }
        }
    }

    fn processOutput(self: *PlayList, output: []const u8) !void {
        var lines = std.mem.splitSequence(u8, output, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "@F")) {
                var fields = std.mem.tokenizeSequence(u8, line, " ");
                _ = fields.next();
                _ = fields.next();
                if (fields.next()) |progress_str| {
                    const current_frame = std.fmt.parseInt(u32, progress_str, 10) catch |err| {
                        std.debug.print("Error parsing progress: {}\n", .{err});
                        continue;
                    };
                    if (self.total_frames == 0) {
                        self.total_frames = current_frame;
                    }
                    if (self.total_frames > 0) {
                        const progress_percentage = @as(u8, @intCast(@divFloor(100 * (self.total_frames - current_frame), self.total_frames)));
                        self.progress = @min(progress_percentage, 100);
                        try self.updateProgressDisplay();
                    }
                }
            }
        }
    }

    fn updateProgressDisplay(self: *PlayList) !void {
        try self.stdout.writeAll("\x1B[1A\x1B[2K");
        try self.stdout.print("Progress: [", .{});
        const filled = @divFloor(self.progress * 20, 100);
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            if (i < filled) {
                try self.stdout.writeAll("=");
            } else if (i == filled) {
                try self.stdout.writeAll(">");
            } else {
                try self.stdout.writeAll(" ");
            }
        }
        try self.stdout.print("] {}%\n", .{self.progress});
    }

    fn init(self: *PlayList, stdout: std.fs.File.Writer) !void {
        self.process = std.process.Child.init(&[_][]const u8{ "mpg123", "--remote" }, self.allocator.*);
        self.process.stdin_behavior = .Pipe;
        self.process.stdout_behavior = .Pipe;
        self.process.stderr_behavior = .Pipe;
        try self.process.spawn();
        self.stdout = stdout;
    }

    fn play(self: *PlayList, file: []const u8) !void {
        const file_path = try std.fmt.allocPrint(self.allocator.*, "load {s}/{s}\n", .{ self.directory, file });
        defer self.allocator.free(file_path);

        if (self.process.stdin) |stdin| {
            try stdin.writer().writeAll(file_path);
            self.is_playing = true;
        } else {
            return error.StdinNotAvailable;
        }
    }

    fn pause(self: *PlayList) !void {
        if (self.is_paused) {
            std.log.info("Player is already paused\n", .{});
            return;
        }
        if (self.process.stdin) |stdin| {
            const pause_cmd: []const u8 = "pause\n";
            try stdin.writer().writeAll(pause_cmd);
            self.is_paused = true;
        } else {
            return error.StdinUnavailable;
        }
    }

    fn unpause(self: *PlayList) !void {
        if (!self.is_paused) {
            return error.PlayerNotPaused;
        }
        if (self.process.stdin) |stdin| {
            const resume_cmd: []const u8 = "resume\n";
            try stdin.writer().writeAll(resume_cmd);
            self.is_paused = false;
        } else {
            return error.StdinUnavailable;
        }
    }

    fn log_process_output(self: *PlayList) !void {
        if (self.process.stdout) |out_stream| {
            var buf: [1024]u8 = undefined;
            const num_bytes = try out_stream.read(&buf);
            if (num_bytes > 0) {
                const output_str = buf[0..num_bytes];
                std.log.info("mpg123 stdout: {s}\n", .{output_str});
            } else {
                std.log.info("mpg123 stdout: No output\n", .{});
            }
        }

        if (self.process.stderr) |err_stream| {
            var buf: [1024]u8 = undefined;
            const num_bytes = try err_stream.read(&buf);
            if (num_bytes > 0) {
                const error_str = buf[0..num_bytes];
                std.log.err("mpg123 stderr: {s}\n", .{error_str});
            } else {
                std.log.err("mpg123 stderr: No error output\n", .{});
            }
        }
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len <= 1) {
        std.log.info("Args are not present\n", .{});
        return;
    }
    if (args[1].len == 0) {
        std.log.err("Path arg is not preset\n", .{});
        return;
    }
    const path = args[1];
    const stdout = std.io.getStdOut().writer();
    var playlist = PlayList{
        .allocator = @constCast(&allocator),
        .files = std.ArrayList([]const u8).init(allocator),
        .directory = path,
        .selected = 0,
        .process = undefined,
        .is_playing = false,
        .is_paused = false,
        .progress = 0,
        .total_frames = 0,
        .stdout = stdout,
    };
    defer playlist.files.deinit();
    try playlist.parseDirectory();
    try playlist.init(stdout);
    const output_thread = try std.Thread.spawn(.{}, PlayList.capture_output, .{&playlist});
    try stdout.writeAll("Progress: [                    ] 0%\n");
    while (true) {
        const stdin = std.io.getStdIn().reader();
        const bare_line = try stdin.readUntilDelimiterAlloc(allocator, '\n', 8192);
        defer allocator.free(bare_line);
        const line = std.mem.trim(u8, bare_line, "\r");
        var parts = std.mem.splitSequence(u8, line, " ");
        const command = parts.next() orelse continue;
        const argument = parts.next() orelse "";
        const out_str = try allocator.alloc(u8, command.len);
        defer allocator.free(out_str);
        _ = std.ascii.upperString(out_str, command);
        const player_state = std.meta.stringToEnum(PlaylistCommands, out_str) orelse continue;
        switch (player_state) {
            PlaylistCommands.PLAY => {
                std.log.info("Play command executed! with arguments: {s}\n", .{argument});
                playlist.play(argument) catch |err| {
                    std.log.err("Error when playing music: {}\n", .{err});
                };
            },
            PlaylistCommands.PAUSE => {
                std.log.info("Pause command executed!", .{});
                playlist.pause() catch |err| {
                    std.log.err("Error when pausing music: {}\n", .{err});
                };
            },
            PlaylistCommands.RESUME => {
                std.log.info("Resume command executed!", .{});
                playlist.unpause() catch |err| {
                    std.log.err("{}\n", .{err});
                };
            },
            else => unreachable,
        }
    }
    output_thread.join();
}
