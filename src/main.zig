const std = @import("std");
const builtin = @import("builtin");
const ur = @import("ur");

pub fn main() !void {
    var stdout_buffer: [1024]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    const stderr_file = std.fs.File.stderr();
    var stderr_writer = stderr_file.writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    const Subcommand = enum { help, list, install, zig };
    const subcommand: ?Subcommand = if (args.len > 1) std.meta.stringToEnum(Subcommand, args[1]) else null;

    if (subcommand) |value| {
        switch (value) {
            .help => try help(stdout, args),
            .list => try list(allocator, stdout, stderr, args),
            .install => try install(allocator, stdout, stderr, args),
            .zig => try shim(allocator, stdout, stderr, args),
        }
    } else {
        try help(stderr, args);
    }
}

fn help(writer: *std.io.Writer, args: [][:0]u8) !void {
    try writer.print(
        \\A zig version manager, written in zig.
        \\
        \\Usage: {s} [COMMAND] [<ARGS>]
        \\
        \\Commands:
        \\  help                              Display this help message.
        \\  install [VERSION] (TARGET)?       Install VERSION for your architecture, or for TARGET.
        \\  list (*available|all|installed)?  List versions for your architecture; or all zig versions; or installed zig versions.
        \\  zig (VERSION)? [<ARGS>]           Run zig with [<ARGS>], parsing build.zig.zon for the version. Override with VERSION.
        \\
    , .{args[0]});
}

fn list(allocator: std.mem.Allocator, stdout: *std.io.Writer, stderr: *std.io.Writer, args: [][:0]u8) !void {
    const Subcommand = enum { available, all, installed };
    var subcommand: Subcommand = undefined;
    if (args.len > 2) {
        if (std.meta.stringToEnum(Subcommand, args[2])) |value| {
            subcommand = value;
        } else {
            try help(stderr, args);
            return;
        }
    } else {
        subcommand = .available;
    }

    switch (subcommand) {
        .available, .all => {
            const index = try ur.Index.singleton();
            var it = index.versions.iterator();
            while (it.next()) |kv| {
                const version = kv.key_ptr.*;
                const version_spec = kv.value_ptr;
                if (subcommand == Subcommand.all or version_spec.targets.get(ur.NATIVE_TARGET) != null) {
                    try stdout.print("{s}\n", .{version});
                }
            }
        },
        .installed => {
            const dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
            var dir_it = dir.iterate();
            dir_loop: while (try dir_it.next()) |entry| {
                if (entry.kind != .directory) {
                    continue;
                }
                var name_it = std.mem.splitScalar(u8, entry.name, '-');
                var pieces: std.ArrayList([]const u8) = .empty;
                while (name_it.next()) |piece| {
                    if (piece.len == 0) {
                        continue :dir_loop;
                    }
                    try pieces.append(allocator, piece);
                }
                if (pieces.items.len != 4) {
                    continue;
                }
                if (!std.mem.eql(u8, "zig", pieces.items[0])) {
                    continue;
                }
                try stdout.print("{s}\n", .{pieces.items[3]});
            }
        },
    }
}

fn install(allocator: std.mem.Allocator, stdout: *std.io.Writer, stderr: *std.io.Writer, args: [][:0]u8) !void {
    if (args.len < 3) {
        try help(stderr, args);
        return;
    }
    const index = try ur.Index.singleton();
    var version_spec: ur.VersionSpecs = undefined;
    if (index.versions.get(args[2])) |value| {
        version_spec = value;
    } else {
        try stderr.print("Error: no zig version named '{s}'\n", .{args[2]});
        return;
    }

    var target: []const u8 = ur.NATIVE_TARGET;
    if (args.len > 3) {
        target = args[3];
    }

    var target_specs: ur.TargetSpecs = undefined;
    if (version_spec.targets.get(target)) |value| {
        target_specs = value;
    } else {
        try stderr.print("Error: zig version '{s}' does not support architecture '{s}'\n", .{ args[2], target });
        return;
    }
    try stdout.print("Installing zig {s} for {s}...\n", .{ args[2], target });
    try stdout.flush();
    try target_specs.install(allocator);
}

fn shim(allocator: std.mem.Allocator, stdout: *std.io.Writer, stderr: *std.io.Writer, args: [][:0]u8) !void {
    const dir = std.fs.cwd();
    var version: []const u8 = undefined;
    if (dir.openFile("build.zig.zon", .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        var buffer: [1024]u8 = undefined;
        var reader = file.reader(&buffer);
        var source = try allocator.alloc(u8, stat.size + 1);
        @memset(source, 0);
        try reader.interface.readSliceAll(source[0..stat.size]);
        const zon = try std.zon.parse.fromSlice(struct { minimum_zig_version: []const u8 }, allocator, source[0..stat.size :0], null, .{ .ignore_unknown_fields = true });
        version = zon.minimum_zig_version;
    } else |err| {
        if (err != error.FileNotFound) {
            return err;
        }
        version_block: {
            if (args.len > 3) {
                if (std.SemanticVersion.parse(args[3])) |_| {
                    version = args[3];
                    break :version_block;
                } else |_| {}
            }
            const index = try ur.Index.singleton();
            version = index.versions.keys()[1];
        }
    }
    var zig_location: std.ArrayList(u8) = .empty;
    try zig_location.print(allocator, "zig-{s}-{s}", .{ ur.NATIVE_TARGET, version });
    var zig_dir: std.fs.Dir = undefined;
    if (dir.openDir(zig_location.items, .{})) |value| {
        zig_dir = value;
    } else |err| {
        if (err != error.FileNotFound) {
            return err;
        }
        const index = try ur.Index.singleton();
        var version_spec: ur.VersionSpecs = undefined;
        if (index.versions.get(version)) |value| {
            version_spec = value;
        } else {
            try stderr.print("Error: no zig version named '{s}'\n", .{version});
            return;
        }
        var target_specs: ur.TargetSpecs = undefined;
        if (version_spec.targets.get(ur.NATIVE_TARGET)) |value| {
            target_specs = value;
        } else {
            try stderr.print("Error: zig version '{s}' does not support architecture '{s}'\n", .{ version, ur.NATIVE_TARGET });
            return;
        }
        try stdout.print("Installing zig {s} for {s}...\n", .{ version, ur.NATIVE_TARGET });
        try stdout.flush();
        try target_specs.install(allocator);
        zig_dir = try dir.openDir(zig_location.items, .{});
    }
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const zig_exe = try zig_dir.realpath(if (builtin.os.tag == .windows) "zig.exe" else "zig", &buffer);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, zig_exe);
    for (args[2..]) |arg| {
        try argv.append(allocator, arg);
    }
    try stdout.flush();
    try stderr.flush();
    if (std.process.can_execv) {
        return std.process.execv(allocator, argv.items);
    } else if (std.process.can_spawn) {
        var child = std.process.Child.init(argv.items, allocator);
        try child.spawn();
    } else {
        try stderr.print("Error: no mechanism to run {s}!\n", .{zig_exe});
    }
}
