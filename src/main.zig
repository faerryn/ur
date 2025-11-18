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
            var library = try ur.Library.init();
            defer library.deinit();
            var specs = try library.list(allocator);
            defer specs.deinit(allocator);
            for (specs.items) |spec| {
                try tio.out.print("{f}\n", .{spec});
            }
        },
    }
}

fn install(allocator: std.mem.Allocator, tio: ur.TioInterface, args: [][:0]u8) !void {
    const spec: ur.Spec = spec_block: {
        if (args.len > 0) {
            break :spec_block ur.Spec.parse(args[0], .{ .guess = true }) catch {
                try tio.err.print("Error: could not parse '{s}'\n", .{args[0]});
                return;
            };
        }
        if (try ur.findBuildVersion(allocator, std.fs.cwd())) |version| {
            break :spec_block .{
                .target = ur.Target.NATIVE,
                .version = version,
            };
        }
        // TODO: install latest version of zig
        try help(tio);
        return;
    };

    try ensure_installed(allocator, tio, spec);
}

// TODO: use actual errors here to signify different return states
fn ensure_installed(allocator: std.mem.Allocator, tio: ur.TioInterface, spec: ur.Spec) !void {
    var library = try ur.Library.init();
    defer library.deinit();
    var zig_dir_eu = library.openZigDir(spec, .{});
    if (zig_dir_eu) |*zig_dir| {
        zig_dir.close();
        return;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    var index = try ur.fetch_remote_index(allocator);
    defer index.deinit();
    const remote_tarball = index.content.get(spec) orelse {
        try tio.err.print("Error: zig version '{f}' does not exist or not support architecture '{f}'\n", .{ spec.version, spec.target });
        return;
    };
    try tio.out.print("Installing {f}...\n", .{spec});
    try tio.out.flush();

    try library.install_remote_tarball(allocator, spec, remote_tarball);
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
            if (try ur.findBuildVersion(allocator, std.fs.cwd())) |version| {
                break :spec_block .{
                    .target = ur.Target.NATIVE,
                    .version = version,
                };
            }
            // Check for latest installed version
            var library = try ur.Library.init();
            defer library.deinit();
            var local_specs = try library.list(allocator);
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

    var library = try ur.Library.init();
    defer library.deinit();

    try ensure_installed(allocator, tio, spec);
    var zig_dir = try library.openZigDir(spec, .{});
    defer zig_dir.close();

    var buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
    const zig_exe = try zig_dir.realpath(if (builtin.os.tag == .windows) "zig.exe" else "zig", &buffer);

    var argv: std.ArrayList([]u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zig_exe);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    // Execv will prevent us from using GPA's memory leak detection, so we disable it on Debug
    if (std.process.can_execv and builtin.mode != .Debug) {
        return std.process.execv(allocator, argv.items);
    } else if (std.process.can_spawn) {
        var child = std.process.Child.init(argv.items, allocator);
        const term = try child.spawnAndWait();
        // Exit on release with the appropriate exit code
        if (builtin.mode != .Debug) std.process.exit(term.Exited);
    } else {
        @compileError("No shim mechanism!");
    }
}
