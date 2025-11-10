const std = @import("std");
const builtin = @import("builtin");
const ur = @import("ur");

var stdout: *std.io.Writer = undefined;
var stderr: *std.io.Writer = undefined;

var allocator: std.mem.Allocator = undefined;

var args: [][:0]u8 = undefined;

var cache_dir: std.fs.Dir = undefined;
var data_dir: std.fs.Dir = undefined;

pub fn main() !void {
    var stdout_buffer: [1024]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    const stderr_file = std.fs.File.stderr();
    var stderr_writer = stderr_file.writer(&stderr_buffer);
    stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    allocator = arena.allocator();

    args = try std.process.argsAlloc(allocator);

    const envmap = try std.process.getEnvMap(allocator);
    var root_path_env_name: []const u8 = undefined;
    var cache_subpath: []const u8 = undefined;
    var data_subpath: []const u8 = undefined;
    switch (builtin.os.tag) {
        .macos, .linux => {
            root_path_env_name = "HOME";
            cache_subpath = ".cache/ur";
            data_subpath = ".local/share/ur";
        },
        .windows => {
            root_path_env_name = "LOCALAPPDATA";
            cache_subpath = "ur/cache";
            data_subpath = "ur/zig";
        },
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
    }

    const home_path = envmap.get(root_path_env_name) orelse return error.BadEnvironment;
    const home = try std.fs.openDirAbsolute(home_path, .{});
    home.makePath(cache_subpath) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    home.makePath(data_subpath) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try home.realpath(cache_subpath, &buffer);
    cache_dir = try std.fs.openDirAbsolute(cache_path, .{});
    const data_path = try home.realpath(data_subpath, &buffer);
    data_dir = try std.fs.openDirAbsolute(data_path, .{ .iterate = true });

    const Subcommand = enum { help, list, install, zig };
    const subcommand: ?Subcommand = if (args.len > 1) std.meta.stringToEnum(Subcommand, args[1]) else null;

    if (subcommand) |value| {
        switch (value) {
            .help => try help(stdout),
            .list => try list(),
            .install => try install(),
            .zig => try shim(),
        }
    } else {
        try help(stderr);
    }
}

fn help(writer: *std.io.Writer) !void {
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

fn list() !void {
    const Subcommand = enum { available, all, installed };
    var subcommand: Subcommand = undefined;
    if (args.len > 2) {
        if (std.meta.stringToEnum(Subcommand, args[2])) |value| {
            subcommand = value;
        } else {
            try help(stderr);
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
            var dir_it = data_dir.iterate();
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

fn install() !void {
    if (args.len < 3) {
        try help(stderr);
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
    try install_target_spec(target_specs);
}

fn shim() !void {
    var version: []const u8 = undefined;
    var args_shift: usize = 2;
    version_block: {
        if (args.len > 2) {
            try stdout.print("{s}\n", .{args[2]});
            try stdout.flush();
            if (std.SemanticVersion.parse(args[2])) |_| {
                version = args[2];
                args_shift += 1;
                break :version_block;
            } else |_| {}
        }
        if (std.fs.cwd().openFile("build.zig.zon", .{})) |file| {
            defer file.close();
            const stat = try file.stat();
            var buffer: [1024]u8 = undefined;
            var reader = file.reader(&buffer);
            var source = try allocator.alloc(u8, stat.size + 1);
            @memset(source, 0);
            try reader.interface.readSliceAll(source[0..stat.size]);
            const zon = try std.zon.parse.fromSlice(struct { minimum_zig_version: []const u8 }, allocator, source[0..stat.size :0], null, .{ .ignore_unknown_fields = true });
            version = zon.minimum_zig_version;
            break :version_block;
        } else |err| {
            if (err != error.FileNotFound) {
                return err;
            }
        }
        const index = try ur.Index.singleton();
        version = index.versions.keys()[1];
    }
    var zig_location: std.ArrayList(u8) = .empty;
    try zig_location.print(allocator, "zig-{s}-{s}", .{ ur.NATIVE_TARGET, version });
    var zig_dir: std.fs.Dir = undefined;
    if (data_dir.openDir(zig_location.items, .{})) |value| {
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
        try install_target_spec(target_specs);
        zig_dir = try data_dir.openDir(zig_location.items, .{});
    }
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
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

fn install_target_spec(target_spec: ur.TargetSpecs) !void {
    const FileType = enum { zip, tar_xz };
    var filetype: FileType = undefined;
    if (std.ascii.endsWithIgnoreCase(target_spec.tarball, ".zip")) {
        filetype = .zip;
    } else if (std.ascii.endsWithIgnoreCase(target_spec.tarball, ".tar.xz")) {
        filetype = .tar_xz;
    } else {
        return error.UnsupportedFileType;
    }
    var it = std.mem.splitBackwardsScalar(u8, target_spec.tarball, '/');
    const filename = it.next().?;
    var file: std.fs.File = undefined;
    var download = true;
    if (cache_dir.createFile(filename, .{ .read = true, .exclusive = true })) |value| {
        file = value;
    } else |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
        file = try cache_dir.openFile(filename, .{});
        download = false;
    }
    defer file.close();
    errdefer file.close();
    var buffer: [1024 * 16]u8 = undefined; // NOTE: std.zip and std.tar break on small buffer sizes for some reason?
    if (download) {
        errdefer cache_dir.deleteFile(filename) catch {};
        var writer = file.writer(&buffer);
        const compressed_bytes = try ur.http_get(allocator, target_spec.tarball);
        try writer.interface.writeAll(compressed_bytes);
        try writer.interface.flush();
    }
    switch (filetype) {
        .zip => {
            var file_reader = file.reader(&buffer);
            try std.zip.extract(data_dir, &file_reader, .{});
        },
        .tar_xz => {
            const file_reader = file.deprecatedReader();
            var decompress = try std.compress.xz.decompress(allocator, file_reader);
            const decompress_reader = decompress.reader();
            var decompress_adapter = decompress_reader.adaptToNewApi(&buffer);
            try std.tar.pipeToFileSystem(data_dir, &decompress_adapter.new_interface, .{});
        },
    }
}
