const std = @import("std");
const builtin = @import("builtin");
const ur = @import("ur");
const config = @import("config");

var stdout: *std.io.Writer = undefined;
var stderr: *std.io.Writer = undefined;

var allocator: std.mem.Allocator = undefined;

var args: [][:0]u8 = undefined;

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
    const subcommand = if (args.len > 2)
        std.meta.stringToEnum(enum { available, all, installed, help }, args[2]) orelse .help
    else
        .available;
    switch (subcommand) {
        .all, .available => {
            var index = try ur.fetch_remote_index(std.heap.page_allocator);
            defer index.deinit();
            var it = index.content.iterator();
            while (it.next()) |kv| {
                if (subcommand == .all or kv.key_ptr.target.is_executable())
                    try stdout.print("{f}\n", .{kv.key_ptr});
            }
            try stdout.flush();
        },
        .installed => {
            var specs = try ur.list_installed_specs(allocator);
            defer specs.deinit(allocator);
            for (specs.items) |spec| {
                try stdout.print("{f}\n", .{spec});
            }
        },
        .help => try help(),
    }
}

fn install() !void {
    if (args.len < 3) {
        try help();
        return;
    }
    var index = try ur.fetch_remote_index(std.heap.page_allocator);
    defer index.deinit();
    const spec = ur.Spec.parse(args[2], .{ .guess = true }) catch {
        try stderr.print("Error: could not parse '{s}'\n", .{args[2]});
        return;
    };

    const remote_tarball = index.content.get(spec) orelse {
        try stderr.print("Error: zig version '{f}' does not exist or not support architecture '{f}'\n", .{ spec.version, spec.target });
        return;
    };
    try stdout.print("Installing zig {f}...\n", .{spec});
    try stdout.flush();
    try ur.install_remote_tarball(spec, remote_tarball);
}

fn shim() !void {
    var args_shift: usize = 2;
    const spec: ur.Spec =
        spec_block: {
            // Check if VERSION is specified
            if (args.len > 2) {
                if (ur.Spec.parse(args[2], .{ .guess = true })) |spec| {
                    args_shift += 1;
                    break :spec_block spec;
                } else |_| {}
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
                    if (ur.Version.parse(zon.minimum_zig_version)) |version| {
                        break :spec_block .{
                            .target = ur.Target.NATIVE,
                            .version = version,
                        };
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
            // Check for latest installed version
            var local_specs = try ur.list_installed_specs(allocator);
            defer local_specs.deinit(allocator);
            var latest_spec: ?ur.Spec = null;
            for (local_specs.items) |spec| {
                if (spec.target.is_executable() and
                    (latest_spec == null or
                        spec.version.gt(latest_spec.?.version)))
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
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    {
        var zig_dir_name: std.ArrayList(u8) = .empty;
        try zig_dir_name.print(allocator, "{f}", .{spec});
        var install_dir = try ur.openAppDir(.install, .{});
        defer install_dir.close();
        var zig_dir: std.fs.Dir = try install_dir.openDir(zig_dir_name.items, .{});
        defer zig_dir.close();
        // TODO: Install as needed
        var buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
        const zig_exe = try zig_dir.realpath(if (builtin.os.tag == .windows) "zig.exe" else "zig", &buffer);
        try argv.append(allocator, zig_exe);
        for (args[args_shift..]) |arg| {
            try argv.append(allocator, arg);
        }
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
        @compileError("No shim mechanism!");
    }
}
