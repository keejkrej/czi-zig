const std = @import("std");
const CziError = @import("error.zig").CziError;

pub const Source = union(enum) {
    file: struct {
        file: std.Io.File,
        io: std.Io,
        owned: bool,
    },
    memory: []const u8,

    pub fn close(self: *Source) void {
        switch (self.*) {
            .file => |*f| {
                if (f.owned) {
                    f.file.close(f.io);
                    f.owned = false;
                }
            },
            .memory => {},
        }
    }

    pub fn readExactAt(self: Source, allocator: std.mem.Allocator, offset: u64, len: usize) CziError![]u8 {
        const buf = allocator.alloc(u8, len) catch return error.OutOfMemory;
        errdefer allocator.free(buf);
        try self.readExactAtInto(offset, buf);
        return buf;
    }

    pub fn readExactAtInto(self: Source, offset: u64, dest: []u8) CziError!void {
        if (dest.len == 0) return;
        switch (self) {
            .file => |f| {
                const n = f.file.readPositionalAll(f.io, dest, offset) catch return error.IoError;
                if (n != dest.len) return error.IoError;
            },
            .memory => |bytes| {
                const start = std.math.cast(usize, offset) orelse return error.IoError;
                const end = std.math.add(usize, start, dest.len) catch return error.IoError;
                if (end > bytes.len) return error.IoError;
                @memcpy(dest, bytes[start..end]);
            },
        }
    }
};
