const std = @import("std");
const czi_mod = @import("czi");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (args.len < 2) {
        std.debug.print("Usage: {s} <path-to-czi-file>\n", .{args[0]});
        std.process.exit(1);
    }

    const path = args[1];
    var czi = try czi_mod.CziFile.open(allocator, io, path);
    defer czi.deinit();

    const ver = czi.version();
    try stdout.print("=== CZI File Information ===\n", .{});
    try stdout.print("Version: {d}.{d}\n", .{ ver.major, ver.minor });

    var summary = try czi.summary();
    defer summary.deinit(allocator);

    try stdout.print("Logical frames: {d}\n", .{summary.logical_frame_count});
    try stdout.print(
        "Sizes: X={d} Y={d} C={d} Z={d} T={d} S={d}\n",
        .{
            summary.sizes.get("X") orelse 0,
            summary.sizes.get("Y") orelse 0,
            summary.sizes.get("C") orelse 1,
            summary.sizes.get("Z") orelse 1,
            summary.sizes.get("T") orelse 1,
            summary.sizes.get("S") orelse 1,
        },
    );

    for (summary.channels) |ch| {
        try stdout.print(
            "Channel #{d}: name={s} color={s} pixel_type={s}\n",
            .{
                ch.index,
                ch.name orelse "(none)",
                ch.color orelse "(none)",
                ch.pixel_type orelse "(none)",
            },
        );
    }

    if (summary.scaling) |sc| {
        try stdout.print(
            "Scaling: X={?d} Y={?d} Z={?d} unit={s}\n",
            .{ sc.x, sc.y, sc.z, sc.unit orelse "" },
        );
    }

    const first_plane = try czi.readFrame2d(0, 0, 0, 0);
    defer allocator.free(first_plane);
    try stdout.print("First plane pixels: {d}\n", .{first_plane.len});
}
