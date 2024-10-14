const std = @import("std");

const PlayListErrors = error{ FilesPopulated, StdinUnavailable, FileNotFoundInList };

const PlaylistCommands = enum(u8) {
    PLAY,
    PAUSE,
    NEXT,
    PREV,
};

const PlayList = struct {
    files: std.ArrayList([]const u8),
    directory: []const u8,
    allocator: *std.mem.Allocator,
    selected: u8,
    fn parseDirectory(self: *PlayList) !void {
        const mp3_dir = try std.fs.cwd().openDir(self.directory, .{});
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

    fn play(self: *PlayList, file: []const u8) !void {
        var found: bool = false;
        for (self.files.items) |f| {
            std.log.info("File: {s}\n", .{f});
            if (std.mem.eql(u8, f, file)) {
                found = true;
            }
        }
        if (!found) {
            return PlayListErrors.FileNotFoundInList;
        }
        const file_path = try std.fmt.allocPrint(self.allocator.*, "{s}/{s}", .{ self.directory, file });
        const _args = [_][]const u8{
            "mpg123",
            file_path,
        };
        var process = std.process.Child.init(&_args, self.allocator.*);
        try process.spawn();
        const exit_status = try process.wait();
        if (exit_status.Stopped == 1) {
            std.debug.print("Process failed\n", .{});
        } else if (exit_status.Exited == 1) {
            std.debug.print("Proccess failed\n", .{});
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
    var playlist = PlayList{
        .allocator = @constCast(&allocator),
        .files = std.ArrayList([]const u8).init(allocator),
        .directory = path,
        .selected = 0,
    };
    defer playlist.files.deinit();
    playlist.parseDirectory() catch |err| {
        std.log.err("Error parsing folder: {}\n", .{err});
        return err;
    };
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
            else => unreachable,
        }
    }
}
