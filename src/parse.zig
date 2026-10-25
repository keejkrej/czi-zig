const std = @import("std");
const CziError = @import("error.zig").CziError;
const Source = @import("io.zig").Source;
const types = @import("types.zig");
const AttachmentBlob = types.AttachmentBlob;
const AttachmentInfo = types.AttachmentInfo;
const Bitmap = types.Bitmap;
const BoundingBoxes = types.BoundingBoxes;
const CompressionMode = types.CompressionMode;
const Coordinate = types.Coordinate;
const Dimension = types.Dimension;
const DirectorySubBlockInfo = types.DirectorySubBlockInfo;
const FileHeaderInfo = types.FileHeaderInfo;
const IntRect = types.IntRect;
const IntSize = types.IntSize;
const PixelType = types.PixelType;
const RawSubBlock = types.RawSubBlock;
const SubBlockPyramidType = types.SubBlockPyramidType;
const SubBlockStatistics = types.SubBlockStatistics;

const SEGMENT_HEADER_SIZE: usize = 32;
const FILE_HEADER_DATA_SIZE: usize = 512;
const SUBBLOCK_DIRECTORY_DATA_SIZE: usize = 128;
const METADATA_DATA_SIZE: usize = 256;
const ATTACHMENT_DATA_SIZE: usize = 256;
const SUBBLOCK_MIN_DATA_SIZE: usize = 256;
const DIMENSION_ENTRY_DV_SIZE: usize = 20;
const SUBBLOCK_DIRECTORY_ENTRY_DV_FIXED_SIZE: usize = 32;
const SUBBLOCK_SEGMENT_FIXED_SIZE: usize = 16;

const FILE_MAGIC = "ZISRAWFILE\x00\x00\x00\x00\x00\x00";
const SUBBLOCK_DIRECTORY_MAGIC = "ZISRAWDIRECTORY\x00";
const SUBBLOCK_MAGIC = "ZISRAWSUBBLOCK\x00\x00";
const METADATA_MAGIC = "ZISRAWMETADATA\x00\x00";
const ATTACHMENT_DIRECTORY_MAGIC = "ZISRAWATTDIR\x00\x00\x00\x00";
const ATTACHMENT_MAGIC = "ZISRAWATTACH\x00\x00\x00\x00";

pub const ParsedCziFile = struct {
    header: FileHeaderInfo,
    subblocks: []DirectorySubBlockInfo,
    attachments: []AttachmentInfo,
    statistics: SubBlockStatistics,

    pub fn deinit(self: *ParsedCziFile, allocator: std.mem.Allocator) void {
        allocator.free(self.subblocks);
        for (self.attachments) |*att| att.deinit(allocator);
        allocator.free(self.attachments);
        self.statistics.deinit(allocator);
    }
};

const SegmentHeader = struct {
    magic: [16]u8,
    allocated_size: u64,
    used_size: u64,

    fn read(source: Source, offset: u64) CziError!SegmentHeader {
        var bytes: [SEGMENT_HEADER_SIZE]u8 = undefined;
        try source.readExactAtInto(offset, &bytes);
        var magic: [16]u8 = undefined;
        @memcpy(&magic, bytes[0..16]);
        return .{
            .magic = magic,
            .allocated_size = try leU64(&bytes, 16),
            .used_size = try leU64(&bytes, 24),
        };
    }

    fn effectiveSize(self: SegmentHeader) u64 {
        return if (self.used_size != 0) self.used_size else self.allocated_size;
    }
};

pub fn parseFile(allocator: std.mem.Allocator, source: Source) CziError!ParsedCziFile {
    const header = try parseFileHeader(source);
    var dir_res = try parseSubBlockDirectory(allocator, source, header.subblock_directory_position);
    errdefer {
        allocator.free(dir_res.subblocks);
        dir_res.statistics.deinit(allocator);
    }

    const attachments = if (header.attachment_directory_position == 0)
        try allocator.alloc(AttachmentInfo, 0)
    else
        try parseAttachmentDirectory(allocator, source, header.attachment_directory_position);

    return .{
        .header = header,
        .subblocks = dir_res.subblocks,
        .attachments = attachments,
        .statistics = dir_res.statistics,
    };
}

pub fn readMetadataXml(allocator: std.mem.Allocator, source: Source, offset: u64) CziError![]u8 {
    if (offset == 0) {
        return allocator.alloc(u8, 0) catch return error.OutOfMemory;
    }

    const header = try SegmentHeader.read(source, offset);
    try ensureMagic(&header.magic, METADATA_MAGIC);

    var fixed: [METADATA_DATA_SIZE]u8 = undefined;
    try source.readExactAtInto(try checkedAdd(offset, SEGMENT_HEADER_SIZE), &fixed);
    const xml_size: usize = @intCast(try leU32(&fixed, 0));
    if (xml_size == 0) {
        return allocator.alloc(u8, 0) catch return error.OutOfMemory;
    }

    const xml_bytes = try source.readExactAt(
        allocator,
        try checkedAdd(offset, SEGMENT_HEADER_SIZE + METADATA_DATA_SIZE),
        xml_size,
    );
    errdefer allocator.free(xml_bytes);
    if (!std.unicode.utf8ValidateSlice(xml_bytes)) {
        return error.InvalidUtf8;
    }
    return xml_bytes;
}

pub fn readRawSubBlock(allocator: std.mem.Allocator, source: Source, info: DirectorySubBlockInfo) CziError!RawSubBlock {
    const header = try SegmentHeader.read(source, info.file_position);
    try ensureMagic(&header.magic, SUBBLOCK_MAGIC);

    var prefix: [SUBBLOCK_MIN_DATA_SIZE]u8 = undefined;
    try source.readExactAtInto(try checkedAdd(info.file_position, SEGMENT_HEADER_SIZE), &prefix);

    const metadata_size: usize = @intCast(try leU32(&prefix, 0));
    const attachment_size: usize = @intCast(try leU32(&prefix, 4));
    const data_size_u64 = try leU64(&prefix, 8);
    const data_size = std.math.cast(usize, data_size_u64) orelse return error.Overflow;
    const schema = prefix[16..18];

    const dynamic_header_size: usize = if (std.mem.eql(u8, schema, "DV")) blk: {
        const dimension_count: usize = @intCast(try leU32(&prefix, 44));
        if (dimension_count > 1024) return error.InvalidFormat;
        const dims_bytes = std.math.mul(usize, dimension_count, DIMENSION_ENTRY_DV_SIZE) catch return error.Overflow;
        break :blk std.math.add(usize, SUBBLOCK_SEGMENT_FIXED_SIZE + SUBBLOCK_DIRECTORY_ENTRY_DV_FIXED_SIZE, dims_bytes) catch return error.Overflow;
    } else if (std.mem.eql(u8, schema, "DE")) {
        return error.UnsupportedSubBlockSchema;
    } else {
        return error.InvalidFormat;
    };

    const effective_header_size = @max(dynamic_header_size, SUBBLOCK_MIN_DATA_SIZE);
    const metadata_offset = try checkedAdd(info.file_position, @intCast(SEGMENT_HEADER_SIZE + effective_header_size));
    const data_offset = try checkedAdd(metadata_offset, @intCast(metadata_size));
    const attachment_offset = try checkedAdd(data_offset, @intCast(data_size));

    const declared_size = std.math.cast(usize, header.effectiveSize()) orelse return error.Overflow;
    const actual_end_1 = std.math.add(usize, effective_header_size, metadata_size) catch return error.Overflow;
    const actual_end_2 = std.math.add(usize, actual_end_1, data_size) catch return error.Overflow;
    const actual_end = std.math.add(usize, actual_end_2, attachment_size) catch return error.Overflow;
    if (declared_size < actual_end) return error.InvalidFormat;

    const metadata = if (metadata_size == 0)
        allocator.alloc(u8, 0) catch return error.OutOfMemory
    else
        try source.readExactAt(allocator, metadata_offset, metadata_size);
    errdefer allocator.free(metadata);

    const data = if (data_size == 0)
        allocator.alloc(u8, 0) catch return error.OutOfMemory
    else
        try source.readExactAt(allocator, data_offset, data_size);
    errdefer allocator.free(data);

    const attachment = if (attachment_size == 0)
        allocator.alloc(u8, 0) catch return error.OutOfMemory
    else
        try source.readExactAt(allocator, attachment_offset, attachment_size);
    errdefer allocator.free(attachment);

    return .{
        .info = info,
        .metadata = metadata,
        .data = data,
        .attachment = attachment,
    };
}

pub fn decodeSubBlockBitmap(allocator: std.mem.Allocator, raw: RawSubBlock) CziError!Bitmap {
    return decodeBitmap(allocator, raw.info, raw.data);
}

pub fn decodeBitmap(allocator: std.mem.Allocator, info: DirectorySubBlockInfo, encoded: []const u8) CziError!Bitmap {
    const expected_len = try expectedBitmapLen(info);

    const decoded: []u8 = switch (info.compression) {
        .UnCompressed => try normalizePlainFromSlice(allocator, encoded, expected_len),
        .Zstd0 => blk: {
            const raw_decoded = try decompressZstd(allocator, encoded);
            defer allocator.free(raw_decoded);
            break :blk try normalizePlainFromSlice(allocator, raw_decoded, expected_len);
        },
        .Zstd1 => try decodeZstd1(allocator, info, encoded, expected_len),
        .Jpg, .JpgXr => return error.UnsupportedCompression,
    };
    errdefer allocator.free(decoded);

    return Bitmap.init(
        info.pixel_type,
        info.stored_size.w,
        info.stored_size.h,
        decoded,
    );
}

fn parseFileHeader(source: Source) CziError!FileHeaderInfo {
    const header = try SegmentHeader.read(source, 0);
    try ensureMagic(&header.magic, FILE_MAGIC);

    var data: [FILE_HEADER_DATA_SIZE]u8 = undefined;
    try source.readExactAtInto(SEGMENT_HEADER_SIZE, &data);
    return .{
        .major = try leI32(&data, 0),
        .minor = try leI32(&data, 4),
        .primary_file_guid = try parseGuid(data[16..32]),
        .file_guid = try parseGuid(data[32..48]),
        .file_part = try leI32(&data, 48),
        .subblock_directory_position = try leU64(&data, 52),
        .metadata_position = try leU64(&data, 60),
        .update_pending = (try leI32(&data, 68)) != 0,
        .attachment_directory_position = try leU64(&data, 72),
    };
}

const DirectoryParseResult = struct {
    subblocks: []DirectorySubBlockInfo,
    statistics: SubBlockStatistics,
};

fn parseSubBlockDirectory(
    allocator: std.mem.Allocator,
    source: Source,
    offset: u64,
) CziError!DirectoryParseResult {
    const header = try SegmentHeader.read(source, offset);
    try ensureMagic(&header.magic, SUBBLOCK_DIRECTORY_MAGIC);

    var fixed: [SUBBLOCK_DIRECTORY_DATA_SIZE]u8 = undefined;
    try source.readExactAtInto(try checkedAdd(offset, SEGMENT_HEADER_SIZE), &fixed);
    const entry_count = try leI32(&fixed, 0);
    if (entry_count < 0) return error.InvalidFormat;

    const eff_size = header.effectiveSize();
    if (eff_size < SUBBLOCK_DIRECTORY_DATA_SIZE) return error.InvalidFormat;
    const payload_size = std.math.cast(usize, eff_size - SUBBLOCK_DIRECTORY_DATA_SIZE) orelse return error.Overflow;

    const payload = try source.readExactAt(
        allocator,
        try checkedAdd(offset, SEGMENT_HEADER_SIZE + SUBBLOCK_DIRECTORY_DATA_SIZE),
        payload_size,
    );
    defer allocator.free(payload);

    var cursor: usize = 0;
    var subblocks: std.ArrayList(DirectorySubBlockInfo) = .empty;
    errdefer subblocks.deinit(allocator);
    subblocks.ensureTotalCapacity(allocator, @intCast(entry_count)) catch return error.OutOfMemory;

    var statistics: SubBlockStatistics = .{};
    errdefer statistics.deinit(allocator);

    for (0..@as(usize, @intCast(entry_count))) |index| {
        if (cursor + 2 > payload.len) return error.InvalidFormat;
        const schema = payload[cursor .. cursor + 2];
        if (std.mem.eql(u8, schema, "DE")) return error.UnsupportedDirectorySchema;
        if (!std.mem.eql(u8, schema, "DV")) return error.InvalidFormat;
        if (cursor + SUBBLOCK_DIRECTORY_ENTRY_DV_FIXED_SIZE > payload.len) return error.InvalidFormat;

        const pixel_type_raw = try leI32(payload, cursor + 2);
        const pixel_type = PixelType.fromRaw(pixel_type_raw) orelse return error.UnsupportedPixelType;
        const file_position = try leU64(payload, cursor + 6);
        const file_part = try leI32(payload, cursor + 14);
        const compression_raw = try leI32(payload, cursor + 18);
        const compression = CompressionMode.fromRaw(compression_raw) orelse return error.UnsupportedCompression;
        const pyramid_type = SubBlockPyramidType.fromRaw(payload[cursor + 22]);
        const dimension_count_raw = try leI32(payload, cursor + 28);
        if (dimension_count_raw < 0 or dimension_count_raw > 1024) return error.InvalidFormat;
        const dimension_count: usize = @intCast(dimension_count_raw);

        const dims_bytes = std.math.mul(usize, dimension_count, DIMENSION_ENTRY_DV_SIZE) catch return error.Overflow;
        const entry_size = std.math.add(usize, SUBBLOCK_DIRECTORY_ENTRY_DV_FIXED_SIZE, dims_bytes) catch return error.Overflow;
        if (cursor + entry_size > payload.len) return error.InvalidFormat;

        var coordinate = Coordinate.init();
        var rect = IntRect.init(0, 0, -1, -1);
        var stored_size = IntSize{ .w = 0, .h = 0 };
        var has_x = false;
        var has_y = false;
        var m_index: ?i32 = null;

        var dim_cursor = cursor + SUBBLOCK_DIRECTORY_ENTRY_DV_FIXED_SIZE;
        for (0..dimension_count) |_| {
            const dim_code = parseDimCode(payload[dim_cursor .. dim_cursor + 4]);
            const start = try leI32(payload, dim_cursor + 4);
            const size = try leI32(payload, dim_cursor + 8);
            const stored = try leI32(payload, dim_cursor + 16);

            if (Dimension.fromCode(dim_code)) |dim| {
                switch (dim) {
                    .X => {
                        rect.x = start;
                        rect.w = size;
                        stored_size.w = @intCast(@max(stored, 0));
                        has_x = true;
                    },
                    .Y => {
                        rect.y = start;
                        rect.h = size;
                        stored_size.h = @intCast(@max(stored, 0));
                        has_y = true;
                    },
                    .M => {
                        m_index = start;
                    },
                    else => {
                        if (dim.isFrameDimension()) {
                            coordinate.set(dim, start);
                        }
                    },
                }
            }
            dim_cursor += DIMENSION_ENTRY_DV_SIZE;
        }

        if (!has_x or !has_y) return error.InvalidFormat;

        const info = DirectorySubBlockInfo{
            .index = index,
            .file_position = file_position,
            .file_part = file_part,
            .pixel_type = pixel_type,
            .compression = compression,
            .coordinate = coordinate,
            .rect = rect,
            .stored_size = stored_size,
            .m_index = m_index,
            .pyramid_type = pyramid_type,
        };
        try updateStatistics(allocator, &statistics, info);
        subblocks.append(allocator, info) catch return error.OutOfMemory;
        cursor += entry_size;
    }

    return .{
        .subblocks = subblocks.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .statistics = statistics,
    };
}

fn parseAttachmentDirectory(
    allocator: std.mem.Allocator,
    source: Source,
    offset: u64,
) CziError![]AttachmentInfo {
    const header = try SegmentHeader.read(source, offset);
    try ensureMagic(&header.magic, ATTACHMENT_DIRECTORY_MAGIC);

    var fixed: [256]u8 = undefined;
    try source.readExactAtInto(try checkedAdd(offset, SEGMENT_HEADER_SIZE), &fixed);
    const entry_count_raw = try leI32(&fixed, 0);
    if (entry_count_raw < 0) return error.InvalidFormat;
    const count: usize = @intCast(entry_count_raw);
    const entry_size: usize = 128;
    const payload_size = std.math.mul(usize, count, entry_size) catch return error.Overflow;

    const payload = try source.readExactAt(
        allocator,
        try checkedAdd(offset, SEGMENT_HEADER_SIZE + 256),
        payload_size,
    );
    defer allocator.free(payload);

    var attachments: std.ArrayList(AttachmentInfo) = .empty;
    errdefer {
        for (attachments.items) |*att| att.deinit(allocator);
        attachments.deinit(allocator);
    }

    for (0..count) |index| {
        const start = index * entry_size;
        const end = start + entry_size;
        const entry = payload[start..end];
        if (!std.mem.eql(u8, entry[0..2], "A1")) continue;

        const file_position = try leU64(entry, 12);
        const file_part = try leI32(entry, 20);
        const content_guid = try parseGuid(entry[24..40]);
        const content_file_type = allocator.dupe(u8, parseFixedString(entry[40..48])) catch return error.OutOfMemory;
        errdefer allocator.free(content_file_type);
        const name = allocator.dupe(u8, parseFixedString(entry[48..128])) catch return error.OutOfMemory;
        errdefer allocator.free(name);
        const data_size = try readAttachmentDataSize(source, file_position);

        attachments.append(allocator, .{
            .index = index,
            .file_position = file_position,
            .file_part = file_part,
            .content_guid = content_guid,
            .content_file_type = content_file_type,
            .name = name,
            .data_size = data_size,
        }) catch return error.OutOfMemory;
    }

    return attachments.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn readAttachmentDataSize(source: Source, offset: u64) CziError!u64 {
    const header = try SegmentHeader.read(source, offset);
    try ensureMagic(&header.magic, ATTACHMENT_MAGIC);
    var prefix: [16]u8 = undefined;
    try source.readExactAtInto(try checkedAdd(offset, SEGMENT_HEADER_SIZE), &prefix);
    return leU64(&prefix, 0);
}

fn updateStatistics(allocator: std.mem.Allocator, statistics: *SubBlockStatistics, entry: DirectorySubBlockInfo) CziError!void {
    statistics.subblock_count += 1;

    if (statistics.bounding_box) |*existing| {
        existing.unionWith(entry.rect);
    } else {
        statistics.bounding_box = entry.rect;
    }

    if (entry.isLayer0()) {
        if (statistics.bounding_box_layer0) |*existing| {
            existing.unionWith(entry.rect);
        } else {
            statistics.bounding_box_layer0 = entry.rect;
        }
    }

    for (0..Dimension.count) |dim_idx| {
        if (entry.coordinate.values[dim_idx]) |value| {
            statistics.dim_bounds.updateValue(@enumFromInt(dim_idx), value);
        }
    }

    if (entry.m_index) |m_idx| {
        statistics.min_m_index = if (statistics.min_m_index) |v| @min(v, m_idx) else m_idx;
        statistics.max_m_index = if (statistics.max_m_index) |v| @max(v, m_idx) else m_idx;
    }

    if (entry.coordinate.get(.S)) |scene_index| {
        const gop = statistics.scene_bounding_boxes.getOrPut(allocator, scene_index) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .all = entry.rect,
                .layer0 = IntRect.init(0, 0, -1, -1),
            };
        } else {
            gop.value_ptr.all.unionWith(entry.rect);
        }
        if (entry.isLayer0()) {
            if (gop.value_ptr.layer0.isValid()) {
                gop.value_ptr.layer0.unionWith(entry.rect);
            } else {
                gop.value_ptr.layer0 = entry.rect;
            }
        }
    }
}

fn decompressZstd(allocator: std.mem.Allocator, compressed: []const u8) CziError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var in: std.Io.Reader = .fixed(compressed);
    var zstd_stream: std.compress.zstd.Decompress = .init(&in, &.{}, .{});
    _ = zstd_stream.reader.streamRemaining(&out.writer) catch return error.Decompression;

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn decodeZstd1(
    allocator: std.mem.Allocator,
    info: DirectorySubBlockInfo,
    encoded: []const u8,
    expected_len: usize,
) CziError![]u8 {
    const zstd1_hdr = try parseZstd1Header(encoded);
    const compressed = encoded[zstd1_hdr.header_size..];
    const decoded = try decompressZstd(allocator, compressed);
    defer allocator.free(decoded);

    if (zstd1_hdr.unpack_lo_hi) {
        if (info.pixel_type != .Gray16 and info.pixel_type != .Bgr48) {
            return error.UnsupportedPixelType;
        }
        return normalizeHiLo(allocator, decoded, expected_len);
    } else {
        return normalizePlainFromSlice(allocator, decoded, expected_len);
    }
}

const Zstd1Header = struct {
    header_size: usize,
    unpack_lo_hi: bool,
};

fn parseZstd1Header(encoded: []const u8) CziError!Zstd1Header {
    if (encoded.len == 0) return error.Decompression;
    return switch (encoded[0]) {
        1 => .{ .header_size = 1, .unpack_lo_hi = false },
        3 => blk: {
            if (encoded.len < 3) return error.Decompression;
            if (encoded[1] != 1) return error.Decompression;
            break :blk .{ .header_size = 3, .unpack_lo_hi = (encoded[2] & 1) == 1 };
        },
        else => error.Decompression,
    };
}

fn normalizePlainFromSlice(allocator: std.mem.Allocator, decoded: []const u8, expected_len: usize) CziError![]u8 {
    const out = allocator.alloc(u8, expected_len) catch return error.OutOfMemory;
    const copy_len = @min(decoded.len, expected_len);
    @memcpy(out[0..copy_len], decoded[0..copy_len]);
    if (copy_len < expected_len) {
        @memset(out[copy_len..], 0);
    }
    return out;
}

fn normalizeHiLo(allocator: std.mem.Allocator, decoded: []const u8, expected_len: usize) CziError![]u8 {
    if (decoded.len % 2 != 0) return error.Decompression;
    const unpacked = allocator.alloc(u8, decoded.len) catch return error.OutOfMemory;
    defer allocator.free(unpacked);

    const half = decoded.len / 2;
    for (0..half) |index| {
        unpacked[index * 2] = decoded[index];
        unpacked[index * 2 + 1] = decoded[index + half];
    }

    return normalizePlainFromSlice(allocator, unpacked, expected_len);
}

fn expectedBitmapLen(info: DirectorySubBlockInfo) CziError!usize {
    const area = std.math.mul(usize, @as(usize, info.stored_size.w), @as(usize, info.stored_size.h)) catch return error.Overflow;
    return std.math.mul(usize, area, info.pixel_type.bytesPerPixel()) catch return error.Overflow;
}

fn checkedAdd(lhs: u64, rhs: u64) CziError!u64 {
    return std.math.add(u64, lhs, rhs) catch return error.Overflow;
}

fn ensureMagic(actual: *const [16]u8, expected: *const [16]u8) CziError!void {
    if (!std.mem.eql(u8, actual, expected)) {
        return error.InvalidMagic;
    }
}

fn parseGuid(bytes: []const u8) CziError![36]u8 {
    if (bytes.len != 16) return error.InvalidFormat;
    const data1 = std.mem.readInt(u32, bytes[0..4], .little);
    const data2 = std.mem.readInt(u16, bytes[4..6], .little);
    const data3 = std.mem.readInt(u16, bytes[6..8], .little);
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(
        &out,
        "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            data1,     data2,     data3,
            bytes[8],  bytes[9],  bytes[10],
            bytes[11], bytes[12], bytes[13],
            bytes[14], bytes[15],
        },
    ) catch unreachable;
    return out;
}

fn parseDimCode(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return std.mem.trim(u8, bytes[0..end], " \t\r\n");
}

fn parseFixedString(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return std.mem.trim(u8, bytes[0..end], " \t\r\n");
}

fn leI32(bytes: []const u8, offset: usize) CziError!i32 {
    if (offset + 4 > bytes.len) return error.InvalidFormat;
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

fn leU32(bytes: []const u8, offset: usize) CziError!u32 {
    if (offset + 4 > bytes.len) return error.InvalidFormat;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn leU64(bytes: []const u8, offset: usize) CziError!u64 {
    if (offset + 8 > bytes.len) return error.InvalidFormat;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}
