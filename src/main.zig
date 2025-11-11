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

    const Subcommand = enum { help, list, install, zig, version };
    const subcommand: ?Subcommand = if (args.len > 1) std.meta.stringToEnum(Subcommand, args[1]) else null;

    if (subcommand) |value| {
        switch (value) {
            .help => try help(stdout),
            .list => try list(),
            .install => try install(),
            .zig => try shim(),
            .version => try print_version(),
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
        \\  install [VERSION]                 Install VERSION for your architecture.
        \\  list (*available|all|installed)?  List versions for your architecture; or all versions regardless of architecture; or installed versions only.
        \\  zig (VERSION)? [<ARGS>]           Run zig with [<ARGS>], parsing build.zig.zon for the version. Override with VERSION.
        \\  version                           Print the version of {s}
        \\
    , .{ args[0], config.name });
}

fn print_version() !void {
    try stdout.print("{s} {s}\n", .{ config.name, config.version });
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
            const versions = try list_installed_versions();
            for (versions.items) |version| {
                try stdout.print("{s}\n", .{version});
            }
        },
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
        try versions.append(allocator, try allocator.dupe(u8, pieces.items[3]));
    }
    return versions;
}

fn install() !void {
    if (args.len < 3) {
        try help(stderr);
        return;
    }
    const index = try ur.Index.singleton();
    var version_spec: ur.VersionSpecs = undefined;
    const version = args[2];
    if (index.versions.get(version)) |value| {
        version_spec = value;
    } else {
        try stderr.print("Error: no zig version named '{s}'\n", .{version});
        return;
    }

    const target_specs: ur.TargetSpecs = version_spec.targets.get(ur.NATIVE_TARGET) orelse {
        try stderr.print("Error: zig version '{s}' does not support architecture '{s}'\n", .{ version, ur.NATIVE_TARGET });
        return;
    };
    try stdout.print("Installing zig {s} for {s}...\n", .{ version, ur.NATIVE_TARGET });
    try stdout.flush();
    try install_target_spec(version, target_specs);
}

fn shim() !void {
    var version: []const u8 = undefined;
    var args_shift: usize = 2;
    version_block: {
        // Check if VERSION is specified
        if (args.len > 2) {
            if (std.mem.eql(u8, "master", args[2]) or
                if (std.SemanticVersion.parse(args[2])) |_| true else |_| false)
            {
                version = args[2];
                args_shift += 1;
                break :version_block;
            }
        }
        // Check if build.zig.zon specifies version
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
        // Check for latest installed version
        const installed_versions = try list_installed_versions();
        if (installed_versions.items.len > 0) {
            version = installed_versions.items[0];
            for (installed_versions.items[1..]) |installed_version| {
                if (std.mem.eql(u8, "master", version)) {
                    version = installed_version;
                } else if (std.mem.eql(u8, "master", installed_version)) {
                    continue;
                } else {
                    const old = try std.SemanticVersion.parse(version);
                    const new = try std.SemanticVersion.parse(installed_version);
                    if (std.SemanticVersion.order(old, new) == .lt) {
                        version = installed_version;
                    }
                }
            }
            break :version_block;
        }
        // Check online for latest tagged version
        const index = try ur.Index.singleton();
        version = index.versions.keys()[1];
    }
    var zig_dir_name: std.ArrayList(u8) = .empty;
    try zig_dir_name.print(allocator, "zig-{s}-{s}", .{ ur.NATIVE_TARGET, version });
    var zig_dir: std.fs.Dir = undefined;
    if (data_dir.openDir(zig_dir_name.items, .{})) |value| {
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
        try install_target_spec(version, target_specs);
        zig_dir = try data_dir.openDir(zig_dir_name.items, .{});
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

fn install_target_spec(version: []const u8, target_spec: ur.TargetSpecs) !void {
    var zig_dir_name: std.ArrayList(u8) = .empty;
    try zig_dir_name.print(allocator, "zig-{s}-{s}", .{ ur.NATIVE_TARGET, version });
    if (data_dir.access(zig_dir_name.items, .{})) |_| {
        return;
    } else |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    }

    const FileType = enum { zip, tar_xz };
    var filetype: FileType = undefined;
    if (std.ascii.endsWithIgnoreCase(target_spec.tarball, ".zip")) {
        filetype = .zip;
    } else if (std.ascii.endsWithIgnoreCase(target_spec.tarball, ".tar.xz")) {
        filetype = .tar_xz;
    } else {
        return error.UnsupportedFileType;
    }
    var filename = try zig_dir_name.clone(allocator);
    switch (filetype) {
        .zip => try filename.print(allocator, ".zip", .{}),
        .tar_xz => try filename.print(allocator, ".tar.xz", .{}),
    }
    var file: std.fs.File = undefined;
    var download = true;
    if (cache_dir.createFile(filename.items, .{ .read = true, .exclusive = true })) |value| {
        file = value;
    } else |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
        file = try cache_dir.openFile(filename.items, .{});
        download = false;
    }
    defer file.close();
    errdefer file.close();
    // NOTE: std.zip and std.tar break on small buffer sizes for some reason?
    var buffer: [@max(std.fs.max_path_bytes, 1024 * 16)]u8 = undefined;
    if (download) {
        errdefer cache_dir.deleteFile(filename.items) catch {};
        var writer = file.writer(&buffer);
        const compressed_bytes = try ur.http_get(allocator, target_spec.tarball);
        try writer.interface.writeAll(compressed_bytes);
        try writer.interface.flush();
    }
    data_dir.makeDir(zig_dir_name.items) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const zig_dir = try data_dir.openDir(zig_dir_name.items, .{ .iterate = true });
    switch (filetype) {
        .zip => {
            var file_reader = file.reader(&buffer);
            try std.zip.extract(zig_dir, &file_reader, .{});
        },
        .tar_xz => {
            const file_reader = file.deprecatedReader();
            var decompress = try std.compress.xz.decompress(allocator, file_reader);
            const decompress_reader = decompress.reader();
            var decompress_adapter = decompress_reader.adaptToNewApi(&buffer);
            try std.tar.pipeToFileSystem(zig_dir, &decompress_adapter.new_interface, .{});
        },
    }
    var dir_it = zig_dir.iterate();
    var entries: std.ArrayList(std.fs.Dir.Entry) = .empty;
    while (try dir_it.next()) |entry| {
        try entries.append(allocator, entry);
    }
    if (entries.items.len == 1 and
        entries.items[0].kind == .directory)
    {
        const single_dir = try zig_dir.openDir(entries.items[0].name, .{ .iterate = true });
        dir_it = single_dir.iterate();
        const zig_path = try zig_dir.realpathAlloc(allocator, ".");
        while (try dir_it.next()) |entry| {
            const old = try single_dir.realpath(entry.name, &buffer);
            const new = try std.fs.path.join(allocator, &[_][]const u8{ zig_path, entry.name });
            try std.fs.renameAbsolute(old, new);
        }
    }
}
