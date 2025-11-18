const std = @import("std");
const builtin = @import("builtin");
const kf = @import("known_folders");
const config = @import("config");

pub const ParseError = error{Malformed};

pub const SpecParseOptions = struct {
    allow_no_prefix: bool = false, // without the `zig-` prefix
    allow_from_version: bool = false, // parse as version and infer target

    guess: bool = false, // if true, then all other fields are treated as true
};

// zig-target-version
pub const Spec = struct {
    target: Target,
    version: Version,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("zig-{f}-{f}", .{ self.target, self.version });
    }

    pub fn parse(text: []const u8, options: SpecParseOptions) ParseError!@This() {
        if (Spec.parse_impl(text, options.guess or options.allow_no_prefix)) |spec| {
            return spec;
        } else |err| {
            if (err != ParseError.Malformed) return err;
        }
        if (options.guess or options.allow_from_version) {
            if (Version.parse(text)) |version| {
                return .{ .target = .NATIVE, .version = version };
            } else |err| {
                if (err != ParseError.Malformed) return err;
            }
        }
        // TODO: parse target by matching to a *default version*
        // if (Target.parse(text)) |target| { }
        return ParseError.Malformed;
    }

    fn parse_impl(text: []const u8, allow_no_prefix: bool) !@This() {
        var it = std.mem.splitScalar(u8, text, '-');
        var pieces = std.mem.zeroes([4][]const u8);
        var len: usize = 0;
        while (it.next()) |piece| {
            if (len == 4) return ParseError.Malformed;
            if (piece.len == 0) return ParseError.Malformed;
            pieces[len] = piece;
            len += 1;
        }
        if (len < 3) return ParseError.Malformed;
        const has_prefix = std.mem.eql(u8, "zig", pieces[0]);
        if (!allow_no_prefix and !has_prefix) return ParseError.Malformed;
        const start: usize = @intFromBool(has_prefix);
        if (start + 3 != len) return ParseError.Malformed;
        return .{
            .target = .{
                .cpu = pieces[start],
                .os = pieces[start + 1],
            },
            .version = try Version.parse(pieces[start + 2]),
        };
    }
};

pub const SpecContext = struct {
    pub fn hash(_: @This(), spec: Spec) u32 {
        var h = std.hash.Wyhash.init(0);
        h.update(&spec.version.parts);
        h.update(spec.target.cpu);
        h.update(spec.target.os);
        return @truncate(h.final());
    }

    pub fn eql(_: @This(), lhs: Spec, rhs: Spec, _: usize) bool {
        return std.mem.eql(u8, &lhs.version.parts, &rhs.version.parts) and std.mem.eql(u8, lhs.target.cpu, rhs.target.cpu) and std.mem.eql(u8, lhs.target.os, rhs.target.os);
    }
};

// cpu-os
pub const Target = struct {
    cpu: []const u8,
    os: []const u8,

    pub const NATIVE: @This() = .{
        .cpu = @tagName(builtin.cpu.arch),
        .os = @tagName(builtin.os.tag),
    };

    pub fn is_executable(self: @This()) bool {
        return eql(self, NATIVE);
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("{s}-{s}", .{ self.cpu, self.os });
    }

    pub fn parse(text: []const u8) ParseError!@This() {
        var it = std.mem.splitScalar(u8, text, '-');
        var pieces = std.mem.zeroes([2][]const u8);
        var len: usize = 0;
        while (it.next()) |piece| {
            if (len == 2) return ParseError.Malformed;
            if (piece.len == 0) return ParseError.Malformed;
            pieces[len] = piece;
            len += 1;
        }
        if (len != 2) return ParseError.Malformed;
        return .{
            .cpu = pieces[0],
            .os = pieces[1],
        };
    }

    pub fn eql(lhs: @This(), rhs: @This()) bool {
        return std.mem.eql(u8, lhs.cpu, rhs.cpu) and
            std.mem.eql(u8, lhs.os, rhs.os);
    }
};

// major.minor.patch
pub const Version = struct {
    parts: [3]u8,

    pub fn gt(self: @This(), other: @This()) bool {
        return std.mem.readInt(u24, &self.parts, .big) >
            std.mem.readInt(u24, &other.parts, .big);
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
            parts[len] = try parse_decimal(piece);
            len += 1;
        }
        if (len != 3) return ParseError.Malformed;
        return .{ .parts = parts };
    }
};

fn parse_decimal(text: []const u8) !u8 {
    if (text.len == 0) return ParseError.Malformed;
    var acc: u8 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return ParseError.Malformed;
        acc *= 10;
        acc += c - '0';
    }
    return acc;
}

pub const RemoteTarball = struct {
    url: []u8,
    checksum: []u8,
};

pub const RemoteIndexContent = std.ArrayHashMap(Spec, RemoteTarball, SpecContext, true);

pub const RemoteIndex = struct {
    arena: std.heap.ArenaAllocator,
    content: RemoteIndexContent,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }
};

pub fn fetch_remote_index(backing_allocator: std.mem.Allocator) !RemoteIndex {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
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
            const target = Target.parse(kv.key_ptr.*) catch |err| {
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

pub fn http_get(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    var writer = std.io.Writer.Allocating.init(allocator);
    const result = try client.fetch(.{
        .response_writer = &writer.writer,
        .location = .{ .url = url },
        .method = .GET,
    });
    if (result.status.class() != .success) {
        return error.GetFailed;
    }
    return try writer.toOwnedSlice();
}

pub const AppDir = enum { tarball, install };
pub fn openAppDir(comptime app_dir: AppDir, args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path_parts = switch (app_dir) {
        .tarball => &[_][]const u8{
            try kf.getPath(std.Io{}, allocator, kf.KnownFolder.cache) orelse return error.NotFound,
            config.name,
        },
        .install => &[_][]const u8{
            try kf.getPath(std.Io{}, allocator, kf.KnownFolder.data) orelse return error.NotFound,
            config.name,
        },
    };
    const path = try std.fs.path.join(allocator, path_parts);
    std.fs.cwd().makePath(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    return try std.fs.cwd().openDir(path, args);
}

pub fn install_remote_tarball(spec: Spec, remote_tarball: RemoteTarball) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var zig_dir_name: std.ArrayList(u8) = .empty;
    try zig_dir_name.print(allocator, "{f}", .{spec});

    const FileType = enum { zip, tar_xz };
    const filetype: FileType =
        if (std.ascii.endsWithIgnoreCase(remote_tarball.url, ".zip"))
            .zip
        else if (std.ascii.endsWithIgnoreCase(remote_tarball.url, ".tar.xz"))
            .tar_xz
        else
            return error.UnsupportedFileType;
    var filename = try zig_dir_name.clone(allocator);
    switch (filetype) {
        .zip => try filename.print(allocator, ".zip", .{}),
        .tar_xz => try filename.print(allocator, ".tar.xz", .{}),
    }
    var tarball_dir = try openAppDir(.tarball, .{});
    defer tarball_dir.close();
    var download = true;
    var file: std.fs.File = tarball_dir.createFile(filename.items, .{ .read = true, .exclusive = true }) catch |err| file_block: {
        if (err != error.PathAlreadyExists) return err;
        download = false;
        break :file_block try tarball_dir.openFile(filename.items, .{});
    };
    defer file.close();
    var buffer = std.mem.zeroes([1024]u8);
    if (download) {
        errdefer tarball_dir.deleteFile(filename.items) catch {};
        var writer = file.writer(&buffer);
        const compressed_bytes = try http_get(allocator, remote_tarball.url);
        try writer.interface.writeAll(compressed_bytes);
        try writer.interface.flush();
    }
    var install_dir = try openAppDir(.install, .{});
    defer install_dir.close();
    try install_dir.makePath(zig_dir_name.items);
    errdefer install_dir.deleteTree(zig_dir_name.items) catch {};
    var zig_dir = try install_dir.openDir(zig_dir_name.items, .{ .iterate = true });
    defer zig_dir.close();
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
        var single_dir = try zig_dir.openDir(entries.items[0].name, .{ .iterate = true });
        defer single_dir.close();
        dir_it = single_dir.iterate();
        const zig_path = try zig_dir.realpathAlloc(allocator, ".");
        var old_path_buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
        while (try dir_it.next()) |entry| {
            const old = try single_dir.realpath(entry.name, &old_path_buffer);
            const new = try std.fs.path.join(allocator, &[_][]const u8{ zig_path, entry.name });
            try std.fs.renameAbsolute(old, new);
        }
    }
}

pub fn list_installed_specs(allocator: std.mem.Allocator) !std.ArrayList(Spec) {
    var specs: std.ArrayList(Spec) = .empty;
    var install_dir = try openAppDir(.install, .{ .iterate = true });
    defer install_dir.close();
    var dir_it = install_dir.iterate();
    while (try dir_it.next()) |entry| {
        if (entry.kind != .directory) {
            continue;
        }
        const spec = Spec.parse(entry.name, .{}) catch continue;
        try specs.append(allocator, spec);
    }
    return specs;
}
