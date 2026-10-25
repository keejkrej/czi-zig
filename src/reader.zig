const std = @import("std");
const CziError = @import("error.zig").CziError;
const Source = @import("io.zig").Source;
const metadata_mod = @import("metadata.zig");
const parse_mod = @import("parse.zig");
const types = @import("types.zig");

const AttachmentInfo = types.AttachmentInfo;
const Bitmap = types.Bitmap;
const Coordinate = types.Coordinate;
const DatasetSummary = types.DatasetSummary;
const Dimension = types.Dimension;
const DimensionSizes = types.DimensionSizes;
const DirectorySubBlockInfo = types.DirectorySubBlockInfo;
const FileHeaderInfo = types.FileHeaderInfo;
const IntRect = types.IntRect;
const MetadataSummary = types.MetadataSummary;
const PixelType = types.PixelType;
const PlaneIndex = types.PlaneIndex;
const SubBlockStatistics = types.SubBlockStatistics;
const SummaryChannel = types.SummaryChannel;
const SummaryScaling = types.SummaryScaling;

/// Main reader for Zeiss CZI microscopy files.
pub const CziFile = struct {
    allocator: std.mem.Allocator,
    path_owned: ?[]u8,
    source: Source,
    header: FileHeaderInfo,
    subblocks: []DirectorySubBlockInfo,
    attachments: []AttachmentInfo,
    statistics: SubBlockStatistics,
    metadata_xml: ?[]u8,
    metadata_summary: ?MetadataSummary,

    /// Open a CZI file from an in-memory byte slice.
    pub fn openMemory(allocator: std.mem.Allocator, data: []const u8) CziError!CziFile {
        return openInternal(allocator, null, .{ .memory = data });
    }

    /// Open a CZI file from an existing `Source`.
    pub fn openSource(allocator: std.mem.Allocator, source: Source) CziError!CziFile {
        return openInternal(allocator, null, source);
    }

    /// Open a CZI file for reading from a local filesystem path.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) CziError!CziFile {
        const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch return error.IoError;
        var src: Source = .{ .file = .{ .file = file, .io = io, .owned = true } };
        errdefer src.close();

        const duped_path = allocator.dupe(u8, file_path) catch return error.OutOfMemory;
        errdefer allocator.free(duped_path);

        return openInternal(allocator, duped_path, src);
    }

    fn openInternal(allocator: std.mem.Allocator, path_owned: ?[]u8, source: Source) CziError!CziFile {
        const parsed = try parse_mod.parseFile(allocator, source);
        return .{
            .allocator = allocator,
            .path_owned = path_owned,
            .source = source,
            .header = parsed.header,
            .subblocks = parsed.subblocks,
            .attachments = parsed.attachments,
            .statistics = parsed.statistics,
            .metadata_xml = null,
            .metadata_summary = null,
        };
    }

    pub fn deinit(self: *CziFile) void {
        if (self.path_owned) |p| self.allocator.free(p);
        self.source.close();
        self.allocator.free(self.subblocks);
        for (self.attachments) |*att| att.deinit(self.allocator);
        self.allocator.free(self.attachments);
        self.statistics.deinit(self.allocator);
        if (self.metadata_xml) |xml| self.allocator.free(xml);
        if (self.metadata_summary) |*meta| meta.deinit(self.allocator);
    }

    /// Returns the filesystem path to this file, if opened from a path.
    pub fn path(self: *const CziFile) ?[]const u8 {
        return self.path_owned;
    }

    /// Get the format version (major, minor).
    pub fn version(self: *const CziFile) struct { major: u32, minor: u32 } {
        return .{
            .major = @intCast(@max(self.header.major, 0)),
            .minor = @intCast(@max(self.header.minor, 0)),
        };
    }

    fn ensureMetadata(self: *CziFile) CziError!*const MetadataSummary {
        if (self.metadata_summary == null) {
            if (self.metadata_xml == null) {
                self.metadata_xml = try parse_mod.readMetadataXml(self.allocator, self.source, self.header.metadata_position);
            }
            const xml = self.metadata_xml orelse "";
            self.metadata_summary = try metadata_mod.parseMetadataXml(self.allocator, xml);
        }
        return &self.metadata_summary.?;
    }

    /// Returns the dataset dimension sizes (e.g. "X", "Y", "C", "Z", "T", "S").
    pub fn sizes(self: *const CziFile) DimensionSizes {
        var result: DimensionSizes = .{};
        for (Dimension.FRAME_ORDER) |dim| {
            const sz = if (self.statistics.dim_bounds.get(dim)) |interval| interval.size else 1;
            result.set(dim, sz);
        }

        const rect = self.statistics.bounding_box_layer0 orelse self.statistics.bounding_box;
        const w: usize = if (rect) |r| @intCast(@max(r.w, 0)) else 0;
        const h: usize = if (rect) |r| @intCast(@max(r.h, 0)) else 0;
        result.set(.X, w);
        result.set(.Y, h);
        return result;
    }

    /// Return a lightweight dataset overview containing dimensions, channels, and scaling.
    /// Caller owns the returned DatasetSummary and must call `summary.deinit(allocator)`.
    pub fn summary(self: *CziFile) CziError!DatasetSummary {
        const dim_sizes = self.sizes();
        const meta = try self.ensureMetadata();
        const logical_frame_count = try self.logicalFrameCount();

        var ch_pixel_types = try self.channelPixelTypes();
        defer ch_pixel_types.deinit(self.allocator);

        var max_ch_from_blocks: usize = 0;
        var it = ch_pixel_types.keyIterator();
        while (it.next()) |k| {
            if (k.* + 1 > max_ch_from_blocks) max_ch_from_blocks = k.* + 1;
        }
        const max_channel_count = @max(meta.channels.len, max_ch_from_blocks);

        const channels = self.allocator.alloc(SummaryChannel, max_channel_count) catch return error.OutOfMemory;
        var initialized_channels: usize = 0;
        errdefer {
            for (channels[0..initialized_channels]) |*ch| ch.deinit(self.allocator);
            self.allocator.free(channels);
        }

        for (0..max_channel_count) |index| {
            var meta_ch: ?types.ChannelInfo = null;
            for (meta.channels) |ch| {
                if (ch.index == index) {
                    meta_ch = ch;
                    break;
                }
            }

            const name = if (meta_ch) |mc|
                if (mc.name) |n| (self.allocator.dupe(u8, n) catch return error.OutOfMemory) else null
            else
                null;
            errdefer if (name) |n| self.allocator.free(n);

            const color = if (meta_ch) |mc|
                if (mc.color) |c| (self.allocator.dupe(u8, c) catch return error.OutOfMemory) else null
            else
                null;
            errdefer if (color) |c| self.allocator.free(c);

            const pt_enum: ?PixelType = if (meta_ch) |mc|
                mc.pixel_type orelse ch_pixel_types.get(index)
            else
                ch_pixel_types.get(index);

            const pixel_type = if (pt_enum) |pt|
                (self.allocator.dupe(u8, pt.asStr()) catch return error.OutOfMemory)
            else
                null;

            channels[index] = .{
                .index = index,
                .name = name,
                .color = color,
                .pixel_type = pixel_type,
            };
            initialized_channels += 1;
        }

        const primary_pixel_type = if (meta.image.pixel_type) |pt|
            (self.allocator.dupe(u8, pt.asStr()) catch return error.OutOfMemory)
        else
            null;
        errdefer if (primary_pixel_type) |pt| self.allocator.free(pt);

        const scaling: ?SummaryScaling = if (meta.scaling.x != null or
            meta.scaling.y != null or
            meta.scaling.z != null or
            meta.scaling.unit != null)
        blk: {
            const unit_copy = if (meta.scaling.unit) |u|
                (self.allocator.dupe(u8, u) catch return error.OutOfMemory)
            else
                null;
            break :blk .{
                .x = meta.scaling.x,
                .y = meta.scaling.y,
                .z = meta.scaling.z,
                .unit = unit_copy,
            };
        } else null;

        const ver = self.version();
        return .{
            .version_major = ver.major,
            .version_minor = ver.minor,
            .sizes = dim_sizes,
            .logical_frame_count = logical_frame_count,
            .channels = channels,
            .pixel_type = primary_pixel_type,
            .scaling = scaling,
        };
    }

    pub fn logicalFrameCount(self: *const CziFile) CziError!usize {
        var total: usize = 1;
        for (Dimension.FRAME_ORDER) |dim| {
            const size = if (self.statistics.dim_bounds.get(dim)) |interval| interval.size else 1;
            if (size > 1) {
                total = std.math.mul(usize, total, size) catch return error.Overflow;
            }
        }
        return total;
    }

    fn channelPixelTypes(self: *const CziFile) CziError!std.AutoHashMapUnmanaged(usize, PixelType) {
        const channel_start: i32 = if (self.statistics.dim_bounds.get(.C)) |interval| interval.start else 0;
        var map: std.AutoHashMapUnmanaged(usize, PixelType) = .empty;
        errdefer map.deinit(self.allocator);

        for (self.subblocks) |subblock| {
            const actual_channel = subblock.coordinate.get(.C) orelse channel_start;
            const rel: usize = @intCast(@max(actual_channel - channel_start, 0));
            const gop = map.getOrPut(self.allocator, rel) catch return error.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = subblock.pixel_type;
            }
        }
        return map;
    }

    /// Read one logical 2D frame by flat index (0..logical_frame_count).
    /// Returns decoded grayscale pixels as `[]u16` in row-major order (height x width).
    /// Caller owns the returned slice and must free it with `self.allocator`.
    pub fn readFrame(self: *CziFile, index: usize) CziError![]u16 {
        var varying_dims: [Dimension.FRAME_ORDER.len]struct { dim: Dimension, size: usize } = undefined;
        var varying_len: usize = 0;
        var total: usize = 1;

        for (Dimension.FRAME_ORDER) |dim| {
            const size = if (self.statistics.dim_bounds.get(dim)) |interval| interval.size else 1;
            if (size > 1) {
                varying_dims[varying_len] = .{ .dim = dim, .size = size };
                varying_len += 1;
                total = std.math.mul(usize, total, size) catch return error.Overflow;
            }
        }

        if (index >= total) return error.OutOfRange;

        var plane = PlaneIndex.init();
        if (varying_len > 0) {
            var rem = index;
            var i = varying_len;
            while (i > 0) {
                i -= 1;
                const d = varying_dims[i];
                plane.set(d.dim, rem % d.size);
                rem /= d.size;
            }
        }

        var bitmap = try self.readPlane(plane);
        defer bitmap.deinit(self.allocator);
        return bitmap.toGrayU16(self.allocator);
    }

    /// Read a 2D plane at the specified coordinates: Scene (`s`), Time (`t`), Channel (`c`), and Z-slice (`z`).
    /// Returns decoded grayscale pixels as `[]u16` in row-major order (height x width).
    /// Caller owns the returned slice and must free it with `self.allocator`.
    pub fn readFrame2d(self: *CziFile, s: usize, t: usize, c: usize, z: usize) CziError![]u16 {
        const plane = PlaneIndex.init()
            .with(.S, s)
            .with(.T, t)
            .with(.C, c)
            .with(.Z, z);
        var bitmap = try self.readPlane(plane);
        defer bitmap.deinit(self.allocator);
        return bitmap.toGrayU16(self.allocator);
    }

    pub fn readPlane(self: *CziFile, index: PlaneIndex) CziError!Bitmap {
        const actual = try self.resolvePlaneIndex(index);
        const plane_rect = self.selectPlaneRect(actual.get(.S)) orelse return error.InvalidFormat;
        if (plane_rect.w <= 0 or plane_rect.h <= 0) return error.InvalidFormat;

        var matching: std.ArrayList(DirectorySubBlockInfo) = .empty;
        defer matching.deinit(self.allocator);

        for (self.subblocks) |subblock| {
            if (self.matchesPlane(subblock, actual)) {
                matching.append(self.allocator, subblock) catch return error.OutOfMemory;
            }
        }
        if (matching.items.len == 0) return error.InvalidFormat;

        std.mem.sort(DirectorySubBlockInfo, matching.items, {}, struct {
            fn lessThan(_: void, a: DirectorySubBlockInfo, b: DirectorySubBlockInfo) bool {
                const ma = a.m_index orelse std.math.minInt(i32);
                const mb = b.m_index orelse std.math.minInt(i32);
                if (ma != mb) return ma < mb;
                return a.file_position < b.file_position;
            }
        }.lessThan);

        const pixel_type = matching.items[0].pixel_type;
        for (matching.items[1..]) |sb| {
            if (sb.pixel_type != pixel_type) return error.InvalidFormat;
        }

        var bitmap = try Bitmap.zeros(self.allocator, pixel_type, @intCast(plane_rect.w), @intCast(plane_rect.h));
        errdefer bitmap.deinit(self.allocator);

        for (matching.items) |subblock| {
            var raw = try parse_mod.readRawSubBlock(self.allocator, self.source, subblock);
            defer raw.deinit(self.allocator);
            var tile = try parse_mod.decodeSubBlockBitmap(self.allocator, raw);
            defer tile.deinit(self.allocator);
            try blitTile(
                &bitmap,
                tile,
                subblock.rect.x - plane_rect.x,
                subblock.rect.y - plane_rect.y,
            );
        }

        return bitmap;
    }

    fn resolvePlaneIndex(self: *const CziFile, index: PlaneIndex) CziError!Coordinate {
        var actual = Coordinate.init();

        for (Dimension.FRAME_ORDER) |dimension| {
            const requested = index.get(dimension);
            if (self.statistics.dim_bounds.get(dimension)) |interval| {
                const relative: usize = if (requested) |val|
                    val
                else if (interval.size <= 1)
                    0
                else
                    return error.MissingDimension;

                if (relative >= interval.size) return error.OutOfRange;
                actual.set(dimension, interval.start + @as(i32, @intCast(relative)));
            } else {
                if ((requested orelse 0) != 0) return error.InvalidArgument;
            }
        }

        return actual;
    }

    fn selectPlaneRect(self: *const CziFile, scene: ?i32) ?IntRect {
        if (scene) |s| {
            if (self.statistics.scene_bounding_boxes.get(s)) |boxes| {
                if (boxes.layer0.isValid()) return boxes.layer0;
                if (boxes.all.isValid()) return boxes.all;
            }
        }
        return self.statistics.bounding_box_layer0 orelse self.statistics.bounding_box;
    }

    fn matchesPlane(self: *const CziFile, subblock: DirectorySubBlockInfo, actual: Coordinate) bool {
        if (!subblock.isLayer0()) return false;

        for (Dimension.FRAME_ORDER) |dimension| {
            const requested_value = actual.get(dimension) orelse continue;
            if (subblock.coordinate.get(dimension)) |value| {
                if (value != requested_value) return false;
            } else {
                const has_multiple = if (self.statistics.dim_bounds.get(dimension)) |interval|
                    interval.size > 1
                else
                    false;
                if (has_multiple) return false;
            }
        }
        return true;
    }
};

fn blitTile(
    destination: *Bitmap,
    source: Bitmap,
    offset_x: i32,
    offset_y: i32,
) CziError!void {
    if (destination.pixel_type != source.pixel_type) return error.InvalidFormat;

    const source_rect = IntRect.init(
        offset_x,
        offset_y,
        @intCast(source.width),
        @intCast(source.height),
    );
    const destination_rect = IntRect.init(
        0,
        0,
        @intCast(destination.width),
        @intCast(destination.height),
    );
    const intersection = source_rect.intersect(destination_rect) orelse return;

    const bytes_per_pixel = destination.pixel_type.bytesPerPixel();
    for (0..@as(usize, @intCast(intersection.h))) |row| {
        const src_x: usize = @intCast(intersection.x - offset_x);
        const src_y: usize = @as(usize, @intCast(intersection.y - offset_y)) + row;
        const dst_x: usize = @intCast(intersection.x);
        const dst_y: usize = @as(usize, @intCast(intersection.y)) + row;
        const row_bytes = @as(usize, @intCast(intersection.w)) * bytes_per_pixel;

        const src_row_off = std.math.mul(usize, src_y, source.stride) catch return error.Overflow;
        const src_offset = std.math.add(usize, src_row_off, src_x * bytes_per_pixel) catch return error.Overflow;
        const dst_row_off = std.math.mul(usize, dst_y, destination.stride) catch return error.Overflow;
        const dst_offset = std.math.add(usize, dst_row_off, dst_x * bytes_per_pixel) catch return error.Overflow;

        @memcpy(
            destination.data[dst_offset .. dst_offset + row_bytes],
            source.data[src_offset .. src_offset + row_bytes],
        );
    }
}
