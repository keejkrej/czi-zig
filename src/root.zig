const std = @import("std");

pub const err = @import("error.zig");
pub const io = @import("io.zig");
pub const metadata = @import("metadata.zig");
pub const parse = @import("parse.zig");
pub const reader = @import("reader.zig");
pub const types = @import("types.zig");

pub const CziError = err.CziError;
pub const ErrorSource = err.ErrorSource;
pub const classifyError = err.classifyError;
pub const isFileError = err.isFileError;
pub const isInputError = err.isInputError;
pub const isInternalError = err.isInternalError;
pub const isUnsupportedError = err.isUnsupportedError;

pub const Source = io.Source;
pub const CziFile = reader.CziFile;

pub const AttachmentBlob = types.AttachmentBlob;
pub const AttachmentInfo = types.AttachmentInfo;
pub const Bitmap = types.Bitmap;
pub const BoundingBoxes = types.BoundingBoxes;
pub const ChannelInfo = types.ChannelInfo;
pub const CompressionMode = types.CompressionMode;
pub const Coordinate = types.Coordinate;
pub const DatasetSummary = types.DatasetSummary;
pub const DimBounds = types.DimBounds;
pub const Dimension = types.Dimension;
pub const DimensionSizes = types.DimensionSizes;
pub const DirectorySubBlockInfo = types.DirectorySubBlockInfo;
pub const DocumentInfo = types.DocumentInfo;
pub const FileHeaderInfo = types.FileHeaderInfo;
pub const ImageInfo = types.ImageInfo;
pub const IntRect = types.IntRect;
pub const IntSize = types.IntSize;
pub const Interval = types.Interval;
pub const MetadataSummary = types.MetadataSummary;
pub const PixelType = types.PixelType;
pub const PlaneIndex = types.PlaneIndex;
pub const RawSubBlock = types.RawSubBlock;
pub const ScalingInfo = types.ScalingInfo;
pub const SubBlockPyramidType = types.SubBlockPyramidType;
pub const SubBlockStatistics = types.SubBlockStatistics;
pub const SummaryChannel = types.SummaryChannel;
pub const SummaryScaling = types.SummaryScaling;

test "open nonexistent fails" {
    const res = CziFile.open(std.testing.allocator, std.testing.io, "nonexistent_file_xyz.czi");
    try std.testing.expectError(error.IoError, res);
    if (res) |_| unreachable else |e| {
        try std.testing.expect(isFileError(e));
    }
}

test "open invalid file fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const garbage: [200]u8 = @splat(0);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "garbage.czi", .data = &garbage });

    const file = try tmp.dir.openFile(std.testing.io, "garbage.czi", .{});
    const src: Source = .{ .file = .{ .file = file, .io = std.testing.io, .owned = true } };
    var src_mut = src;
    defer src_mut.close();

    const res = CziFile.openSource(std.testing.allocator, src_mut);
    try std.testing.expectError(error.InvalidMagic, res);
    if (res) |_| unreachable else |e| {
        try std.testing.expect(isFileError(e));
    }
}

test "open memory invalid stream" {
    const garbage: [100]u8 = @splat(0);
    const res = CziFile.openMemory(std.testing.allocator, &garbage);
    try std.testing.expectError(error.InvalidMagic, res);
    if (res) |_| unreachable else |e| {
        try std.testing.expect(isFileError(e));
        try std.testing.expectEqual(ErrorSource.file, classifyError(e));
    }
}

test "error classification helpers" {
    try std.testing.expect(isFileError(error.InvalidFormat));
    try std.testing.expect(!isInputError(error.InvalidFormat));
    try std.testing.expect(!isInternalError(error.InvalidFormat));
    try std.testing.expect(!isUnsupportedError(error.InvalidFormat));

    try std.testing.expect(!isFileError(error.OutOfRange));
    try std.testing.expect(isInputError(error.OutOfRange));

    try std.testing.expect(isInternalError(error.Overflow));
    try std.testing.expect(isUnsupportedError(error.UnsupportedCompression));
}

test "synthetic in-memory CZI file roundtrip" {
    // Build a valid minimal CZI file in memory:
    // Segment 0: FileHeader (offset 0, header 32 + data 512 = 544)
    // Segment 1: SubBlockDirectory (offset 544, header 32 + fixed 128 + 1 DV entry)
    // Segment 2: Metadata XML (offset 1024)
    // Segment 3: SubBlock 0 (offset 2048)
    const allocator = std.testing.allocator;
    var buf = try allocator.alloc(u8, 4096);
    defer allocator.free(buf);
    @memset(buf, 0);

    // 1. FileHeader at 0
    @memcpy(buf[0..16], "ZISRAWFILE\x00\x00\x00\x00\x00\x00");
    std.mem.writeInt(u64, buf[16..24], 512, .little);
    std.mem.writeInt(u64, buf[24..32], 512, .little);
    std.mem.writeInt(i32, buf[32..36], 1, .little); // major = 1
    std.mem.writeInt(i32, buf[36..40], 0, .little); // minor = 0
    std.mem.writeInt(u64, buf[32 + 52 ..][0..8], 544, .little); // subblock_dir_pos = 544
    std.mem.writeInt(u64, buf[32 + 60 ..][0..8], 1024, .little); // metadata_pos = 1024
    std.mem.writeInt(u64, buf[32 + 72 ..][0..8], 0, .little); // attachment_dir_pos = 0

    // 2. SubBlockDirectory at 544
    // 1 DV entry with 3 dimensions (X, Y, C) => 32 + 3 * 20 = 92 bytes
    const dv_size: usize = 32 + 3 * 20;
    @memcpy(buf[544..560], "ZISRAWDIRECTORY\x00");
    std.mem.writeInt(u64, buf[560..568], 128 + dv_size, .little);
    std.mem.writeInt(u64, buf[568..576], 128 + dv_size, .little);
    std.mem.writeInt(i32, buf[576..580], 1, .little); // entry_count = 1

    const entry_off: usize = 544 + 32 + 128;
    @memcpy(buf[entry_off .. entry_off + 2], "DV");
    std.mem.writeInt(i32, buf[entry_off + 2 ..][0..4], 1, .little); // Gray16
    std.mem.writeInt(u64, buf[entry_off + 6 ..][0..8], 2048, .little); // file_position = 2048
    std.mem.writeInt(i32, buf[entry_off + 14 ..][0..4], 0, .little); // file_part
    std.mem.writeInt(i32, buf[entry_off + 18 ..][0..4], 0, .little); // UnCompressed
    buf[entry_off + 22] = 0; // PyramidType.None
    std.mem.writeInt(i32, buf[entry_off + 28 ..][0..4], 3, .little); // 3 dims

    // Dim 0: X (start=0, size=2, stored=2)
    const d0 = entry_off + 32;
    @memcpy(buf[d0 .. d0 + 4], "X\x00\x00\x00");
    std.mem.writeInt(i32, buf[d0 + 4 ..][0..4], 0, .little);
    std.mem.writeInt(i32, buf[d0 + 8 ..][0..4], 2, .little);
    std.mem.writeInt(i32, buf[d0 + 16 ..][0..4], 2, .little);

    // Dim 1: Y (start=0, size=2, stored=2)
    const d1 = d0 + 20;
    @memcpy(buf[d1 .. d1 + 4], "Y\x00\x00\x00");
    std.mem.writeInt(i32, buf[d1 + 4 ..][0..4], 0, .little);
    std.mem.writeInt(i32, buf[d1 + 8 ..][0..4], 2, .little);
    std.mem.writeInt(i32, buf[d1 + 16 ..][0..4], 2, .little);

    // Dim 2: C (start=0, size=1, stored=1)
    const d2 = d1 + 20;
    @memcpy(buf[d2 .. d2 + 4], "C\x00\x00\x00");
    std.mem.writeInt(i32, buf[d2 + 4 ..][0..4], 0, .little);
    std.mem.writeInt(i32, buf[d2 + 8 ..][0..4], 1, .little);
    std.mem.writeInt(i32, buf[d2 + 16 ..][0..4], 1, .little);

    // 3. Metadata XML at 1024
    const xml =
        \\<ImageDocument>
        \\  <Metadata>
        \\    <Information>
        \\      <Image>
        \\        <PixelType>Gray16</PixelType>
        \\        <SizeX>2</SizeX>
        \\        <SizeY>2</SizeY>
        \\        <SizeC>1</SizeC>
        \\        <Dimensions>
        \\          <Channels>
        \\            <Channel Id="Channel:0" Name="DAPI">
        \\              <PixelType>Gray16</PixelType>
        \\              <Color>#FF4080FF</Color>
        \\            </Channel>
        \\          </Channels>
        \\        </Dimensions>
        \\      </Image>
        \\    </Information>
        \\    <Scaling>
        \\      <Items>
        \\        <Distance Id="X"><Value>0.325</Value><DefaultUnitFormat>um</DefaultUnitFormat></Distance>
        \\        <Distance Id="Y"><Value>0.325</Value></Distance>
        \\      </Items>
        \\    </Scaling>
        \\  </Metadata>
        \\</ImageDocument>
    ;
    @memcpy(buf[1024..1040], "ZISRAWMETADATA\x00\x00");
    std.mem.writeInt(u64, buf[1040..1048], 256 + xml.len, .little);
    std.mem.writeInt(u64, buf[1048..1056], 256 + xml.len, .little);
    std.mem.writeInt(u32, buf[1056..1060], @intCast(xml.len), .little);
    @memcpy(buf[1024 + 32 + 256 ..][0..xml.len], xml);

    // 4. SubBlock at 2048 (header 32 + min data header 256 + 8 bytes pixel data)
    @memcpy(buf[2048..2064], "ZISRAWSUBBLOCK\x00\x00");
    std.mem.writeInt(u64, buf[2064..2072], 256 + 8, .little);
    std.mem.writeInt(u64, buf[2072..2080], 256 + 8, .little);
    const sb_hdr = 2048 + 32;
    std.mem.writeInt(u32, buf[sb_hdr + 0 ..][0..4], 0, .little); // metadata_size = 0
    std.mem.writeInt(u32, buf[sb_hdr + 4 ..][0..4], 0, .little); // attachment_size = 0
    std.mem.writeInt(u64, buf[sb_hdr + 8 ..][0..8], 8, .little); // data_size = 8 (4 u16 pixels)
    @memcpy(buf[sb_hdr + 16 .. sb_hdr + 18], "DV");
    std.mem.writeInt(u32, buf[sb_hdr + 44 ..][0..4], 3, .little); // dimension_count = 3

    const pixel_off = sb_hdr + 256;
    std.mem.writeInt(u16, buf[pixel_off + 0 ..][0..2], 100, .little);
    std.mem.writeInt(u16, buf[pixel_off + 2 ..][0..2], 200, .little);
    std.mem.writeInt(u16, buf[pixel_off + 4 ..][0..2], 300, .little);
    std.mem.writeInt(u16, buf[pixel_off + 6 ..][0..2], 400, .little);

    var czi = try CziFile.openMemory(allocator, buf);
    defer czi.deinit();

    const ver = czi.version();
    try std.testing.expectEqual(@as(u32, 1), ver.major);
    try std.testing.expectEqual(@as(u32, 0), ver.minor);

    var summary = try czi.summary();
    defer summary.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), summary.sizes.get("X").?);
    try std.testing.expectEqual(@as(usize, 2), summary.sizes.get("Y").?);
    try std.testing.expectEqual(@as(usize, 1), summary.sizes.get("C").?);
    try std.testing.expectEqual(@as(usize, 1), summary.logical_frame_count);
    try std.testing.expectEqual(@as(usize, 1), summary.channels.len);
    try std.testing.expectEqualStrings("DAPI", summary.channels[0].name.?);
    try std.testing.expectEqualStrings("#FF4080FF", summary.channels[0].color.?);
    try std.testing.expect(summary.scaling != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.325), summary.scaling.?.x.?, 1e-6);

    const frame = try czi.readFrame2d(0, 0, 0, 0);
    defer allocator.free(frame);
    try std.testing.expectEqualSlices(u16, &[_]u16{ 100, 200, 300, 400 }, frame);

    const flat_frame = try czi.readFrame(0);
    defer allocator.free(flat_frame);
    try std.testing.expectEqualSlices(u16, &[_]u16{ 100, 200, 300, 400 }, flat_frame);
}

test "real OME CZI fixture integration" {
    const allocator = std.testing.allocator;
    const io_ctx = std.testing.io;
    const fixture_path = "/Users/jack/workspace/czi-zig/tests/fixtures/Plate1-Blue-A-02-Scene-1-P2-E1-01.czi";
    var czi = CziFile.open(allocator, io_ctx, fixture_path) catch |e| switch (e) {
        error.IoError => return, // Skip if fixture not downloaded
        else => return e,
    };
    defer czi.deinit();

    const ver = czi.version();
    try std.testing.expect(ver.major >= 1);

    var summary = try czi.summary();
    defer summary.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 672), summary.sizes.get("X").?);
    try std.testing.expectEqual(@as(usize, 512), summary.sizes.get("Y").?);
    try std.testing.expectEqual(@as(usize, 3), summary.sizes.get("C").?);
    try std.testing.expectEqual(@as(usize, 21), summary.sizes.get("Z").?);
    try std.testing.expectEqual(@as(usize, 63), summary.logical_frame_count);
    try std.testing.expectEqual(@as(usize, 3), summary.channels.len);

    const plane = try czi.readFrame(0);
    defer allocator.free(plane);
    try std.testing.expectEqual(@as(usize, 672 * 512), plane.len);

    const plane2d = try czi.readFrame2d(0, 0, 0, 0);
    defer allocator.free(plane2d);
    try std.testing.expectEqualSlices(u16, plane, plane2d);
}
