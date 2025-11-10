const std = @import("std");
const builtin = @import("builtin");

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

pub const NATIVE_TARGET: []const u8 = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
pub const VersionSpecs = struct {
    targets: std.StringHashMap(TargetSpecs),
};

pub const TargetSpecs = struct {
    tarball: []const u8,
    shasum: []const u8,
    size: usize,

    pub fn install(self: @This(), allocator: std.mem.Allocator) !void {
        const FileType = enum { zip, tar_xz };
        var filetype: FileType = undefined;
        if (std.ascii.endsWithIgnoreCase(self.tarball, ".zip")) {
            filetype = .zip;
        } else if (std.ascii.endsWithIgnoreCase(self.tarball, ".tar.xz")) {
            filetype = .tar_xz;
        } else {
            return error.UnsupportedFileType;
        }
        var it = std.mem.splitBackwardsScalar(u8, self.tarball, '/');
        const filename = it.next().?;
        var file: std.fs.File = undefined;
        var download = true;

        const dir = std.fs.cwd();

        if (dir.createFile(filename, .{ .read = true, .exclusive = true })) |value| {
            file = value;
        } else |err| {
            if (err != error.PathAlreadyExists) {
                return err;
            }
            file = try dir.openFile(filename, .{});
            download = false;
        }
        defer file.close();
        errdefer file.close();
        var buffer: [1024 * 16]u8 = undefined; // NOTE: std.zip and std.tar break on small buffer sizes for some reason?
        if (download) {
            errdefer dir.deleteFile(filename) catch {};
            var writer = file.writer(&buffer);
            const compressed_bytes = try http_get(allocator, self.tarball);
            try writer.interface.writeAll(compressed_bytes);
            try writer.interface.flush();
        }
        switch (filetype) {
            .zip => {
                var file_reader = file.reader(&buffer);
                try std.zip.extract(dir, &file_reader, .{});
            },
            .tar_xz => {
                const file_reader = file.deprecatedReader();
                var decompress = try std.compress.xz.decompress(allocator, file_reader);
                const decompress_reader = decompress.reader();
                var decompress_adapter = decompress_reader.adaptToNewApi(&buffer);
                try std.tar.pipeToFileSystem(dir, &decompress_adapter.new_interface, .{});
            },
        }
    }
};

fn http_get(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
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
