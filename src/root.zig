const std = @import("std");
const builtin = @import("builtin");
const known_folders = @import("known_folders");
const config = @import("config");

pub const ParseError = error{Malformed} || std.fmt.ParseIntError;

pub const TargetParseOptions = struct {
    infer_cpu: bool = false, // just parse as os and infer cpu
    infer_os: bool = false, // just parse as cpu and infer os
};

pub const SpecParseOptions = struct {
    infer_prefix: bool = false, // parse with or without the "zig-" prefix
    infer_target: bool = false, // just parse as version and infer target
    infer_version: ?Version = null, // just parse as target and infer version
};

// zig-target-version
pub const Spec = struct {
    target: Target,
    version: Version,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("zig-{f}-{f}", .{ self.target, self.version });
    }

    pub fn buffered(self: @This(), buffer: *[std.fs.max_name_bytes]u8) ![]u8 {
        var writer = std.Io.Writer.fixed(buffer);
        try writer.print("{f}", .{self});
        return writer.buffered();
    }

    pub fn parse(
        text: []const u8,
        spec_opts: SpecParseOptions,
        target_opts: TargetParseOptions,
    ) ParseError!@This() {
        if (Spec.parse_impl(text, spec_opts.infer_prefix, target_opts)) |spec| {
            return spec;
        } else |_| {}
        if (spec_opts.infer_target) {
            if (Version.parse(text)) |version| {
                return .{ .target = .NATIVE, .version = version };
            } else |_| {}
        }
        if (spec_opts.infer_version) |version| {
            if (Target.parse(text, target_opts)) |target| {
                return .{ .target = target, .version = version };
            } else |_| {}
        }
        return ParseError.Malformed;
    }

    fn parse_impl(text: []const u8, infer_prefix: bool, target_opts: TargetParseOptions) !@This() {
        const firstDash = std.mem.indexOfScalar(u8, text, '-') orelse return ParseError.Malformed;
        const lastDash = std.mem.lastIndexOfScalar(u8, text, '-') orelse return ParseError.Malformed;
        const version = try Version.parse(text[lastDash + 1 ..]);
        const has_prefix = std.mem.eql(u8, "zig", text[0..firstDash]);
        if (!has_prefix and !infer_prefix) return ParseError.Malformed;
        const target_str = if (has_prefix) text[firstDash + 1 .. lastDash] else text[0..firstDash];
        const target = try Target.parse(target_str, target_opts);
        return .{
            .target = target,
            .version = version,
        };
    }
};

// cpu-os
pub const Target = struct {
    cpu: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,

    pub const NATIVE: @This() = .{
        .cpu = builtin.cpu.arch,
        .os = builtin.os.tag,
    };

    pub fn isNative(self: @This()) bool {
        return eql(self, NATIVE);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("{s}-{s}", .{ @tagName(self.cpu), @tagName(self.os) });
    }

    pub fn fromTagNames(cpu: []const u8, os: []const u8) ParseError!@This() {
        return .{
            .cpu = std.meta.stringToEnum(std.Target.Cpu.Arch, cpu) orelse return ParseError.Malformed,
            .os = std.meta.stringToEnum(std.Target.Os.Tag, os) orelse return ParseError.Malformed,
        };
    }

    pub fn parse(text: []const u8, opts: TargetParseOptions) ParseError!@This() {
        if (std.mem.indexOfScalar(u8, text, '-')) |dash| {
            return try fromTagNames(text[0..dash], text[dash + 1 ..]);
        } else {
            const try_cpu = std.meta.stringToEnum(std.Target.Cpu.Arch, text);
            const try_os = std.meta.stringToEnum(std.Target.Os.Tag, text);
            if (try_cpu == null and try_os == null) return ParseError.Malformed;
            const cpu = try_cpu orelse if (opts.infer_cpu) NATIVE.cpu else return ParseError.Malformed;
            const os = try_os orelse if (opts.infer_os) NATIVE.os else return ParseError.Malformed;
            return .{ .cpu = cpu, .os = os };
        }
    }

    pub fn eql(lhs: @This(), rhs: @This()) bool {
        return std.meta.eql(lhs, rhs);
    }
};

// major.minor.patch
pub const Version = struct {
    parts: [3]u8,

    fn toU24(self: @This()) u24 {
        return std.mem.readInt(u24, &self.parts, .big);
    }

    pub fn eql(self: @This(), other: @This()) bool {
        return self.toU24() == other.toU24();
    }

    pub fn gt(self: @This(), other: @This()) bool {
        return self.toU24() > other.toU24();
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("{}.{}.{}", .{ self.parts[0], self.parts[1], self.parts[2] });
    }

    pub fn parse(text: []const u8) ParseError!@This() {
        var it = std.mem.splitScalar(u8, text, '.');
        var parts = std.mem.zeroes([3]u8);
        var len: usize = 0;
        while (it.next()) |piece| {
            if (len == 3) return ParseError.Malformed;
            parts[len] = try parseDecimal(piece);
            len += 1;
        }
        if (len != 3) return ParseError.Malformed;
        return .{ .parts = parts };
    }
};

fn parseDecimal(text: []const u8) ParseError!u8 {
    for (text) |c| if (!std.ascii.isDigit(c)) return ParseError.Malformed;
    return try std.fmt.parseInt(u8, text, 10);
}

pub const RemoteTarball = struct {
    tarball: []u8,
    shasum: []u8,
    size: usize,
};

pub const RemoteIndexContent = std.AutoHashMap(Spec, RemoteTarball);

pub const RemoteIndex = struct {
    arena: std.heap.ArenaAllocator,
    content: RemoteIndexContent,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    // Returns null if content is empty (should be unlikely)
    pub fn defaultRemoteSpec(self: @This()) ?Spec {
        var candidate: ?Spec = null;
        var key_iterator = self.content.keyIterator();
        while (key_iterator.next()) |spec| {
            if (spec.target.isNative()) {
                if (candidate) |other| {
                    if (spec.version.gt(other.version)) {
                        candidate = spec.*;
                    }
                } else {
                    candidate = spec.*;
                }
            }
        }
        return candidate;
    }
};

pub fn fetch_remote_index(io: std.Io, backing_allocator: std.mem.Allocator) !RemoteIndex {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var content = RemoteIndexContent.init(allocator);

    const s = try http_get(io, allocator, "https://ziglang.org/download/index.json");

    const index_value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, s, .{});

    var index_it = switch (index_value) {
        .object => |value| value.iterator(),
        else => return ParseError.Malformed,
    };
    while (index_it.next()) |index_kv| {
        // TODO: handle master branch
        if (std.mem.eql(u8, "master", index_kv.key_ptr.*)) continue;
        const version = try Version.parse(index_kv.key_ptr.*);
        var version_it = index_kv.value_ptr.object.iterator();
        while (version_it.next()) |kv| {
            const target = Target.parse(kv.key_ptr.*, .{}) catch |err| {
                if (err == ParseError.Malformed) continue else return err;
            };
            const remote_tarball = std.json.parseFromValueLeaky(RemoteTarball, allocator, kv.value_ptr.*, .{}) catch |err|
                {
                    if (err == error.DuplicateField or err == error.UnknownField or
                        err == error.MissingField or err == error.LengthMismatch or
                        err == error.UnexpectedToken)
                        continue
                    else
                        return err;
                };
            try content.put(.{ .version = version, .target = target }, remote_tarball);
        }
    }

    return .{ .content = content, .arena = arena };
}

pub fn http_get(io: std.Io, allocator: std.mem.Allocator, url_undecorated: []const u8) ![]u8 {
    var url: std.ArrayList(u8) = .empty;
    defer url.deinit(allocator);
    if (std.mem.indexOfScalar(u8, url_undecorated, '?') == null) {
        try url.print(allocator, "{s}?source=ur", .{url_undecorated});
    } else {
        try url.print(allocator, "{s},source=ur", .{url_undecorated});
    }
    var client = std.http.Client{ .io = io, .allocator = allocator };
    var writer = std.Io.Writer.Allocating.init(allocator);
    const result = try client.fetch(.{
        .response_writer = &writer.writer,
        .location = .{ .url = url.items },
        .method = .GET,
    });
    if (result.status.class() != .success) {
        return error.GetFailed;
    }
    return try writer.toOwnedSlice();
}

fn getAppPath(io: std.Io, allocator: std.mem.Allocator, environ: *std.process.Environ.Map, known_folder: known_folders.KnownFolder) ![]const u8 {
    const parent_path =
        try known_folders.getPath(io, allocator, environ, known_folder) orelse return error.NotFound;
    defer allocator.free(parent_path);
    const sub_path = switch (builtin.os.tag) {
        .macos => "com.faerryn." ++ config.name,
        else => config.name,
    };
    const path_parts = &[_][]const u8{ parent_path, sub_path };
    return try std.fs.path.join(allocator, path_parts);
}
fn openAppDir(io: std.Io, allocator: std.mem.Allocator, environ: *std.process.Environ.Map, known_folder: known_folders.KnownFolder, args: std.Io.Dir.OpenOptions) !std.Io.Dir {
    const path = try getAppPath(io, allocator, environ, known_folder);
    defer allocator.free(path);
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    return try std.Io.Dir.cwd().openDir(io, path, args);
}

pub fn Tio(comptime out_buf_size: usize, comptime err_buf_size: usize) type {
    return struct {
        initialized: bool = false,
        io: std.Io,

        out_file: std.Io.File,
        out_buf: [out_buf_size]u8 = std.mem.zeroes([out_buf_size]u8),
        out: std.Io.File.Writer = undefined,

        err_file: std.Io.File,
        err_buf: [err_buf_size]u8 = std.mem.zeroes([err_buf_size]u8),
        err: std.Io.File.Writer = undefined,

        pub fn init(io: std.Io) @This() {
            return .{
                .io = io,
                .out_file = std.Io.File.stdout(),
                .err_file = std.Io.File.stderr(),
            };
        }

        pub fn deinit(self: *@This()) void {
            if (self.initialized) {
                self.out.interface.flush() catch {};
                self.err.interface.flush() catch {};
            }
            self.out_file.close(self.io);
            self.err_file.close(self.io);
        }

        pub fn interface(self: *@This()) TioInterface {
            if (!self.initialized) {
                self.initialized = true;
                self.out = self.out_file.writer(self.io, &self.out_buf);
                self.err = self.err_file.writer(self.io, &self.err_buf);
            }
            return .{
                .out = &self.out.interface,
                .err = &self.err.interface,
            };
        }
    };
}

pub const TioInterface = struct {
    out: *std.Io.Writer,
    err: *std.Io.Writer,
};

pub fn findBuildVersion(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) !?Version {
    if (dir.openFile(io, "build.zig.zon", .{})) |file| {
        defer file.close(io);
        const stat = try file.stat(io);
        var buffer = std.mem.zeroes([4096]u8);
        var reader = file.reader(io, &buffer);
        var source = try allocator.alloc(u8, stat.size + 1);
        defer allocator.free(source);
        @memset(source, 0);
        try reader.interface.readSliceAll(source[0..stat.size]);
        if (std.zon.parse.fromSliceAlloc(struct { minimum_zig_version: []const u8 }, allocator, source[0..stat.size :0], null, .{ .ignore_unknown_fields = true })) |zon| {
            defer allocator.free(zon.minimum_zig_version);
            if (Version.parse(zon.minimum_zig_version)) |version| {
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

    var parent = try dir.openDir(io, "..", .{});
    defer parent.close(io);
    var dir_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    var parent_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    const dir_len = try dir.realPath(io, &dir_buf);
    const parent_len = try parent.realPath(io, &parent_buf);
    if (std.mem.eql(u8, dir_buf[0..dir_len], parent_buf[0..parent_len])) {
        return null;
    }
    return try findBuildVersion(io, allocator, parent);
}

// Library of local zig installations
pub const Library = struct {
    io: std.Io,
    data_dir: std.Io.Dir,
    cache_dir: std.Io.Dir,

    pub fn init(io: std.Io, environ: *std.process.Environ.Map) !@This() {
        var buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = fba.allocator();
        return .{
            .io = io,
            .data_dir = try openAppDir(io, allocator, environ, .data, .{ .iterate = true }),
            .cache_dir = try openAppDir(io, allocator, environ, .cache, .{ .iterate = true }),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.data_dir.close(self.io);
        self.cache_dir.close(self.io);
    }

    pub const Iterator = struct {
        io: std.Io,
        it: std.Io.Dir.Iterator,
        pub fn next(self: *@This()) !?Spec {
            while (try self.it.next(self.io)) |entry| {
                if (entry.kind != .directory) continue;
                const spec = Spec.parse(entry.name, .{}, .{}) catch continue;
                return spec;
            }
            return null;
        }
    };

    pub fn iterate(self: @This()) Iterator {
        return .{ .io = self.io, .it = self.data_dir.iterate() };
    }

    pub fn openZigDir(self: @This(), spec: Spec, args: std.Io.Dir.OpenOptions) !std.Io.Dir {
        var buffer = std.mem.zeroes([std.fs.max_name_bytes]u8);
        return try self.data_dir.openDir(self.io, try spec.buffered(&buffer), args);
    }

    pub fn isInstalled(self: @This(), spec: Spec) !bool {
        var buffer = std.mem.zeroes([std.fs.max_name_bytes]u8);
        if (self.data_dir.access(self.io, try spec.buffered(&buffer), .{})) {
            return true;
        } else |err| {
            if (err == error.FileNotFound) return false;
            return err;
        }
    }

    pub fn installRemoteTarball(self: @This(), allocator: std.mem.Allocator, spec: Spec, remote_tarball: RemoteTarball) !void {
        var zig_dir_name_buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
        var zig_dir_name_writer = std.Io.Writer.fixed(&zig_dir_name_buffer);
        try zig_dir_name_writer.print("{f}", .{spec});
        const zig_dir_name = zig_dir_name_writer.buffered();
        // Exit if already installed
        if (self.data_dir.access(self.io, zig_dir_name, .{})) {
            return error.AlreadyInstalled;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        const FileType = enum { zip, tar_xz };
        const filetype: FileType =
            if (std.ascii.endsWithIgnoreCase(remote_tarball.tarball, ".zip"))
                .zip
            else if (std.ascii.endsWithIgnoreCase(remote_tarball.tarball, ".tar.xz"))
                .tar_xz
            else
                return error.UnsupportedFileType;
        switch (filetype) {
            .zip => try zig_dir_name_writer.print(".zip", .{}),
            .tar_xz => try zig_dir_name_writer.print(".tar.xz", .{}),
        }
        const filename = zig_dir_name_writer.buffered();
        var download = true;
        var file: std.Io.File = self.cache_dir.createFile(self.io, filename, .{ .read = true, .exclusive = true }) catch |err| file_block: {
            if (err != error.PathAlreadyExists) return err;
            download = false;
            break :file_block try self.cache_dir.openFile(self.io, filename, .{});
        };
        defer file.close(self.io);
        var buffer = std.mem.zeroes([4096]u8);
        if (download) {
            errdefer self.cache_dir.deleteFile(self.io, filename) catch {};
            var writer = file.writer(self.io, &buffer);
            const compressed_bytes = try http_get(self.io, allocator, remote_tarball.tarball);
            defer allocator.free(compressed_bytes);
            try writer.interface.writeAll(compressed_bytes);
            try writer.interface.flush();
        }

        try self.data_dir.createDirPath(self.io, zig_dir_name);
        errdefer self.data_dir.deleteTree(self.io, zig_dir_name) catch {};

        var zig_dir = try self.data_dir.openDir(self.io, zig_dir_name, .{ .iterate = true });
        defer zig_dir.close(self.io);
        var file_reader = file.reader(self.io, &buffer);
        switch (filetype) {
            .zip => {
                try std.zip.extract(zig_dir, &file_reader, .{});
                var it = zig_dir.iterate();
                const mono_entry = try it.next(self.io) orelse return error.EmptyZip;
                defer zig_dir.deleteTree(self.io, mono_entry.name) catch {};
                var mono_dir = try zig_dir.openDir(self.io, mono_entry.name, .{ .iterate = true });
                defer mono_dir.close(self.io);
                it = mono_dir.iterate();
                while (try it.next(self.io)) |entry| {
                    try mono_dir.rename(entry.name, zig_dir, entry.name, self.io);
                }
            },
            .tar_xz => {
                const buffer2 = try allocator.alloc(u8, 4096);
                var decompress = try std.compress.xz.Decompress.init(&file_reader.interface, allocator, buffer2);
                defer decompress.deinit();
                try std.tar.pipeToFileSystem(self.io, zig_dir, &decompress.reader, .{ .strip_components = 1 });
            },
        }
    }

    // TODO: consider returning errors instead of an option?
    pub fn match(self: @This(), text: []const u8) !?Spec {
        const try_target = Target.parse(text, .{ .infer_cpu = true, .infer_os = true }) catch null;
        const try_version = Version.parse(text) catch null;
        if (try_target == null and try_version == null) return null;
        var candidate: ?Spec = null;

        var it = self.iterate();
        while (try it.next()) |spec| {
            if (try_target) |target| {
                if (target.eql(spec.target)) {
                    if (candidate) |_| return null;
                    candidate = spec;
                }
            }
            if (try_version) |version| {
                if (version.eql(spec.version)) {
                    if (candidate) |_| return null;
                    candidate = spec;
                }
            }
        }
        return candidate;
    }
};

// TODO: Use mirrors from "https://ziglang.org/download/community-mirrors.txt"
// TODO: Verify tarballs with checksum and minisign
// TODO: Cache index.json and community-mirrors.txt
