const std = @import("std");
const CziError = @import("error.zig").CziError;

pub const Dimension = enum(u8) {
    Z = 0,
    C = 1,
    T = 2,
    R = 3,
    S = 4,
    I = 5,
    H = 6,
    V = 7,
    B = 8,
    X = 9,
    Y = 10,
    M = 11,

    pub const count = 12;

    pub const FRAME_ORDER = [9]Dimension{
        .S,
        .T,
        .C,
        .Z,
        .R,
        .I,
        .H,
        .V,
        .B,
    };

    pub fn asStr(self: Dimension) []const u8 {
        return switch (self) {
            .Z => "Z",
            .C => "C",
            .T => "T",
            .R => "R",
            .S => "S",
            .I => "I",
            .H => "H",
            .V => "V",
            .B => "B",
            .X => "X",
            .Y => "Y",
            .M => "M",
        };
    }

    pub fn fromCode(code: []const u8) ?Dimension {
        const trimmed = std.mem.trim(u8, code, " \t\r\n\x00");
        if (trimmed.len != 1) return null;
        return switch (std.ascii.toUpper(trimmed[0])) {
            'Z' => .Z,
            'C' => .C,
            'T' => .T,
            'R' => .R,
            'S' => .S,
            'I' => .I,
            'H' => .H,
            'V' => .V,
            'B' => .B,
            'X' => .X,
            'Y' => .Y,
            'M' => .M,
            else => null,
        };
    }

    pub fn isFrameDimension(self: Dimension) bool {
        return switch (self) {
            .Z, .C, .T, .R, .S, .I, .H, .V, .B => true,
            .X, .Y, .M => false,
        };
    }

    pub fn format(self: Dimension, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.asStr());
    }
};

pub const Interval = struct {
    start: i32,
    size: usize,

    pub fn endExclusive(self: Interval) i32 {
        return self.start + @as(i32, @intCast(self.size));
    }
};

pub const DimBounds = struct {
    intervals: [Dimension.count]?Interval = @splat(null),

    pub fn init() DimBounds {
        return .{};
    }

    pub fn get(self: DimBounds, dimension: Dimension) ?Interval {
        return self.intervals[@intFromEnum(dimension)];
    }

    pub fn set(self: *DimBounds, dimension: Dimension, interval: Interval) void {
        self.intervals[@intFromEnum(dimension)] = interval;
    }

    pub fn updateValue(self: *DimBounds, dimension: Dimension, value: i32) void {
        const idx = @intFromEnum(dimension);
        if (self.intervals[idx]) |*existing| {
            const current_end = existing.endExclusive();
            if (value < existing.start) {
                existing.size = @intCast(current_end - value);
                existing.start = value;
            } else if (value >= current_end) {
                existing.size = @intCast(value - existing.start + 1);
            }
        } else {
            self.intervals[idx] = .{ .start = value, .size = 1 };
        }
    }
};

pub const Coordinate = struct {
    values: [Dimension.count]?i32 = @splat(null),

    pub fn init() Coordinate {
        return .{};
    }

    pub fn with(self: Coordinate, dimension: Dimension, value: i32) Coordinate {
        var copy = self;
        copy.set(dimension, value);
        return copy;
    }

    pub fn set(self: *Coordinate, dimension: Dimension, value: i32) void {
        self.values[@intFromEnum(dimension)] = value;
    }

    pub fn get(self: Coordinate, dimension: Dimension) ?i32 {
        return self.values[@intFromEnum(dimension)];
    }

    pub fn contains(self: Coordinate, dimension: Dimension) bool {
        return self.values[@intFromEnum(dimension)] != null;
    }
};

pub const PlaneIndex = struct {
    values: [Dimension.count]?usize = @splat(null),

    pub fn init() PlaneIndex {
        return .{};
    }

    pub fn with(self: PlaneIndex, dimension: Dimension, value: usize) PlaneIndex {
        var copy = self;
        copy.set(dimension, value);
        return copy;
    }

    pub fn set(self: *PlaneIndex, dimension: Dimension, value: usize) void {
        self.values[@intFromEnum(dimension)] = value;
    }

    pub fn get(self: PlaneIndex, dimension: Dimension) ?usize {
        return self.values[@intFromEnum(dimension)];
    }
};

pub const IntRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn init(x: i32, y: i32, w: i32, h: i32) IntRect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn isValid(self: IntRect) bool {
        return self.w >= 0 and self.h >= 0;
    }

    pub fn isNonEmpty(self: IntRect) bool {
        return self.w > 0 and self.h > 0;
    }

    pub fn right(self: IntRect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: IntRect) i32 {
        return self.y + self.h;
    }

    pub fn intersect(self: IntRect, other: IntRect) ?IntRect {
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.right(), other.right());
        const y2 = @min(self.bottom(), other.bottom());
        if (x2 <= x1 or y2 <= y1) return null;
        return IntRect.init(x1, y1, x2 - x1, y2 - y1);
    }

    pub fn unionWith(self: *IntRect, other: IntRect) void {
        if (!self.isValid()) {
            self.* = other;
            return;
        }
        const x1 = @min(self.x, other.x);
        const y1 = @min(self.y, other.y);
        const x2 = @max(self.right(), other.right());
        const y2 = @max(self.bottom(), other.bottom());
        self.* = IntRect.init(x1, y1, x2 - x1, y2 - y1);
    }
};

pub const IntSize = struct {
    w: u32,
    h: u32,
};

pub const PixelType = enum {
    Gray8,
    Gray16,
    Gray32Float,
    Bgr24,
    Bgr48,
    Bgr96Float,
    Bgra32,
    Gray64ComplexFloat,
    Bgr192ComplexFloat,
    Gray32,
    Gray64Float,

    pub fn fromRaw(value: i32) ?PixelType {
        return switch (value) {
            0 => .Gray8,
            1 => .Gray16,
            2 => .Gray32Float,
            3 => .Bgr24,
            4 => .Bgr48,
            8 => .Bgr96Float,
            9 => .Bgra32,
            10 => .Gray64ComplexFloat,
            11 => .Bgr192ComplexFloat,
            12 => .Gray32,
            13 => .Gray64Float,
            else => null,
        };
    }

    pub fn fromName(name: []const u8) ?PixelType {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "Gray8")) return .Gray8;
        if (std.mem.eql(u8, trimmed, "Gray16")) return .Gray16;
        if (std.mem.eql(u8, trimmed, "Gray32Float")) return .Gray32Float;
        if (std.mem.eql(u8, trimmed, "Bgr24")) return .Bgr24;
        if (std.mem.eql(u8, trimmed, "Bgr48")) return .Bgr48;
        if (std.mem.eql(u8, trimmed, "Bgr96Float")) return .Bgr96Float;
        if (std.mem.eql(u8, trimmed, "Bgra32")) return .Bgra32;
        if (std.mem.eql(u8, trimmed, "Gray64ComplexFloat")) return .Gray64ComplexFloat;
        if (std.mem.eql(u8, trimmed, "Bgr192ComplexFloat")) return .Bgr192ComplexFloat;
        if (std.mem.eql(u8, trimmed, "Gray32")) return .Gray32;
        if (std.mem.eql(u8, trimmed, "Gray64Float")) return .Gray64Float;
        return null;
    }

    pub fn asStr(self: PixelType) []const u8 {
        return switch (self) {
            .Gray8 => "Gray8",
            .Gray16 => "Gray16",
            .Gray32Float => "Gray32Float",
            .Bgr24 => "Bgr24",
            .Bgr48 => "Bgr48",
            .Bgr96Float => "Bgr96Float",
            .Bgra32 => "Bgra32",
            .Gray64ComplexFloat => "Gray64ComplexFloat",
            .Bgr192ComplexFloat => "Bgr192ComplexFloat",
            .Gray32 => "Gray32",
            .Gray64Float => "Gray64Float",
        };
    }

    pub fn bytesPerPixel(self: PixelType) usize {
        return switch (self) {
            .Gray8 => 1,
            .Gray16 => 2,
            .Gray32Float => 4,
            .Bgr24 => 3,
            .Bgr48 => 6,
            .Bgr96Float => 12,
            .Bgra32 => 4,
            .Gray64ComplexFloat => 16,
            .Bgr192ComplexFloat => 24,
            .Gray32 => 4,
            .Gray64Float => 8,
        };
    }

    pub fn format(self: PixelType, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.asStr());
    }
};

pub const CompressionMode = enum {
    UnCompressed,
    Jpg,
    JpgXr,
    Zstd0,
    Zstd1,

    pub fn fromRaw(value: i32) ?CompressionMode {
        return switch (value) {
            0 => .UnCompressed,
            1 => .Jpg,
            4 => .JpgXr,
            5 => .Zstd0,
            6 => .Zstd1,
            else => null,
        };
    }

    pub fn asStr(self: CompressionMode) []const u8 {
        return switch (self) {
            .UnCompressed => "UnCompressed",
            .Jpg => "Jpg",
            .JpgXr => "JpgXr",
            .Zstd0 => "Zstd0",
            .Zstd1 => "Zstd1",
        };
    }

    pub fn format(self: CompressionMode, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.asStr());
    }
};

pub const SubBlockPyramidType = enum {
    None,
    SingleSubBlock,
    MultiSubBlock,

    pub fn fromRaw(value: u8) ?SubBlockPyramidType {
        return switch (value) {
            0 => .None,
            1 => .SingleSubBlock,
            2 => .MultiSubBlock,
            else => null,
        };
    }
};

pub const FileHeaderInfo = struct {
    major: i32,
    minor: i32,
    primary_file_guid: [36]u8,
    file_guid: [36]u8,
    file_part: i32,
    subblock_directory_position: u64,
    metadata_position: u64,
    update_pending: bool,
    attachment_directory_position: u64,
};

pub const DirectorySubBlockInfo = struct {
    index: usize,
    file_position: u64,
    file_part: i32,
    pixel_type: PixelType,
    compression: CompressionMode,
    coordinate: Coordinate,
    rect: IntRect,
    stored_size: IntSize,
    m_index: ?i32,
    pyramid_type: ?SubBlockPyramidType,

    pub fn isDownsampled(self: DirectorySubBlockInfo) bool {
        return self.rect.w > 0 and self.rect.h > 0 and
            (@as(u32, @intCast(self.rect.w)) != self.stored_size.w or
                @as(u32, @intCast(self.rect.h)) != self.stored_size.h);
    }

    pub fn isLayer0(self: DirectorySubBlockInfo) bool {
        return !self.isDownsampled() and
            (self.pyramid_type == null or self.pyramid_type == .None);
    }
};

pub const AttachmentInfo = struct {
    index: usize,
    file_position: u64,
    file_part: i32,
    content_guid: [36]u8,
    content_file_type: []u8,
    name: []u8,
    data_size: u64,

    pub fn deinit(self: *AttachmentInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.content_file_type);
        allocator.free(self.name);
    }
};

pub const AttachmentBlob = struct {
    info: AttachmentInfo,
    data: []u8,

    pub fn deinit(self: *AttachmentBlob, allocator: std.mem.Allocator) void {
        self.info.deinit(allocator);
        allocator.free(self.data);
    }
};

pub const RawSubBlock = struct {
    info: DirectorySubBlockInfo,
    metadata: []u8,
    data: []u8,
    attachment: []u8,

    pub fn deinit(self: *RawSubBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.metadata);
        allocator.free(self.data);
        allocator.free(self.attachment);
    }
};

pub const BoundingBoxes = struct {
    all: IntRect,
    layer0: IntRect,
};

pub const SubBlockStatistics = struct {
    subblock_count: usize = 0,
    dim_bounds: DimBounds = .{},
    bounding_box: ?IntRect = null,
    bounding_box_layer0: ?IntRect = null,
    scene_bounding_boxes: std.AutoHashMapUnmanaged(i32, BoundingBoxes) = .empty,
    min_m_index: ?i32 = null,
    max_m_index: ?i32 = null,

    pub fn deinit(self: *SubBlockStatistics, allocator: std.mem.Allocator) void {
        self.scene_bounding_boxes.deinit(allocator);
    }
};

pub const ScalingInfo = struct {
    x: ?f64 = null,
    y: ?f64 = null,
    z: ?f64 = null,
    unit: ?[]u8 = null,

    pub fn deinit(self: *ScalingInfo, allocator: std.mem.Allocator) void {
        if (self.unit) |u| allocator.free(u);
    }
};

pub const ChannelInfo = struct {
    index: usize,
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    pixel_type: ?PixelType = null,
    color: ?[]u8 = null,

    pub fn deinit(self: *ChannelInfo, allocator: std.mem.Allocator) void {
        if (self.id) |v| allocator.free(v);
        if (self.name) |v| allocator.free(v);
        if (self.color) |v| allocator.free(v);
    }
};

pub const DocumentInfo = struct {
    name: ?[]u8 = null,
    title: ?[]u8 = null,
    comment: ?[]u8 = null,
    author: ?[]u8 = null,
    user_name: ?[]u8 = null,
    creation_date: ?[]u8 = null,
    description: ?[]u8 = null,
    application_name: ?[]u8 = null,
    application_version: ?[]u8 = null,

    pub fn deinit(self: *DocumentInfo, allocator: std.mem.Allocator) void {
        if (self.name) |v| allocator.free(v);
        if (self.title) |v| allocator.free(v);
        if (self.comment) |v| allocator.free(v);
        if (self.author) |v| allocator.free(v);
        if (self.user_name) |v| allocator.free(v);
        if (self.creation_date) |v| allocator.free(v);
        if (self.description) |v| allocator.free(v);
        if (self.application_name) |v| allocator.free(v);
        if (self.application_version) |v| allocator.free(v);
    }
};

pub const ImageInfo = struct {
    pixel_type: ?PixelType = null,
    sizes: [Dimension.count]?usize = @splat(null),
};

pub const MetadataSummary = struct {
    document: DocumentInfo = .{},
    image: ImageInfo = .{},
    scaling: ScalingInfo = .{},
    channels: []ChannelInfo = &.{},

    pub fn deinit(self: *MetadataSummary, allocator: std.mem.Allocator) void {
        self.document.deinit(allocator);
        self.scaling.deinit(allocator);
        for (self.channels) |*ch| ch.deinit(allocator);
        if (self.channels.len > 0) allocator.free(self.channels);
    }
};

pub const SummaryChannel = struct {
    index: usize,
    name: ?[]u8 = null,
    color: ?[]u8 = null,
    pixel_type: ?[]u8 = null,

    pub fn deinit(self: *SummaryChannel, allocator: std.mem.Allocator) void {
        if (self.name) |v| allocator.free(v);
        if (self.color) |v| allocator.free(v);
        if (self.pixel_type) |v| allocator.free(v);
    }
};

pub const SummaryScaling = struct {
    x: ?f64 = null,
    y: ?f64 = null,
    z: ?f64 = null,
    unit: ?[]u8 = null,

    pub fn deinit(self: *SummaryScaling, allocator: std.mem.Allocator) void {
        if (self.unit) |v| allocator.free(v);
    }
};

pub const DimensionSizes = struct {
    entries: [Dimension.count]usize = @splat(0),
    present: [Dimension.count]bool = @splat(false),

    pub fn set(self: *DimensionSizes, dim: Dimension, size: usize) void {
        const idx = @intFromEnum(dim);
        self.entries[idx] = size;
        self.present[idx] = true;
    }

    pub fn get(self: DimensionSizes, code: []const u8) ?usize {
        const dim = Dimension.fromCode(code) orelse return null;
        return self.getDim(dim);
    }

    pub fn getDim(self: DimensionSizes, dim: Dimension) ?usize {
        const idx = @intFromEnum(dim);
        if (!self.present[idx]) return null;
        return self.entries[idx];
    }
};

pub const DatasetSummary = struct {
    version_major: u32,
    version_minor: u32,
    sizes: DimensionSizes,
    logical_frame_count: usize,
    channels: []SummaryChannel,
    pixel_type: ?[]u8,
    scaling: ?SummaryScaling,

    pub fn deinit(self: *DatasetSummary, allocator: std.mem.Allocator) void {
        for (self.channels) |*ch| ch.deinit(allocator);
        allocator.free(self.channels);
        if (self.pixel_type) |pt| allocator.free(pt);
        if (self.scaling) |*sc| sc.deinit(allocator);
    }
};

pub const Bitmap = struct {
    pixel_type: PixelType,
    width: u32,
    height: u32,
    stride: usize,
    data: []u8,

    pub fn init(pixel_type: PixelType, width: u32, height: u32, data: []u8) CziError!Bitmap {
        const stride = std.math.mul(usize, @as(usize, width), pixel_type.bytesPerPixel()) catch return error.Overflow;
        const expected = std.math.mul(usize, stride, @as(usize, height)) catch return error.Overflow;
        if (data.len != expected) return error.InvalidFormat;
        return .{
            .pixel_type = pixel_type,
            .width = width,
            .height = height,
            .stride = stride,
            .data = data,
        };
    }

    pub fn zeros(allocator: std.mem.Allocator, pixel_type: PixelType, width: u32, height: u32) CziError!Bitmap {
        const stride = std.math.mul(usize, @as(usize, width), pixel_type.bytesPerPixel()) catch return error.Overflow;
        const len = std.math.mul(usize, stride, @as(usize, height)) catch return error.Overflow;
        const data = allocator.alloc(u8, len) catch return error.OutOfMemory;
        @memset(data, 0);
        return .{
            .pixel_type = pixel_type,
            .width = width,
            .height = height,
            .stride = stride,
            .data = data,
        };
    }

    pub fn deinit(self: *Bitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn bytesPerPixel(self: Bitmap) usize {
        return self.pixel_type.bytesPerPixel();
    }

    pub fn asBytes(self: Bitmap) []const u8 {
        return self.data;
    }

    pub fn toU16Slice(self: Bitmap, allocator: std.mem.Allocator) CziError![]u16 {
        if (self.bytesPerPixel() % 2 != 0) return error.UnsupportedPixelType;
        const count = self.data.len / 2;
        const values = allocator.alloc(u16, count) catch return error.OutOfMemory;
        for (0..count) |i| {
            values[i] = std.mem.readInt(u16, self.data[i * 2 ..][0..2], .little);
        }
        return values;
    }

    pub fn toGrayU16(self: Bitmap, allocator: std.mem.Allocator) CziError![]u16 {
        const expected_len = @as(usize, self.width) * @as(usize, self.height);
        switch (self.pixel_type) {
            .Gray8 => {
                const out = allocator.alloc(u16, expected_len) catch return error.OutOfMemory;
                for (self.data, 0..) |b, i| {
                    out[i] = @as(u16, b);
                }
                return out;
            },
            .Bgr24, .Bgra32 => {
                const channels = self.pixel_type.bytesPerPixel();
                const out = allocator.alloc(u16, expected_len) catch return error.OutOfMemory;
                for (0..expected_len) |i| {
                    const chunk = self.data[i * channels .. (i + 1) * channels];
                    var sum: u32 = 0;
                    for (chunk) |b| sum += @as(u32, b);
                    out[i] = @intCast(sum / @as(u32, @intCast(channels)));
                }
                return out;
            },
            .Gray16 => return self.toU16Slice(allocator),
            .Bgr48 => {
                const values = try self.toU16Slice(allocator);
                defer allocator.free(values);
                const channels: usize = 3;
                const out = allocator.alloc(u16, expected_len) catch return error.OutOfMemory;
                for (0..expected_len) |i| {
                    const chunk = values[i * channels .. (i + 1) * channels];
                    var sum: u32 = 0;
                    for (chunk) |v| sum += @as(u32, v);
                    out[i] = @intCast(sum / 3);
                }
                return out;
            },
            else => return error.UnsupportedPixelType,
        }
    }

    pub fn toF32Slice(self: Bitmap, allocator: std.mem.Allocator) CziError![]f32 {
        if (self.bytesPerPixel() % 4 != 0) return error.UnsupportedPixelType;
        const count = self.data.len / 4;
        const values = allocator.alloc(f32, count) catch return error.OutOfMemory;
        for (0..count) |i| {
            const bits = std.mem.readInt(u32, self.data[i * 4 ..][0..4], .little);
            values[i] = @bitCast(bits);
        }
        return values;
    }
};
