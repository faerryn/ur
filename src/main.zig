const std = @import("std");
const builtin = @import("builtin");
const ur = @import("ur");
const config = @import("config");

pub fn main(init: std.process.Init) void {
    var tio_context = ur.Tio(if (builtin.mode == .debug) 0 else 4096, 0).init(init.io);
    // TODO: We probably want to deinitialize this before execv!
    defer tio_context.deinit();
    const tio = tio_context.interface();

    start(.{ .tio = tio, .init = init }) catch |err| {
        tio.err.print("error: {}\n", .{ .err = err }) catch {};
    };
}

fn start(g: ur.Global) !void {
    var arena = std.heap.ArenaAllocator.init(g.init.gpa);
    defer arena.deinit();
    const args = try g.init.minimal.args.toSlice(arena.allocator());

    var library = try ur.Library.init(g);
    defer library.deinit(g);

    var index = ur.RemoteIndex.init(g);
    defer index.deinit(g);
    // TODO: don't hardcode remote index URLs
    try index.request_remote_index(g, .Zig, "https://ziglang.org/download/index.json");
    try index.request_remote_index(g, .Zls, "https://builds.zigtools.org/index.json");

    const default_version = blk: {
        if (ur.findBuildVersion(g, std.Io.Dir.cwd())) |v| {
            break :blk v;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
        if (try library.latest_native(g)) |spec| {
            break :blk spec.version;
        }
        break :blk null;
    };

    const spec_opts = ur.SpecParseOptions{ .infer_target = ur.Target.NATIVE, .infer_version = default_version };
    const target_opts = ur.TargetParseOptions{ .infer_cpu = ur.Target.NATIVE.cpu, .infer_os = ur.Target.NATIVE.os };
    if (ur.Spec.parse(args[0], spec_opts, target_opts)) |spec| {
        return shim(g, &library, &index, spec, args[1..]);
    } else |_| if (args.len > 1) {
        if (ur.Spec.parse(args[1], spec_opts, target_opts)) |spec| {
            return shim(g, &library, &index, spec, args[2..]);
        } else |_| {}
    }

    const Subcommand = enum { help, version, list, install, uninstall };
    const subcommand: Subcommand, const argshift: usize = subcommand_block: {
        if (args.len < 2) {
            break :subcommand_block .{ .help, 0 };
        }
        if (std.meta.stringToEnum(Subcommand, args[1])) |subcommand| {
            break :subcommand_block .{ subcommand, 1 };
        }
        break :subcommand_block .{ .help, 0 };
    };
    switch (subcommand) {
        .help => try subcommand_help(g),
        .version => try subcommand_version(g),
        .list => try subcommand_list(g, &library, &index, args[argshift..]),
        .install => try subcommand_install(g, &library, &index, args[argshift..]),
        .uninstall => try subcommand_uninstall(g, &library, args[argshift..]),
    }
}

fn subcommand_help(g: ur.Global) !void {
    try g.tio.out.print(
        \\A zig/zls version manager, written in zig.
        \\
        \\Usage: {s} [COMMAND] [<ARGS>]
        \\Usage: zig [<ARGS>]
        \\Usage: zls [<ARGS>]
        \\
        \\Commands:
        \\  help                    Display this help message.
        \\  install [SPEC]...       Install SPEC.
        \\  uninstall [SPEC]...     Uninstall SPEC
        \\  list (all|installed)?   List versions for your architecture, or all versions, or just the ones installed.
        \\  (SPEC)? [<ARGS>]        Run program specified by SPEC, passing [<ARGS>].
        \\  version                 Print the version of {s}.
        \\
        \\Specs:
        \\  (zig|zls)?(-ARCH)?(-OS)?(-VERSION)?
        \\
    , .{ config.name, config.name });
}

fn subcommand_version(g: ur.Global) !void {
    try g.tio.out.print("{s} {s}\n", .{ config.name, config.version });
}

fn subcommand_list(g: ur.Global, library: *ur.Library, index: *ur.RemoteIndex, args: []const [:0]const u8) !void {
    const subcommand = subcommand_block: {
        if (args.len > 1) {
            if (std.meta.stringToEnum(enum { available, all, installed }, args[1])) |subcommand| {
                break :subcommand_block subcommand;
            }
            try subcommand_help(g);
            return;
        }
        break :subcommand_block .available;
    };

    var list = std.ArrayList(ur.Spec).empty;
    defer list.deinit(g.init.gpa);

    switch (subcommand) {
        .all, .available => {
            index.fetch_all(g) catch |err| {
                if (err == error.NameServerFailure) {
                    g.tio.err.print("Error: no internet access.\n", .{}) catch {};
                    return;
                }
                return err;
            };
            var it = index.content.iterator();
            while (it.next()) |kv| {
                if (subcommand == .all or kv.key_ptr.target.isNative())
                    try list.append(g.init.gpa, kv.key_ptr.*);
            }
            try g.tio.out.flush();
        },
        .installed => {
            var it = library.iterator();
            while (try it.next(g)) |spec| {
                try list.append(g.init.gpa, spec);
            }
        },
    }

    std.mem.sortUnstable(ur.Spec, list.items, {}, ur.Spec.lessThanFn);
    for (list.items) |spec| {
        try g.tio.out.print("{f}\n", .{spec});
    }
}

fn subcommand_install(g: ur.Global, library: *ur.Library, index: *ur.RemoteIndex, args: []const [:0]const u8) !void {
    index.fetch_all(g) catch |err| {
        if (err == error.NameServerFailure) {
            g.tio.err.print("Error: no internet access.\n", .{}) catch {};
            return;
        }
        return err;
    };
    const default_version = if (index.latest_native()) |spec| spec.version else null;
    var specs = std.ArrayList(ur.Spec).empty;
    defer specs.deinit(g.init.gpa);

    // Check if SPEC is specified
    if (args.len > 1) {
        for (args[1..]) |arg| {
            if (ur.Spec.parse(
                arg,
                .{ .infer_product = .Zig, .infer_target = ur.Target.NATIVE, .infer_version = default_version },
                .{ .infer_cpu = ur.Target.NATIVE.cpu, .infer_os = ur.Target.NATIVE.os },
            )) |spec| {
                try specs.append(g.init.gpa, spec);
            } else |_| {
                g.tio.err.print("Error: could not parse '{s}'.\n", .{args[1]}) catch {};
            }
        }
    } else if (default_version) |version| {
        // Use default version if available
        try specs.append(g.init.gpa, ur.Spec{
            .product = .Zig,
            .target = ur.Target.NATIVE,
            .version = version,
        });
    } else {
        // Somehow there is nothing!
        try g.tio.out.print("There does not seem to be a native version of zig for your system. You may be able to install a foreign version and run it using emulation.\n", .{});
    }

    for (specs.items) |spec| {
        if (try library.isInstalled(g, spec)) {
            g.tio.out.print("{f} is already installed, skipping.\n", .{spec}) catch {};
        } else {
            try install_spec(g, library, index, spec);
        }
    }
}

fn subcommand_uninstall(g: ur.Global, library: *ur.Library, args: []const [:0]const u8) !void {
    var specs = std.ArrayList(ur.Spec).empty;
    defer specs.deinit(g.init.gpa);

    // Try to parse SPEC
    if (args.len > 1) {
        for (args[1..]) |arg| {
            if (try library.match(g, args[1])) |spec| {
                try specs.append(g.init.gpa, spec);
            } else {
                g.tio.err.print("{s} is not installed, skipping\n", .{arg}) catch {};
            }
        }
    } else {
        try subcommand_help(g);
        return;
    }

    var buffer = std.mem.zeroes([std.fs.max_name_bytes]u8);
    for (specs.items) |spec| {
        try library.data_dir.deleteTree(g.init.io, try spec.buffered(&buffer));
        try g.tio.out.print("Uninstalled {f} .\n", .{spec});
    }
}

fn shim(g: ur.Global, library: *ur.Library, index: *ur.RemoteIndex, spec: ur.Spec, args: []const [:0]const u8) !void {
    if (!try library.isInstalled(g, spec)) {
        try install_spec(g, library, index, spec);
    }
    var spec_dir = try library.openSpecDir(g, spec, .{});
    defer spec_dir.close(g.init.io);

    var spec_dir_path = std.mem.zeroes([std.fs.max_path_bytes]u8);
    const spec_dir_path_len = try spec_dir.realPath(g.init.io, &spec_dir_path);

    g.tio.out.flush() catch {};
    g.tio.err.flush() catch {};

    var buffer = std.mem.zeroes([std.fs.max_name_bytes]u8);
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print(if (builtin.os.tag == .windows) "{f}.exe" else "{f}", .{spec.product});
    const exe_name = writer.buffered();

    const exe_path = try std.fs.path.join(g.init.gpa, &[_][]const u8{ spec_dir_path[0..spec_dir_path_len], exe_name });
    defer g.init.gpa.free(exe_path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(g.init.gpa);
    try argv.append(g.init.gpa, exe_path);
    for (args) |arg| {
        try argv.append(g.init.gpa, arg);
    }

    // if zls, try to update path against actual zig
    if (spec.product == .Zls) {
        var spec_zig = spec;
        spec_zig.product = .Zig;
        if (library.openSpecDir(g, spec_zig, .{})) |zig_spec_dir| {
            defer zig_spec_dir.close(g.init.io);
            var zig_spec_path_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
            const zig_spec_path_len = try zig_spec_dir.realPath(g.init.io, &zig_spec_path_buf);
            const oldpath = g.init.environ_map.get("PATH") orelse "";
            const newpath = try g.init.gpa.alloc(u8, oldpath.len + zig_spec_path_len + 1);
            errdefer g.init.gpa.free(newpath);
            var newpath_writer = std.Io.Writer.fixed(newpath);
            try newpath_writer.print("{s}{c}{s}", .{ zig_spec_path_buf[0..zig_spec_path_len], std.fs.path.delimiter, oldpath });
            try g.init.environ_map.put("PATH", newpath);
        } else |_| {
            g.tio.err.print("Failed to find {f} required by {f}.\n", .{ spec_zig, spec }) catch {};
        }
    }

    // Execv will prevent us from using GPA's memory leak detection, so we disable it during debug
    if (std.process.can_replace and builtin.mode != .debug) {
        return std.process.replace(g.init.io, .{ .argv = argv.items, .environ_map = g.init.environ_map });
    } else if (std.process.can_spawn) {
        var child = try std.process.spawn(g.init.io, .{ .argv = argv.items, .environ_map = g.init.environ_map });
        const term = try child.wait(g.init.io);
        // Exit on release with the appropriate exit code
        if (builtin.mode != .debug) std.process.exit(term.exited);
    } else {
        @compileError("Error: No shim mechanism available for this target.");
    }
}

fn install_spec(g: ur.Global, library: *ur.Library, index: *ur.RemoteIndex, spec: ur.Spec) !void {
    if (try library.isInstalled(g, spec)) return;

    try index.fetch_all(g);
    const remote_tarball = index.content.get(spec) orelse {
        g.tio.err.print("Error: {f} version '{f}' does not exist or not support architecture '{f}'\n", .{ spec.product, spec.version, spec.target }) catch {};
        return;
    };
    try g.tio.out.print("Starting to install {f} .\n", .{spec});
    try g.tio.out.flush();

    try library.installRemoteTarball(g, spec, remote_tarball);
    try g.tio.out.print("Finished installing {f} .\n", .{spec});
}
