const std = @import("std");
const builtin = @import("builtin");
const known_folders = @import("known_folders");
const config = @import("config");

pub const ParseError = error{Malformed} || std.fmt.ParseIntError;

pub const TargetParseOptions = struct {
    infer_cpu: ?std.Target.Cpu.Arch = null,
    infer_os: ?std.Target.Os.Tag = null,
};

pub const SpecParseOptions = struct {
    infer_product: ?Product = null,
    infer_target: ?Target = null,
    infer_version: ?Version = null,
};

// product-target@(cpu-os)-version
pub const Spec = struct {
    product: Product,
    target: Target,
    version: Version,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("{f}-{f}-{f}", .{ self.product, self.target, self.version });
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
        var dash_indices = std.mem.zeroes([3]usize);
        var dash_count: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '-') {
                if (i == 0 or i == text.len - 1) return ParseError.Malformed;
                if (dash_count >= dash_indices.len) return ParseError.Malformed;
                dash_indices[dash_count] = i;
                dash_count += 1;
            }
        }

        const spans_count: usize = dash_count + 1;
        var spans = std.mem.zeroes([4]struct { start: usize, stop: usize });
        for (0..spans_count) |i| {
            spans[i].start = if (i == 0) 0 else (dash_indices[i - 1] + 1);
            spans[i].stop = if (i == dash_count) text.len else dash_indices[i];
        }

        var cursor: usize = 0;

        const product = blk: {
            if (cursor < spans_count) {
                if (Product.parse(text[spans[cursor].start..spans[cursor].stop])) |p| {
                    cursor += 1;
                    break :blk p;
                } else |_| {}
            }
            if (spec_opts.infer_product) |p| break :blk p;
            return ParseError.Malformed;
        };

        const target = blk: {
            if (cursor + 1 < spans_count) {
                if (Target.parse(
                    text[spans[cursor].start..spans[cursor + 1].stop],
                    target_opts,
                )) |p| {
                    cursor += 2;
                    break :blk p;
                } else |_| {}
            } else if (cursor < spans_count) {
                if (Target.parse(
                    text[spans[cursor].start..spans[cursor].stop],
                    target_opts,
                )) |p| {
                    cursor += 1;
                    break :blk p;
                } else |_| {}
            }
            if (spec_opts.infer_target) |t| break :blk t;
            return ParseError.Malformed;
        };

        const version = blk: {
            if (cursor < spans_count) {
                if (Version.parse(text[spans[cursor].start..spans[cursor].stop])) |p| {
                    cursor += 1;
                    break :blk p;
                } else |_| {}
            }
            if (spec_opts.infer_version) |v| break :blk v;
            return ParseError.Malformed;
        };

        if (cursor < spans_count) return ParseError.Malformed;

        return .{
            .product = product,
            .target = target,
            .version = version,
        };
    }
};

pub const Product = enum {
    Zig,
    Zls,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("{s}", .{switch (self) {
            .Zig => "zig",
            .Zls => "zls",
        }});
    }
    pub fn parse(text: []const u8) ParseError!@This() {
        if (std.mem.eql(u8, "zig", text)) {
            return .Zig;
        }
        if (std.mem.eql(u8, "zls", text)) {
            return .Zls;
        }
        return ParseError.Malformed;
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
            const cpu = try_cpu orelse if (opts.infer_cpu) |cpu| cpu else return ParseError.Malformed;
            const os = try_os orelse if (opts.infer_os) |os| os else return ParseError.Malformed;
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
    content: RemoteIndexContent,
    work_queue: std.ArrayList(Work),

    const Work = struct {
        product: Product,
        url: []const u8,
    };

    pub fn init(g: Global) @This() {
        return .{
            .content = RemoteIndexContent.init(g.init.gpa),
            .work_queue = .empty,
        };
    }

    pub fn deinit(self: *@This(), g: Global) void {
        self.content.deinit();
        self.work_queue.deinit(g.init.gpa);
    }

    pub fn request_remote_index(self: *@This(), g: Global, product: Product, url: []const u8) !void {
        try self.work_queue.append(g.init.gpa, .{ .product = product, .url = url });
    }

    pub fn fetch_all(self: *@This(), g: Global) !void {
        for (self.work_queue.items) |work| {
            try self.fetch_remote_index(g, work.product, work.url);
        }
        self.work_queue.clearAndFree(g.init.gpa);
    }

    fn fetch_remote_index(self: *@This(), g: Global, product: Product, url: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(g.init.gpa);
        defer arena.deinit();
        const allocator = arena.allocator();
        const s = try http_get(g, allocator, url);
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
                const spec = Spec{ .product = product, .version = version, .target = target };
                const remote_tarball = std.json.parseFromValueLeaky(RemoteTarball, allocator, kv.value_ptr.*, .{}) catch |err|
                    {
                        if (err == error.DuplicateField or err == error.UnknownField or
                            err == error.MissingField or err == error.LengthMismatch or
                            err == error.UnexpectedToken)
                            continue
                        else
                            return err;
                    };

                const shasum = try g.init.gpa.dupe(u8, remote_tarball.shasum);
                errdefer g.init.gpa.free(shasum);
                const tarball = try g.init.gpa.dupe(u8, remote_tarball.tarball);
                errdefer g.init.gpa.free(tarball);

                try self.content.put(spec, .{
                    .size = remote_tarball.size,
                    .shasum = shasum,
                    .tarball = tarball,
                });
            }
        }
    }

    // Finds latest runnable spec
    pub fn latest_native(self: @This()) ?Spec {
        var candidate: ?Spec = null;
        var it = self.content.iterator();
        while (it.next()) |entry| {
            const spec = entry.key_ptr;
            if (!spec.target.isNative()) continue;
            if (candidate) |other| {
                if (spec.version.gt(other.version)) {
                    candidate = spec.*;
                }
            } else {
                candidate = spec.*;
            }
        }
        return candidate;
    }
};

pub fn http_get(g: Global, allocator: std.mem.Allocator, url_undecorated: []const u8) ![]u8 {
    var url: std.ArrayList(u8) = .empty;
    defer url.deinit(allocator);
    if (std.mem.indexOfScalar(u8, url_undecorated, '?') == null) {
        try url.print(allocator, "{s}?source=" ++ config.name, .{url_undecorated});
    } else {
        try url.print(allocator, "{s},source=" ++ config.name, .{url_undecorated});
    }
    var client = std.http.Client{ .io = g.init.io, .allocator = allocator };
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

fn getAppPath(g: Global, known_folder: known_folders.KnownFolder) ![]const u8 {
    const parent_path =
        try known_folders.getPath(g.init.io, g.init.gpa, g.init.environ_map, known_folder) orelse return error.NotFound;
    defer g.init.gpa.free(parent_path);
    const sub_path = switch (builtin.os.tag) {
        .macos => "com.faerryn." ++ config.name, // TODO: don't hardcode faerryn.com
        else => config.name,
    };
    const path_parts = &[_][]const u8{ parent_path, sub_path };
    return try std.fs.path.join(g.init.gpa, path_parts);
}
fn openAppDir(g: Global, known_folder: known_folders.KnownFolder, args: std.Io.Dir.OpenOptions) !std.Io.Dir {
    const path = try getAppPath(g, known_folder);
    defer g.init.gpa.free(path);
    std.Io.Dir.cwd().createDirPath(g.init.io, path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    return try std.Io.Dir.cwd().openDir(g.init.io, path, args);
}

// Library of local program installations
pub const Library = struct {
    data_dir: std.Io.Dir,
    cache_dir: std.Io.Dir,

    pub fn init(g: Global) !@This() {
        return .{
            .data_dir = try openAppDir(g, .data, .{ .iterate = true }),
            .cache_dir = try openAppDir(g, .cache, .{ .iterate = true }),
        };
    }

    pub fn deinit(self: *@This(), g: Global) void {
        self.data_dir.close(g.init.io);
        self.cache_dir.close(g.init.io);
    }

    pub const Iterator = struct {
        it: std.Io.Dir.Iterator,
        pub fn next(self: *@This(), g: Global) !?Spec {
            while (try self.it.next(g.init.io)) |entry| {
                if (entry.kind != .directory) continue;
                const spec = Spec.parse(entry.name, .{}, .{}) catch continue;
                return spec;
            }
            return null;
        }
    };

    pub fn iterator(self: @This()) Iterator {
        return .{ .it = self.data_dir.iterate() };
    }

    pub fn openSpecDir(self: @This(), g: Global, spec: Spec, args: std.Io.Dir.OpenOptions) !std.Io.Dir {
        var buffer = std.mem.zeroes([std.fs.max_name_bytes]u8);
        return try self.data_dir.openDir(g.init.io, try spec.buffered(&buffer), args);
    }

    pub fn isInstalled(self: @This(), g: Global, spec: Spec) !bool {
        var buffer = std.mem.zeroes([std.fs.max_name_bytes]u8);
        if (self.data_dir.access(g.init.io, try spec.buffered(&buffer), .{})) {
            return true;
        } else |err| {
            if (err == error.FileNotFound) return false;
            return err;
        }
    }

    // TODO: monster of a function, split it up and give things better names?
    pub fn installRemoteTarball(self: @This(), g: Global, spec: Spec, remote_tarball: RemoteTarball) !void {
        var zig_dir_name_buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
        var zig_dir_name_writer = std.Io.Writer.fixed(&zig_dir_name_buffer);
        try zig_dir_name_writer.print("{f}", .{spec});
        const zig_dir_name = zig_dir_name_writer.buffered();
        // Exit if already installed
        if (self.data_dir.access(g.init.io, zig_dir_name, .{})) {
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
        var file: std.Io.File = self.cache_dir.createFile(g.init.io, filename, .{ .read = true, .exclusive = true }) catch |err| file_block: {
            if (err != error.PathAlreadyExists) return err;
            download = false;
            break :file_block try self.cache_dir.openFile(g.init.io, filename, .{});
        };
        defer file.close(g.init.io);
        var buffer = std.mem.zeroes([4096]u8);
        if (download) {
            errdefer self.cache_dir.deleteFile(g.init.io, filename) catch {};
            var writer = file.writer(g.init.io, &buffer);
            const compressed_bytes = try http_get(g, g.init.gpa, remote_tarball.tarball);
            defer g.init.gpa.free(compressed_bytes);
            try writer.interface.writeAll(compressed_bytes);
            try writer.interface.flush();
        }

        try self.data_dir.createDirPath(g.init.io, zig_dir_name);
        errdefer self.data_dir.deleteTree(g.init.io, zig_dir_name) catch {};

        var zig_dir = try self.data_dir.openDir(g.init.io, zig_dir_name, .{ .iterate = true });
        defer zig_dir.close(g.init.io);
        var file_reader = file.reader(g.init.io, &buffer);
        switch (filetype) {
            .zip => {
                try std.zip.extract(zig_dir, &file_reader, .{});
                if (spec.product == .Zig) {
                    var it = zig_dir.iterate();
                    const mono_entry = try it.next(g.init.io) orelse return error.EmptyZip;
                    defer zig_dir.deleteDir(g.init.io, mono_entry.name) catch g.tio.err.print("error: Failed to delete {s}\n", .{mono_entry.name}) catch {};
                    {
                        var mono_dir = try zig_dir.openDir(g.init.io, mono_entry.name, .{ .iterate = true });
                        defer mono_dir.close(g.init.io);
                        var it2 = mono_dir.iterate();
                        while (try it2.next(g.init.io)) |entry| {
                            try mono_dir.rename(entry.name, zig_dir, entry.name, g.init.io);
                        }
                    }
                }
            },
            .tar_xz => {
                const buffer2 = try g.init.gpa.alloc(u8, 4096);
                var decompress = try std.compress.xz.Decompress.init(&file_reader.interface, g.init.gpa, buffer2);
                defer decompress.deinit();
                try std.tar.pipeToFileSystem(g.init.io, zig_dir, &decompress.reader, .{ .strip_components = switch (spec.product) {
                    .Zig => 1,
                    .Zls => 0,
                } });
            },
        }
    }

    // Matches text against all installed specs to find a match. Returns null for multiple matches.
    pub fn match(self: @This(), g: Global, text: []const u8) !?Spec {
        var candidate: ?Spec = null;
        var it = self.iterator();
        while (try it.next(g)) |spec| {
            if (Spec.parse(text, .{ .infer_target = spec.target, .infer_product = spec.product, .infer_version = spec.version }, .{ .infer_os = spec.target.os, .infer_cpu = spec.target.cpu })) |guess| {
                if (std.meta.eql(spec, guess)) {
                    if (candidate) |_| return null; // too many candidates
                    candidate = guess;
                }
            } else |_| {}
        }
        return candidate;
    }

    // Finds latest runnable spec
    pub fn latest_native(self: @This(), g: Global) !?Spec {
        var candidate: ?Spec = null;
        var it = self.iterator();
        while (try it.next(g)) |spec| {
            if (!spec.target.isNative()) continue;
            if (candidate) |other| {
                if (spec.version.gt(other.version)) {
                    candidate = spec;
                }
            } else {
                candidate = spec;
            }
        }
        return candidate;
    }
};

pub const Global = struct {
    init: std.process.Init,
    tio: TioInterface,
};

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

pub fn findBuildVersion(g: Global, dir: std.Io.Dir) !?Version {
    if (dir.openFile(g.init.io, "build.zig.zon", .{})) |file| {
        defer file.close(g.init.io);
        var buffer = std.mem.zeroes([4096]u8);
        var reader = file.reader(g.init.io, &buffer);
        var writer = std.Io.Writer.Allocating.init(g.init.gpa);
        defer writer.deinit();
        _ = try reader.interface.streamRemaining(&writer.writer);
        const source = try writer.toOwnedSliceSentinel(0);
        defer g.init.gpa.free(source);
        if (std.zon.parse.fromSliceAlloc(struct { minimum_zig_version: []const u8 }, g.init.gpa, source, null, .{ .ignore_unknown_fields = true })) |zon| {
            defer g.init.gpa.free(zon.minimum_zig_version);
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

    var parent = try dir.openDir(g.init.io, "..", .{});
    defer parent.close(g.init.io);
    var dir_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    var parent_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    const dir_len = try dir.realPath(g.init.io, &dir_buf);
    const parent_len = try parent.realPath(g.init.io, &parent_buf);
    if (std.mem.eql(u8, dir_buf[0..dir_len], parent_buf[0..parent_len])) {
        return null;
    }
    return try findBuildVersion(g, parent);
}
