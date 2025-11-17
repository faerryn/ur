const std = @import("std");
const builtin = @import("builtin");
const ur = @import("ur");
const config = @import("config");

var stdout: *std.io.Writer = undefined;
var stderr: *std.io.Writer = undefined;

var allocator: std.mem.Allocator = undefined;

var args: [][:0]u8 = undefined;

var cache_dir: std.fs.Dir = undefined;
var data_dir: std.fs.Dir = undefined;

pub fn main() !void {
    var stdout_buffer = std.mem.zeroes([1024]u8);
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer = std.mem.zeroes([1024]u8);
    const stderr_file = std.fs.File.stderr();
    var stderr_writer = stderr_file.writer(&stderr_buffer);
    stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    allocator = arena.allocator();

    args = try std.process.argsAlloc(allocator);

    const envmap = try std.process.getEnvMap(allocator);
    const parent_path_env_name, const cache_subpath, const data_subpath =
        switch (builtin.os.tag) {
            .macos, .linux => .{ "HOME", ".cache/ur", ".local/share/ur" },
            .windows => .{
                "LOCALAPPDATA",
                "ur/cache",
                "ur/zig",
            },
            else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
        };

    const parent_path = envmap.get(parent_path_env_name) orelse return error.BadEnvironment;
    const parent_dir = try std.fs.openDirAbsolute(parent_path, .{});
    parent_dir.makePath(cache_subpath) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    parent_dir.makePath(data_subpath) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
    const cache_path = try parent_dir.realpath(cache_subpath, &buffer);
    cache_dir = try std.fs.openDirAbsolute(cache_path, .{});
    const data_path = try parent_dir.realpath(data_subpath, &buffer);
    data_dir = try std.fs.openDirAbsolute(data_path, .{ .iterate = true });

    const Subcommand = enum { help, list, install, zig, version };
    switch (if (args.len > 1)
        std.meta.stringToEnum(Subcommand, args[1]) orelse .help
    else
        .help) {
        .help => try help(),
        .list => try list(),
        .install => try install(),
        .zig => try shim(),
        .version => try print_version(),
    }
}

fn help() !void {
    try stdout.print(
        \\A zig version manager, written in zig.
        \\
        \\Usage: {s} [COMMAND] [<ARGS>]
        \\
        \\Commands:
        \\  help                              Display this help message.
        \\  install [VERSION]                 Install VERSION for your architecture.
        \\  list (*available|all|installed)?  List versions for your architecture; or all versions regardless of architecture; or installed versions only.
        \\  zig (VERSION)? [<ARGS>]           Run zig with [<ARGS>], parsing build.zig.zon for the version. Override with VERSION.
        \\  version                           Print the version of {s}.
        \\
    , .{ args[0], config.name });
}

fn print_version() !void {
    try stdout.print("{s} {s}\n", .{ config.name, config.version });
}

fn list() !void {
    const Subcommand = enum { available, all, installed, help };

    switch (if (args.len > 2)
        std.meta.stringToEnum(Subcommand, args[2]) orelse .help
    else
        .available) {
        .all => {
            var index = try ur.fetch_remote_index(allocator);
            defer index.deinit();
            var it = index.content.iterator();
            while (it.next()) |kv| {
                try kv.key_ptr.serialize(stdout);
                try stdout.print("\n", .{});
            }
            try stdout.flush();
        },
        .available => {
            const index = try ur.Index.singleton();
            var it = index.versions.iterator();
            while (it.next()) |kv| {
                const version = kv.key_ptr.*;
                const version_spec = kv.value_ptr;
                if (version_spec.targets.get(ur.NATIVE_TARGET) != null) {
                    try stdout.print("{s}\n", .{version});
                }
            }
        },
        .installed => {
            const versions = try list_installed_versions();
            for (versions.items) |version| {
                try stdout.print("{s}\n", .{version});
            }
        },
        .help => try help(),
    }
}

fn list_installed_versions() !std.ArrayList([]const u8) {
    var versions: std.ArrayList([]const u8) = .empty;
    var dir_it = data_dir.iterate();
    dir_loop: while (try dir_it.next()) |entry| {
        if (entry.kind != .directory) {
            continue;
        }
        var name_it = std.mem.splitScalar(u8, entry.name, '-');
        var pieces = std.mem.zeroes([4][]const u8);
        var len: usize = 0;
        while (name_it.next()) |piece| {
            if (len == 4) continue :dir_loop;
            if (piece.len == 0) continue :dir_loop;
            pieces[len] = piece;
            len += 1;
        }
        if (len != 4) {
            continue;
        }
        if (!std.mem.eql(u8, "zig", pieces[0])) {
            continue;
        }
        try versions.append(allocator, try allocator.dupe(u8, pieces[3]));
    }
    return versions;
}

fn install() !void {
    if (args.len < 3) {
        try help();
        return;
    }
    const index = try ur.Index.singleton();
    const version = args[2];
    const version_spec: ur.VersionSpecs = index.versions.get(version) orelse
        {
            try stderr.print("Error: no zig version named '{s}'\n", .{version});
            return;
        };

    _ = version_spec.targets.get(ur.NATIVE_TARGET) orelse {
        try stderr.print("Error: zig version '{s}' does not support architecture '{s}'\n", .{ version, ur.NATIVE_TARGET });
        return;
    };
    try stdout.print("Installing zig {s} for {s}...\n", .{ version, ur.NATIVE_TARGET });
    try stdout.flush();
    try ur.install_spec(.{ .target = ur.Target.NATIVE, .version = try ur.Version.parse(version) }, data_dir, cache_dir);
}

fn shim() !void {
    var args_shift: usize = 2;
    const version: []const u8 =
        version_block: {
            // Check if VERSION is specified
            if (args.len > 2) {
                if (std.mem.eql(u8, "master", args[2]) or
                    if (std.SemanticVersion.parse(args[2])) |_| true else |_| false)
                {
                    args_shift += 1;
                    break :version_block args[2];
                }
            }
            // Check if build.zig.zon specifies version
            // TODO: check parent directories for build.zig.zon
            if (std.fs.cwd().openFile("build.zig.zon", .{})) |file| {
                defer file.close();
                const stat = try file.stat();
                var buffer = std.mem.zeroes([1024]u8);
                var reader = file.reader(&buffer);
                var source = try allocator.alloc(u8, stat.size + 1);
                @memset(source, 0);
                try reader.interface.readSliceAll(source[0..stat.size]);
                if (std.zon.parse.fromSlice(struct { minimum_zig_version: []const u8 }, allocator, source[0..stat.size :0], null, .{ .ignore_unknown_fields = true })) |zon| {
                    break :version_block zon.minimum_zig_version;
                } else |err| {
                    if (err != error.ParseZon) {
                        return err;
                    }
                }
            } else |err| {
                if (err != error.FileNotFound) {
                    return err;
                }
            }
            // Check for latest installed version
            const installed_versions = try list_installed_versions();
            if (installed_versions.items.len > 0) {
                var candidate = installed_versions.items[0];
                for (installed_versions.items[1..]) |installed_version| {
                    if (std.mem.eql(u8, "master", candidate)) {
                        candidate = installed_version;
                    } else if (std.mem.eql(u8, "master", installed_version)) {
                        continue;
                    } else {
                        const old = try std.SemanticVersion.parse(candidate);
                        const new = try std.SemanticVersion.parse(installed_version);
                        if (std.SemanticVersion.order(old, new) == .lt) {
                            candidate = installed_version;
                        }
                    }
                }
                break :version_block candidate;
            }
            // Check online for latest tagged version
            const index = try ur.Index.singleton();
            break :version_block index.versions.keys()[1];
        };
    var zig_dir_name: std.ArrayList(u8) = .empty;
    try zig_dir_name.print(allocator, "zig-{s}-{s}", .{ ur.NATIVE_TARGET, version });
    const zig_dir: std.fs.Dir = data_dir.openDir(zig_dir_name.items, .{}) catch |err| zig_dir_block: {
        if (err != error.FileNotFound) {
            return err;
        }
        const index = try ur.Index.singleton();
        var version_spec: ur.VersionSpecs = index.versions.get(version) orelse {
            try stderr.print("Error: no zig version named '{s}'\n", .{version});
            return;
        };
        _ = version_spec.targets.get(ur.NATIVE_TARGET) orelse
            {
                try stderr.print("Error: zig version '{s}' does not support architecture '{s}'\n", .{ version, ur.NATIVE_TARGET });
                return;
            };
        try stdout.print("Installing zig {s} for {s}...\n", .{ version, ur.NATIVE_TARGET });
        try stdout.flush();
        try ur.install_spec(.{ .target = ur.Target.NATIVE, .version = try ur.Version.parse(version) }, data_dir, cache_dir);
        break :zig_dir_block try data_dir.openDir(zig_dir_name.items, .{});
    };
    var buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
    const zig_exe = try zig_dir.realpath(if (builtin.os.tag == .windows) "zig.exe" else "zig", &buffer);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, zig_exe);
    for (args[args_shift..]) |arg| {
        try argv.append(allocator, arg);
    }
    try stdout.flush();
    try stderr.flush();
    if (std.process.can_execv) {
        return std.process.execv(allocator, argv.items);
    } else if (std.process.can_spawn) {
        var child = std.process.Child.init(argv.items, allocator);
        const term = try child.spawnAndWait();
        return std.process.exit(term.Exited);
    } else {
        try stderr.print("Error: no mechanism to run {s}!\n", .{zig_exe});
    }
}
