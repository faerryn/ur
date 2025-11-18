const std = @import("std");
const builtin = @import("builtin");
const ur = @import("ur");
const config = @import("config");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer {
        _ = gpa.detectLeaks();
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    var tio_context = ur.Tio(1024, 0).init();
    defer tio_context.deinit();
    const tio = tio_context.interface();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const Subcommand = enum { help, version, list, install, zig };
    const subcommand: Subcommand, const argshift: usize = subcommand_block: {
        if (args.len < 2) {
            break :subcommand_block .{ .help, 0 };
        }
        if (std.meta.stringToEnum(Subcommand, args[1])) |subcommand| {
            break :subcommand_block .{ subcommand, 2 };
        }
        break :subcommand_block .{ .help, 0 };
    };
    switch (subcommand) {
        .help => try help(tio),
        .version => try print_version(tio),
        .list => try list(allocator, tio, args[argshift..]),
        .install => try install(allocator, tio, args[argshift..]),
        .zig => try shim(allocator, tio, args[argshift..]),
    }
}

fn help(tio: ur.TioInterface) !void {
    try tio.out.print(
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
    , .{ config.name, config.name });
}

fn print_version(tio: ur.TioInterface) !void {
    try tio.out.print("{s} {s}\n", .{ config.name, config.version });
}

fn list(allocator: std.mem.Allocator, tio: ur.TioInterface, args: [][:0]u8) !void {
    const subcommand = if (args.len > 0)
        std.meta.stringToEnum(enum { available, all, installed }, args[0]) orelse {
            try help(tio);
            return;
        }
    else
        .available;
    switch (subcommand) {
        .all, .available => {
            var index = try ur.fetch_remote_index(allocator);
            defer index.deinit();
            var it = index.content.iterator();
            while (it.next()) |kv| {
                if (subcommand == .all or kv.key_ptr.target.is_executable())
                    try tio.out.print("{f}\n", .{kv.key_ptr});
            }
            try tio.out.flush();
        },
        .installed => {
            var specs = try ur.listInstalledSpecs(allocator);
            defer specs.deinit(allocator);
            for (specs.items) |spec| {
                try tio.out.print("{f}\n", .{spec});
            }
        },
    }
}

fn install(allocator: std.mem.Allocator, tio: ur.TioInterface, args: [][:0]u8) !void {
    const spec: ur.Spec = spec_block: {
        if (args.len > 1) {
            break :spec_block ur.Spec.parse(args[0], .{ .guess = true }) catch {
                try tio.err.print("Error: could not parse '{s}'\n", .{args[0]});
                return;
            };
        }
        if (try findBuildVersion(allocator, std.fs.cwd())) |version| {
            break :spec_block .{
                .target = ur.Target.NATIVE,
                .version = version,
            };
        }
        // TODO: install latest version of zig
        try help(tio);
        return;
    };

    // TODO: avoid reinstalling already installed versions of zig

    var index = try ur.fetch_remote_index(allocator);
    defer index.deinit();
    const remote_tarball = index.content.get(spec) orelse {
        try tio.err.print("Error: zig version '{f}' does not exist or not support architecture '{f}'\n", .{ spec.version, spec.target });
        return;
    };
    try tio.out.print("Installing zig {f}...\n", .{spec});
    try tio.out.flush();
    try ur.install_remote_tarball(allocator, spec, remote_tarball);
}

fn findBuildVersion(allocator: std.mem.Allocator, dir: std.fs.Dir) !?ur.Version {
    if (dir.openFile("build.zig.zon", .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        var buffer = std.mem.zeroes([1024]u8);
        var reader = file.reader(&buffer);
        var source = try allocator.alloc(u8, stat.size + 1);
        defer allocator.free(source);
        @memset(source, 0);
        try reader.interface.readSliceAll(source[0..stat.size]);
        if (std.zon.parse.fromSlice(struct { minimum_zig_version: []const u8 }, allocator, source[0..stat.size :0], null, .{ .ignore_unknown_fields = true })) |zon| {
            defer allocator.free(zon.minimum_zig_version);
            if (ur.Version.parse(zon.minimum_zig_version)) |version| {
                return version;
            } else |_| {}
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

    var parent = try dir.openDir("..", .{});
    defer parent.close();
    var buffer1 = std.mem.zeroes([std.fs.max_path_bytes]u8);
    var buffer2 = std.mem.zeroes([std.fs.max_path_bytes]u8);
    const dir_path = try dir.realpath(".", &buffer1);
    const parent_path = try parent.realpath(".", &buffer2);
    if (std.mem.eql(u8, dir_path, parent_path)) {
        return null;
    }
    return try findBuildVersion(allocator, parent);
}

fn shim(allocator: std.mem.Allocator, tio: ur.TioInterface, parent_args: [][:0]u8) !void {
    var args = parent_args;
    const spec: ur.Spec =
        spec_block: {
            // Check if VERSION is specified
            if (args.len > 0) {
                if (ur.Spec.parse(args[0], .{ .guess = true })) |spec| {
                    args = args[1..];
                    break :spec_block spec;
                } else |_| {}
            }
            // Check if build.zig.zon specifies version
            if (try findBuildVersion(allocator, std.fs.cwd())) |version| {
                break :spec_block .{
                    .target = ur.Target.NATIVE,
                    .version = version,
                };
            }
            // Check for latest installed version
            var local_specs = try ur.listInstalledSpecs(allocator);
            defer local_specs.deinit(allocator);
            var latest_spec: ?ur.Spec = null;
            for (local_specs.items) |spec| {
                if (spec.target.is_executable() and
                    if (latest_spec) |ls| spec.version.gt(ls.version) else true)
                {
                    latest_spec = spec;
                }
            }
            if (latest_spec) |spec| {
                break :spec_block spec;
            }
            // TODO: Check online for latest tagged version
            return error.Unimplemented;
        };

    var buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
    var argv: std.ArrayList([]u8) = .empty;
    defer argv.deinit(allocator);
    {
        var zig_dir_name: std.ArrayList(u8) = .empty;
        defer zig_dir_name.deinit(allocator);
        try zig_dir_name.print(allocator, "{f}", .{spec});
        var install_dir = try ur.openAppDir(allocator, .data, .{});
        defer install_dir.close();
        var zig_dir: std.fs.Dir = install_dir.openDir(zig_dir_name.items, .{}) catch |err| {
            if (err != error.FileNotFound) return err;
            // TODO: Install zig as needed
            try tio.out.print("Installing zig...\n", .{});
            return error.Unimplemented;
        };
        defer zig_dir.close();
        const zig_exe = try zig_dir.realpath(if (builtin.os.tag == .windows) "zig.exe" else "zig", &buffer);
        try argv.append(allocator, zig_exe);
    }
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    // Execv will prevent us from using GPA's memory leak detection
    if (std.process.can_execv and builtin.mode != .Debug) {
        const err = std.process.execv(argv.allocator, argv.content);
        argv.deinit();
        return err;
    } else if (std.process.can_spawn) {
        var child = std.process.Child.init(argv.items, allocator);
        _ = try child.spawnAndWait();
    } else {
        @compileError("No shim mechanism!");
    }
}
