const std = @import("std");
const CziError = @import("error.zig").CziError;
const types = @import("types.zig");
const ChannelInfo = types.ChannelInfo;
const Dimension = types.Dimension;
const DocumentInfo = types.DocumentInfo;
const ImageInfo = types.ImageInfo;
const MetadataSummary = types.MetadataSummary;
const PixelType = types.PixelType;
const ScalingInfo = types.ScalingInfo;

pub fn parseMetadataXml(allocator: std.mem.Allocator, xml: []const u8) CziError!MetadataSummary {
    const trimmed = std.mem.trim(u8, xml, " \t\r\n\x00");
    if (trimmed.len == 0) return .{};

    // Basic well-formedness check
    if (std.mem.indexOfScalar(u8, trimmed, '<') == null or std.mem.indexOfScalar(u8, trimmed, '>') == null) {
        return error.MetadataParse;
    }

    const information = findPath(trimmed, &.{ "Metadata", "Information" }) orelse findTagContent(trimmed, "Information");
    const image_node = if (information) |info| findTagContent(info, "Image") else findTagContent(trimmed, "Image");
    const document_node = if (information) |info| findTagContent(info, "Document") else null;
    const application_node = if (information) |info| findTagContent(info, "Application") else null;
    const scaling_node = findPath(trimmed, &.{ "Metadata", "Scaling" }) orelse findTagContent(trimmed, "Scaling");

    var summary: MetadataSummary = .{};
    errdefer summary.deinit(allocator);

    summary.document = try parseDocument(allocator, document_node, application_node);
    summary.image = parseImage(image_node);
    summary.scaling = try parseScaling(allocator, scaling_node);
    summary.channels = try parseChannels(allocator, image_node);

    return summary;
}

fn parseDocument(allocator: std.mem.Allocator, doc_node: ?[]const u8, app_node: ?[]const u8) CziError!DocumentInfo {
    var doc: DocumentInfo = .{};
    errdefer doc.deinit(allocator);

    if (doc_node) |node| {
        doc.name = try childTextOwned(allocator, node, "Name");
        doc.title = try childTextOwned(allocator, node, "Title");
        doc.comment = try childTextOwned(allocator, node, "Comment");
        doc.author = try childTextOwned(allocator, node, "Author");
        doc.user_name = try childTextOwned(allocator, node, "UserName");
        doc.creation_date = try childTextOwned(allocator, node, "CreationDate");
        doc.description = try childTextOwned(allocator, node, "Description");
    }

    if (app_node) |node| {
        doc.application_name = try childTextOwned(allocator, node, "Name");
        doc.application_version = try childTextOwned(allocator, node, "Version");
    }

    return doc;
}

fn parseImage(image_node: ?[]const u8) ImageInfo {
    var image: ImageInfo = .{};
    const node = image_node orelse return image;

    if (childTextSlice(node, "PixelType")) |pt| {
        image.pixel_type = PixelType.fromName(pt);
    }

    const dim_codes = [_]Dimension{ .Z, .C, .T, .R, .S, .I, .H, .V, .B, .X, .Y, .M };
    for (dim_codes) |dim| {
        var tag_buf: [8]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "Size{s}", .{dim.asStr()}) catch continue;
        if (childTextSlice(node, tag)) |val_str| {
            if (std.fmt.parseInt(usize, val_str, 10)) |val| {
                image.sizes[@intFromEnum(dim)] = val;
            } else |_| {}
        }
    }

    return image;
}

fn parseChannels(allocator: std.mem.Allocator, image_node: ?[]const u8) CziError![]ChannelInfo {
    const node = image_node orelse return &.{};
    const channels_node = findPath(node, &.{ "Dimensions", "Channels" }) orelse findTagContent(node, "Channels") orelse return &.{};

    var list: std.ArrayList(ChannelInfo) = .empty;
    errdefer {
        for (list.items) |*ch| ch.deinit(allocator);
        list.deinit(allocator);
    }

    var cursor: usize = 0;
    var index: usize = 0;
    while (nextElement(channels_node, &cursor, "Channel")) |elem| {
        var ch: ChannelInfo = .{ .index = index };
        errdefer ch.deinit(allocator);

        if (extractAttribute(elem.open_tag, "Id")) |id| {
            ch.id = allocator.dupe(u8, id) catch return error.OutOfMemory;
        }
        if (extractAttribute(elem.open_tag, "Name")) |name| {
            ch.name = allocator.dupe(u8, name) catch return error.OutOfMemory;
        }
        if (childTextSlice(elem.inner, "PixelType")) |pt| {
            ch.pixel_type = PixelType.fromName(pt);
        }
        ch.color = try childTextOwned(allocator, elem.inner, "Color");

        list.append(allocator, ch) catch return error.OutOfMemory;
        index += 1;
    }

    return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn parseScaling(allocator: std.mem.Allocator, scaling_node: ?[]const u8) CziError!ScalingInfo {
    var scaling: ScalingInfo = .{};
    errdefer scaling.deinit(allocator);

    const node = scaling_node orelse return scaling;
    const items = findTagContent(node, "Items") orelse node;

    var cursor: usize = 0;
    while (nextElement(items, &cursor, "Distance")) |elem| {
        const value: ?f64 = if (childTextSlice(elem.inner, "Value")) |v|
            std.fmt.parseFloat(f64, v) catch null
        else
            null;

        if (extractAttribute(elem.open_tag, "Id")) |id_raw| {
            const id = std.mem.trim(u8, id_raw, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(id, "X")) scaling.x = value;
            if (std.ascii.eqlIgnoreCase(id, "Y")) scaling.y = value;
            if (std.ascii.eqlIgnoreCase(id, "Z")) scaling.z = value;
        }

        if (scaling.unit == null) {
            const unit_slice = childTextSlice(elem.inner, "DefaultUnitFormat") orelse
                childTextSlice(elem.inner, "Unit") orelse
                childTextSlice(elem.inner, "UnitFormat");
            if (unit_slice) |u| {
                scaling.unit = allocator.dupe(u8, u) catch return error.OutOfMemory;
            }
        }
    }

    return scaling;
}

const ElementMatch = struct {
    open_tag: []const u8,
    inner: []const u8,
};

fn findPath(root: []const u8, path: []const []const u8) ?[]const u8 {
    var current: []const u8 = root;
    for (path) |name| {
        current = findTagContent(current, name) orelse return null;
    }
    return current;
}

fn findTagContent(xml: []const u8, tag_name: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    if (nextElement(xml, &cursor, tag_name)) |elem| {
        return elem.inner;
    }
    return null;
}

fn nextElement(xml: []const u8, cursor: *usize, tag_name: []const u8) ?ElementMatch {
    var pos = cursor.*;
    while (pos < xml.len) {
        const lt = std.mem.indexOfScalarPos(u8, xml, pos, '<') orelse return null;
        if (lt + 1 + tag_name.len > xml.len) return null;

        if (std.mem.eql(u8, xml[lt + 1 .. lt + 1 + tag_name.len], tag_name)) {
            const after_name = lt + 1 + tag_name.len;
            if (after_name < xml.len) {
                const next_ch = xml[after_name];
                if (next_ch == '>' or next_ch == '/' or std.ascii.isWhitespace(next_ch)) {
                    const gt = std.mem.indexOfScalarPos(u8, xml, after_name, '>') orelse return null;
                    const open_tag = xml[lt + 1 .. gt];
                    if (gt > lt and xml[gt - 1] == '/') {
                        cursor.* = gt + 1;
                        return .{ .open_tag = open_tag, .inner = "" };
                    }
                    // Find matching closing tag </tag_name>
                    const inner_start = gt + 1;
                    var search_pos = inner_start;
                    var depth: usize = 1;
                    while (search_pos < xml.len) {
                        const next_lt = std.mem.indexOfScalarPos(u8, xml, search_pos, '<') orelse return null;
                        if (next_lt + 1 < xml.len and xml[next_lt + 1] == '/') {
                            if (next_lt + 2 + tag_name.len < xml.len and
                                std.mem.eql(u8, xml[next_lt + 2 .. next_lt + 2 + tag_name.len], tag_name))
                            {
                                const close_end = next_lt + 2 + tag_name.len;
                                if (xml[close_end] == '>' or std.ascii.isWhitespace(xml[close_end])) {
                                    depth -= 1;
                                    if (depth == 0) {
                                        const close_gt = std.mem.indexOfScalarPos(u8, xml, close_end, '>') orelse return null;
                                        cursor.* = close_gt + 1;
                                        return .{
                                            .open_tag = open_tag,
                                            .inner = xml[inner_start..next_lt],
                                        };
                                    }
                                }
                            }
                        } else if (next_lt + 1 + tag_name.len < xml.len and
                            std.mem.eql(u8, xml[next_lt + 1 .. next_lt + 1 + tag_name.len], tag_name))
                        {
                            const c_after = xml[next_lt + 1 + tag_name.len];
                            if (c_after == '>' or c_after == '/' or std.ascii.isWhitespace(c_after)) {
                                const nested_gt = std.mem.indexOfScalarPos(u8, xml, next_lt + 1 + tag_name.len, '>') orelse return null;
                                if (xml[nested_gt - 1] != '/') {
                                    depth += 1;
                                }
                                search_pos = nested_gt + 1;
                                continue;
                            }
                        }
                        search_pos = next_lt + 1;
                    }
                    return null;
                }
            }
        }
        pos = lt + 1;
    }
    return null;
}

fn extractAttribute(open_tag: []const u8, attr_name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < open_tag.len) {
        const idx = std.mem.indexOfPos(u8, open_tag, pos, attr_name) orelse return null;
        if (idx > 0 and !std.ascii.isWhitespace(open_tag[idx - 1])) {
            pos = idx + attr_name.len;
            continue;
        }
        var eq_pos = idx + attr_name.len;
        while (eq_pos < open_tag.len and std.ascii.isWhitespace(open_tag[eq_pos])) : (eq_pos += 1) {}
        if (eq_pos >= open_tag.len or open_tag[eq_pos] != '=') {
            pos = eq_pos;
            continue;
        }
        var quote_pos = eq_pos + 1;
        while (quote_pos < open_tag.len and std.ascii.isWhitespace(open_tag[quote_pos])) : (quote_pos += 1) {}
        if (quote_pos >= open_tag.len) return null;
        const quote = open_tag[quote_pos];
        if (quote != '"' and quote != '\'') {
            pos = quote_pos + 1;
            continue;
        }
        const val_start = quote_pos + 1;
        const val_end = std.mem.indexOfScalarPos(u8, open_tag, val_start, quote) orelse return null;
        return open_tag[val_start..val_end];
    }
    return null;
}

fn childTextSlice(node: []const u8, tag_name: []const u8) ?[]const u8 {
    const inner = findTagContent(node, tag_name) orelse return null;
    const trimmed = std.mem.trim(u8, inner, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn childTextOwned(allocator: std.mem.Allocator, node: []const u8, tag_name: []const u8) CziError!?[]u8 {
    const slice = childTextSlice(node, tag_name) orelse return null;
    return allocator.dupe(u8, slice) catch return error.OutOfMemory;
}
