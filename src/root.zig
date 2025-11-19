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
    url: []u8,
    checksum: []u8,
};

pub const RemoteIndexContent = std.AutoArrayHashMap(Spec, RemoteTarball);

pub const RemoteIndex = struct {
    arena: std.heap.ArenaAllocator,
    content: RemoteIndexContent,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }
};

pub fn fetch_remote_index(backing_allocator: std.mem.Allocator) !RemoteIndex {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var content = RemoteIndexContent.init(allocator);

    const s = try http_get(allocator, "https://ziglang.org/download/index.json");

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
            const remote_tarball = std.json.parseFromValueLeaky(struct {
                tarball: []u8,
                shasum: []u8,
                size: usize,
            }, allocator, kv.value_ptr.*, .{}) catch |err|
                {
                    if (err == error.DuplicateField or err == error.UnknownField or
                        err == error.MissingField or err == error.LengthMismatch or
                        err == error.UnexpectedToken)
                        continue
                    else
                        return err;
                };
            try content.put(.{ .version = version, .target = target }, .{ .url = remote_tarball.tarball, .checksum = remote_tarball.shasum });
        }
    }

    return .{ .content = content, .arena = arena };
}

pub fn http_get(allocator: std.mem.Allocator, url_undecorated: []const u8) ![]u8 {
    var url: std.ArrayList(u8) = .empty;
    defer url.deinit(allocator);
    if (std.mem.indexOfScalar(u8, url_undecorated, '?') == null) {
        try url.print(allocator, "{s}?source=ur", .{url_undecorated});
    } else {
        try url.print(allocator, "{s},source=ur", .{url_undecorated});
    }
    var client = std.http.Client{ .allocator = allocator };
    var writer = std.io.Writer.Allocating.init(allocator);
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

fn getAppPath(allocator: std.mem.Allocator, known_folder: known_folders.KnownFolder) ![]const u8 {
    const parent_path =
        try known_folders.getPath(std.Io{}, allocator, known_folder) orelse return error.NotFound;
    defer allocator.free(parent_path);
    const sub_path = switch (builtin.os.tag) {
        .macos => "com.faerryn." ++ config.name,
        else => config.name,
    };
    const path_parts = &[_][]const u8{ parent_path, sub_path };
    return try std.fs.path.join(allocator, path_parts);
}
fn openAppDir(allocator: std.mem.Allocator, known_folder: known_folders.KnownFolder, args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    const path = try getAppPath(allocator, known_folder);
    defer allocator.free(path);
    std.fs.cwd().makePath(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    return try std.fs.cwd().openDir(path, args);
}

pub fn Tio(comptime out_buf_size: usize, comptime err_buf_size: usize) type {
    return struct {
        out_file: std.fs.File,
        out_buf: [out_buf_size]u8 = std.mem.zeroes([out_buf_size]u8),
        out: std.fs.File.Writer = undefined,

        err_file: std.fs.File,
        err_buf: [err_buf_size]u8 = std.mem.zeroes([err_buf_size]u8),
        err: std.fs.File.Writer = undefined,

        initialized: bool = false,

        pub fn init() @This() {
            return .{
                .out_file = std.fs.File.stdout(),
                .err_file = std.fs.File.stderr(),
            };
        }

        pub fn deinit(self: *@This()) void {
            if (self.initialized) {
                self.out.interface.flush() catch {};
                self.err.interface.flush() catch {};
            }
            self.out_file.close();
            self.err_file.close();
        }

        pub fn interface(self: *@This()) TioInterface {
            if (!self.initialized) {
                self.initialized = true;
                self.out = self.out_file.writer(&self.out_buf);
                self.err = self.err_file.writer(&self.err_buf);
            }
            return .{
                .out = &self.out.interface,
                .err = &self.err.interface,
            };
        }
    };
}

pub const TioInterface = struct {
    out: *std.io.Writer,
    err: *std.io.Writer,
};

pub fn findBuildVersion(allocator: std.mem.Allocator, dir: std.fs.Dir) !?Version {
    if (dir.openFile("build.zig.zon", .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        var buffer = std.mem.zeroes([4096]u8);
        var reader = file.reader(&buffer);
        var source = try allocator.alloc(u8, stat.size + 1);
        defer allocator.free(source);
        @memset(source, 0);
        try reader.interface.readSliceAll(source[0..stat.size]);
        if (std.zon.parse.fromSlice(struct { minimum_zig_version: []const u8 }, allocator, source[0..stat.size :0], null, .{ .ignore_unknown_fields = true })) |zon| {
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

// Library of local zig installations
pub const Library = struct {
    data_dir: std.fs.Dir,
    cache_dir: std.fs.Dir,

    pub fn init() !@This() {
        var buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = fba.allocator();
        return .{
            .data_dir = try openAppDir(allocator, .data, .{ .iterate = true }),
            .cache_dir = try openAppDir(allocator, .cache, .{ .iterate = true }),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.data_dir.close();
        self.cache_dir.close();
    }

    pub const Iterator = struct {
        it: std.fs.Dir.Iterator,
        pub fn next(self: *@This()) !?Spec {
            while (try self.it.next()) |entry| {
                if (entry.kind != .directory) continue;
                const spec = Spec.parse(entry.name, .{}, .{}) catch continue;
                return spec;
            }
            return null;
        }
    };

    pub fn iterate(self: @This()) Iterator {
        return .{ .it = self.data_dir.iterate() };
    }

    pub fn openZigDir(self: @This(), spec: Spec, args: std.fs.Dir.OpenOptions) !std.fs.Dir {
        var buffer = std.mem.zeroes([std.fs.max_name_bytes]u8);
        return try self.data_dir.openDir(try spec.buffered(&buffer), args);
    }

    pub fn isInstalled(self: @This(), spec: Spec) !bool {
        var buffer = std.mem.zeroes([std.fs.max_name_bytes]u8);
        if (self.data_dir.access(try spec.buffered(&buffer), .{})) {
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
        if (self.data_dir.access(zig_dir_name, .{})) {
            return error.AlreadyInstalled;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        const FileType = enum { zip, tar_xz };
        const filetype: FileType =
            if (std.ascii.endsWithIgnoreCase(remote_tarball.url, ".zip"))
                .zip
            else if (std.ascii.endsWithIgnoreCase(remote_tarball.url, ".tar.xz"))
                .tar_xz
            else
                return error.UnsupportedFileType;
        switch (filetype) {
            .zip => try zig_dir_name_writer.print(".zip", .{}),
            .tar_xz => try zig_dir_name_writer.print(".tar.xz", .{}),
        }
        const filename = zig_dir_name_writer.buffered();
        var download = true;
        var file: std.fs.File = self.cache_dir.createFile(filename, .{ .read = true, .exclusive = true }) catch |err| file_block: {
            if (err != error.PathAlreadyExists) return err;
            download = false;
            break :file_block try self.cache_dir.openFile(filename, .{});
        };
        defer file.close();
        var buffer = std.mem.zeroes([4096]u8);
        if (download) {
            errdefer self.cache_dir.deleteFile(filename) catch {};
            var writer = file.writer(&buffer);
            const compressed_bytes = try http_get(allocator, remote_tarball.url);
            defer allocator.free(compressed_bytes);
            try writer.interface.writeAll(compressed_bytes);
            try writer.interface.flush();
        }

        try self.data_dir.makePath(zig_dir_name);
        errdefer self.data_dir.deleteTree(zig_dir_name) catch {};
        var zig_dir = try self.data_dir.openDir(zig_dir_name, .{ .iterate = true });
        defer zig_dir.close();
        switch (filetype) {
            .zip => {
                var file_reader = file.reader(&buffer);
                try std.zip.extract(zig_dir, &file_reader, .{});
            },
            .tar_xz => {
                const file_reader = file.deprecatedReader();
                var decompress = try std.compress.xz.decompress(allocator, file_reader);
                defer decompress.deinit();
                const decompress_reader = decompress.reader();
                var decompress_adapter = decompress_reader.adaptToNewApi(&buffer);
                try std.tar.pipeToFileSystem(zig_dir, &decompress_adapter.new_interface, .{});
            },
        }
        var dir_it = zig_dir.iterate();
        var entries: std.ArrayList(std.fs.Dir.Entry) = .empty;
        defer entries.deinit(allocator);
        while (try dir_it.next()) |entry| {
            try entries.append(allocator, entry);
        }
        if (entries.items.len == 1 and
            entries.items[0].kind == .directory)
        {
            var single_dir = try zig_dir.openDir(entries.items[0].name, .{ .iterate = true });
            defer single_dir.close();
            dir_it = single_dir.iterate();

            var buffer1 = std.mem.zeroes([std.fs.max_path_bytes]u8);
            var buffer2 = std.mem.zeroes([std.fs.max_path_bytes]u8);

            const zig_path = try zig_dir.realpath(".", &buffer1);
            while (try dir_it.next()) |entry| {
                const old = try single_dir.realpath(entry.name, &buffer2);
                const new = try std.fs.path.join(allocator, &[_][]const u8{ zig_path, entry.name });
                defer allocator.free(new);
                try std.fs.renameAbsolute(old, new);
            }
        }
    }

    // TODO: consider returning errors instead of an option?
    pub fn match(self: @This(), text: []u8) !?Spec {
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
