const std = @import("std");
const builtin = @import("builtin");

// zig-target-version
pub const Spec = struct {
    target: Target,
    version: Version,

    pub fn serialize(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("zig-", .{});
        try self.target.serialize(writer);
        try writer.print("-", .{});
        try self.version.serialize(writer);
    }

    pub fn parse(text: []const u8) !@This() {
        var it = std.mem.splitScalar(u8, text, '-');
        var pieces = std.mem.zeroes([4][]const u8);
        var len: usize = 0;
        while (it.next()) |piece| {
            if (len == 4) return error.ParseError;
            if (piece.len == 0) return error.ParseError;
            pieces[len] = piece;
            len += 1;
        }
        if (len != 4) return error.ParseError;
        if (!std.mem.eql(u8, "zig", pieces[0])) return error.ParseError;
        return .{
            .target = .{
                .cpu = pieces[1],
                .os = pieces[2],
            },
            .version = try Version.parse(pieces[3]),
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

    pub fn serialize(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("{s}-{s}", .{ self.cpu, self.os });
    }

    pub fn parse(text: []const u8) !@This() {
        var it = std.mem.splitScalar(u8, text, '-');
        var pieces = std.mem.zeroes([2][]const u8);
        var len: usize = 0;
        while (it.next()) |piece| {
            if (len == 2) return error.ParseError;
            if (piece.len == 0) return error.ParseError;
            pieces[len] = piece;
            len += 1;
        }
        if (len != 2) return error.ParseError;
        return .{
            .cpu = pieces[0],
            .os = pieces[1],
        };
    }
};

pub const NATIVE_TARGET = Target.NATIVE.cpu ++ "-" ++ Target.NATIVE.os;

// major.minor.patch
pub const Version = struct {
    parts: [3]u8,

    pub fn serialize(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("{d}.{d}.{d}", .{ self.parts[0], self.parts[1], self.parts[2] });
    }

    pub fn parse(text: []const u8) !@This() {
        var it = std.mem.splitScalar(u8, text, '.');
        var parts = std.mem.zeroes([3]u8);
        var len: usize = 0;
        while (it.next()) |piece| {
            if (len == 3) return error.ParseError;
            parts[len] = try parse_decimal(piece);
            len += 1;
        }
        if (len != 3) return error.ParseError;
        return .{ .parts = parts };
    }
};

fn parse_decimal(text: []const u8) !u8 {
    if (text.len == 0) return error.ParseError;
    var acc: u8 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return error.ParseError;
        acc *= 10;
        acc += c - '0';
    }
    return acc;
}

pub const RemoteTarball = struct {
    tarball_url: []u8,
    tarball_checksum: []u8,
};

pub const RemoteIndexContent = std.ArrayHashMap(Spec, RemoteTarball, SpecContext, true);

pub const RemoteIndex = struct {
    arena: std.heap.ArenaAllocator,
    content: RemoteIndexContent,

    pub fn deinit(self: *@This()) void {
        self.content.deinit();
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
        else => return error.ParseError,
    };
    while (index_it.next()) |index_kv| {
        if (std.mem.eql(u8, "master", index_kv.key_ptr.*)) continue; // TODO: handle master
        const version = try Version.parse(index_kv.key_ptr.*);
        var version_it = index_kv.value_ptr.object.iterator();
        while (version_it.next()) |kv| {
            const target = Target.parse(kv.key_ptr.*) catch |err| {
                if (err == error.ParseError) continue else return err;
            };
            const target_specs = std.json.parseFromValueLeaky(TargetSpecs, allocator, kv.value_ptr.*, .{}) catch |err|
                {
                    if (err == error.DuplicateField or err == error.UnknownField or
                        err == error.MissingField or err == error.LengthMismatch or
                        err == error.UnexpectedToken)
                        continue
                    else
                        return err;
                };
            try content.put(.{ .version = version, .target = target }, .{ .tarball_url = target_specs.tarball, .tarball_checksum = target_specs.shasum });
        }
    }

    return .{ .content = content, .arena = arena };
}

pub const Index = struct {
    versions: std.StringArrayHashMap(VersionSpecs),

    pub fn singleton() !@This() {
        if (index_singleton) |value| {
            return value;
        } else {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            const allocator = arena.allocator();
            index_singleton = try fetch_index(allocator);
            return index_singleton.?;
        }
    }

    fn get(self: @This(), spec: Spec) !?TargetSpecs {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var version_builder = std.Io.Writer.Allocating.init(allocator);
        try spec.version.serialize(&version_builder.writer);
        const version = try version_builder.toOwnedSlice();

        const version_spec = self.versions.get(version) orelse return null;
        var target_builder = std.Io.Writer.Allocating.init(allocator);
        try spec.target.serialize(&target_builder.writer);
        const target = try target_builder.toOwnedSlice();
        return version_spec.targets.get(target);
    }
};

var index_singleton: ?Index = null;
fn fetch_index(allocator: std.mem.Allocator) !Index {
    var versions = std.StringArrayHashMap(VersionSpecs).init(allocator);
    const s = try http_get(allocator, "https://ziglang.org/download/index.json");
    const index_value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, s, .{});
    var index_it = index_value.object.iterator();
    while (index_it.next()) |index_kv| {
        const version = index_kv.key_ptr.*;
        const version_value = index_kv.value_ptr;
        var targets = std.StringHashMap(TargetSpecs).init(allocator);
        var version_it = version_value.object.iterator();
        while (version_it.next()) |kv| {
            const k = kv.key_ptr.*;
            const v = kv.value_ptr.*;
            if (std.json.parseFromValueLeaky(TargetSpecs, allocator, v, .{})) |spec| {
                try targets.put(k, spec);
            } else |err| {
                if (!(err == error.DuplicateField or err == error.UnknownField or
                    err == error.MissingField or err == error.LengthMismatch or
                    err == error.UnexpectedToken))
                {
                    return err;
                }
            }
        }
        try versions.put(version, .{ .targets = targets });
    }
    return .{ .versions = versions };
}

pub const VersionSpecs = struct {
    targets: std.StringHashMap(TargetSpecs),
};

pub const TargetSpecs = struct {
    tarball: []u8,
    shasum: []u8,
    size: usize,
};

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

pub fn install_spec(spec: Spec, data_dir: std.fs.Dir, cache_dir: std.fs.Dir) !void {
    const index = try Index.singleton();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var zig_dir_name_builder = std.Io.Writer.Allocating.init(allocator);
    try spec.serialize(&zig_dir_name_builder.writer);
    const zig_dir_name = zig_dir_name_builder.toArrayList();
    data_dir.access(zig_dir_name.items, .{}) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    const target_spec = try index.get(spec) orelse return error.NotFound;

    const FileType = enum { zip, tar_xz };
    const filetype: FileType =
        if (std.ascii.endsWithIgnoreCase(target_spec.tarball, ".zip"))
            .zip
        else if (std.ascii.endsWithIgnoreCase(target_spec.tarball, ".tar.xz"))
            .tar_xz
        else
            return error.UnsupportedFileType;
    var filename = try zig_dir_name.clone(allocator);
    switch (filetype) {
        .zip => try filename.print(allocator, ".zip", .{}),
        .tar_xz => try filename.print(allocator, ".tar.xz", .{}),
    }
    var download = true;
    var file: std.fs.File = cache_dir.createFile(filename.items, .{ .read = true, .exclusive = true }) catch |err| file_block: {
        if (err != error.PathAlreadyExists) return err;
        download = false;
        break :file_block try cache_dir.openFile(filename.items, .{});
    };
    defer file.close();
    errdefer file.close();
    var buffer = std.mem.zeroes([1024]u8);
    if (download) {
        errdefer cache_dir.deleteFile(filename.items) catch {};
        var writer = file.writer(&buffer);
        const compressed_bytes = try http_get(allocator, target_spec.tarball);
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
        var old_path_buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
        while (try dir_it.next()) |entry| {
            const old = try single_dir.realpath(entry.name, &old_path_buffer);
            const new = try std.fs.path.join(allocator, &[_][]const u8{ zig_path, entry.name });
            try std.fs.renameAbsolute(old, new);
        }
    }
}
