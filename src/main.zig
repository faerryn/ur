const std = @import("std");
const builtin = @import("builtin");
const ur = @import("ur");
const config = @import("config");

pub fn main(init: std.process.Init) void {
    var tio_context = ur.Tio(if (builtin.mode == .Debug) 0 else 4096, 0).init(init.io);
    defer tio_context.deinit();
    const tio = tio_context.interface();

    app(init, tio) catch |err| {
        tio.err.print("error: {}\n", .{ .err = err }) catch {};
    };
}

fn app(init: std.process.Init, tio: ur.TioInterface) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const args = try init.minimal.args.toSlice(arena_allocator);

    var library = try ur.Library.init(init.io, init.environ_map);
    defer library.deinit();

    const Subcommand = enum { help, version, list, install, uninstall, zig };
    const subcommand: Subcommand, const argshift: usize = subcommand_block: {
        if (std.mem.eql(u8, "zig", args[0])) {
            break :subcommand_block .{ .zig, 1 };
        }
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
        .list => try list(init.io, init.gpa, tio, args[argshift..], &library),
        .install => try install(init.io, init.gpa, tio, args[argshift..], &library),
        .uninstall => try uninstall(init.io, tio, args[argshift..], &library),
        .zig => try shim(init.io, init.gpa, tio, args[argshift..], &library),
    }
}

fn help(tio: ur.TioInterface) !void {
    try tio.out.print(
        \\A zig version manager, written in zig.
        \\
        \\Usage: {s} [COMMAND] [<ARGS>]
        \\Usage: zig [<ARGS>]
        \\
        \\Commands:
        \\  help                    Display this help message.
        \\  install (SPEC)?         Install SPEC.
        \\  uninstall [SPEC]        Uninstall SPEC
        \\  list (all|installed)?   List versions for your architecture, or all versions, or just the ones installed.
        \\  zig (SPEC)? [<ARGS>]    Run SPEC with [<ARGS>].
        \\  version                 Print the version of {s}.
        \\
    , .{ config.name, config.name });
}

fn print_version(tio: ur.TioInterface) !void {
    try tio.out.print("{s} {s}\n", .{ config.name, config.version });
}

fn list(io: std.Io, allocator: std.mem.Allocator, tio: ur.TioInterface, args: []const [:0]const u8, library: *ur.Library) !void {
    const subcommand = subcommand_block: {
        if (args.len > 0) {
            if (std.meta.stringToEnum(enum { available, all, installed }, args[0])) |subcommand| {
                break :subcommand_block subcommand;
            }
            try help(tio);
            return;
        }
        break :subcommand_block .available;
    };
    switch (subcommand) {
        .all, .available => {
            var index = try ur.fetch_remote_index(io, allocator);
            defer index.deinit();
            var it = index.content.iterator();
            while (it.next()) |kv| {
                if (subcommand == .all or kv.key_ptr.target.isNative())
                    try tio.out.print("{f}\n", .{kv.key_ptr});
            }
            try tio.out.flush();
        },
        .installed => {
            var it = library.iterate();
            while (try it.next()) |spec| {
                try tio.out.print("{f}\n", .{spec});
            }
        },
    }
}

const GuessSpecOptions = struct {
    library: ?*ur.Library = null, // match against library if non-null
    shim_args0: bool = false, // allow non-SPEC args[0]
};
const GuessSpecResults = struct {
    spec: ur.Spec,
    argshift: usize,
};
// guess the spec for install and shim
fn guessSpec(io: std.Io, allocator: std.mem.Allocator, tio: ur.TioInterface, args: []const [:0]const u8, opts: GuessSpecOptions) !?GuessSpecResults {
    // TODO: somehow prepare a (not-slow) fallback default from the remote index
    const build_version = try ur.findBuildVersion(io, allocator, std.Io.Dir.cwd());
    // Check if SPEC is specified
    if (args.len > 0) {
        // TODO: Infer version somehow
        if (ur.Spec.parse(
            args[0],
            .{ .infer_prefix = true, .infer_target = true, .infer_version = build_version },
            .{ .infer_cpu = true, .infer_os = true },
        )) |spec| {
            return .{ .spec = spec, .argshift = 1 };
        } else |_| {}
        // Attempt to match against library
        if (opts.library) |library| {
            if (try library.match(args[0])) |spec| {
                return .{ .spec = spec, .argshift = 1 };
            }
        }
        if (!opts.shim_args0) {
            try tio.err.print("Error: could not parse '{s}'\n", .{args[0]});
            return null;
        }
    }
    // Check if build.zig.zon specifies version
    if (build_version) |version| {
        return .{ .spec = .{
            .target = ur.Target.NATIVE,
            .version = version,
        }, .argshift = 0 };
    }
    // Check for latest remote version
    var index = try ur.fetch_remote_index(io, allocator);
    defer index.deinit();
    if (index.defaultRemoteSpec()) |spec| return .{ .spec = spec, .argshift = 0 };
    // Somehow there is nothing!
    try tio.out.print("There does not seem to be a native version of zig for your architecture. You may try installing foreign architectures and running them with emulation.", .{});
    return null;
}

fn install(io: std.Io, allocator: std.mem.Allocator, tio: ur.TioInterface, args: []const [:0]const u8, library: *ur.Library) !void {
    const guess = try guessSpec(io, allocator, tio, args, .{}) orelse return;
    const spec = guess.spec;
    if (try library.isInstalled(spec)) {
        try tio.err.print("Error: {f} is already installed.\n", .{spec});
        return;
    }
    try ensure_installed(io, allocator, tio, spec, library);
}

// TODO: use actual errors here to signify different return states
fn ensure_installed(io: std.Io, allocator: std.mem.Allocator, tio: ur.TioInterface, spec: ur.Spec, library: *ur.Library) !void {
    if (try library.isInstalled(spec)) return;

    var index = try ur.fetch_remote_index(io, allocator);
    defer index.deinit();
    const remote_tarball = index.content.get(spec) orelse {
        try tio.err.print("Error: zig version '{f}' does not exist or not support architecture '{f}'\n", .{ spec.version, spec.target });
        return;
    };
    try tio.out.print("Starting to install {f} .\n", .{spec});
    try tio.out.flush();

    try library.installRemoteTarball(allocator, spec, remote_tarball);
    try tio.out.print("Finished installing {f} .\n", .{spec});
}

fn shim(io: std.Io, allocator: std.mem.Allocator, tio: ur.TioInterface, parent_args: []const [:0]const u8, library: *ur.Library) !void {
    const guess = try guessSpec(io, allocator, tio, parent_args, .{ .library = library, .shim_args0 = true }) orelse return;
    const spec = guess.spec;
    const args = parent_args[guess.argshift..];

    try ensure_installed(io, allocator, tio, spec, library);
    var zig_dir = try library.openZigDir(spec, .{});
    defer zig_dir.close(io);

    var zig_dir_path = std.mem.zeroes([std.fs.max_path_bytes]u8);
    const zig_dir_path_len = try zig_dir.realPath(io, &zig_dir_path);

    tio.out.flush() catch {};
    tio.err.flush() catch {};

    const zig_exe = try std.fs.path.join(allocator, &[_][]const u8{ zig_dir_path[0..zig_dir_path_len], if (builtin.os.tag == .windows) "zig.exe" else "zig" });
    defer allocator.free(zig_exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zig_exe);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    // Execv will prevent us from using GPA's memory leak detection, so we disable it on Debug
    if (std.process.can_replace and builtin.mode != .Debug) {
        return std.process.replace(io, .{ .argv = argv.items });
    } else if (std.process.can_spawn) {
        var child = try std.process.spawn(io, .{ .argv = argv.items });
        const term = try child.wait(io);
        // Exit on release with the appropriate exit code
        if (builtin.mode != .Debug) std.process.exit(term.exited);
    } else {
        @compileError("Error: No shim mechanism available for this target.");
    }
}

fn uninstall(io: std.Io, tio: ur.TioInterface, args: []const [:0]const u8, library: *ur.Library) !void {
    const spec = spec_block: {
        // Try to parse SPEC
        if (args.len > 0) {
            if (ur.Spec.parse(args[0], .{ .infer_prefix = true, .infer_target = true }, .{ .infer_cpu = true, .infer_os = true })) |spec| {
                if (try library.isInstalled(spec)) break :spec_block spec;
            } else |_| {}
            // Check if args[0] is a version or target of something installed
            if (try library.match(args[0])) |spec| break :spec_block spec;
            try tio.err.print("Error: could not parse '{s}'\n", .{args[0]});
        }
        try help(tio);
        return;
    };

    var buffer = std.mem.zeroes([std.fs.max_name_bytes]u8);
    try library.data_dir.deleteTree(io, try spec.buffered(&buffer));
    try tio.out.print("Uninstalled {f} .\n", .{spec});
}

// TODO: Avoid rebuilding library and index too many times. Singletons?
// TODO: Stick strings into some sort of localization file.
