# czi-zig

Fast, memory-efficient, pure Zig reader for Zeiss CZI (`.czi`) microscopy files.

Ported from `czi-rs` to Zig with zero external C/C++ dependencies (uses `std.compress.zstd` for Zstd0 and Zstd1 decompression).

## Features

- **Pure Zig**: Portable Zig implementation with zero external dependencies.
- **Multi-Dimensional Navigation**: Read 2D planes by `(Scene, Time, Channel, Z)` coordinates via `readFrame2d(s, t, c, z)` or flat frame index via `readFrame(index)`.
- **Compression Support**: Supports uncompressed, `Zstd0`, and `Zstd1` (including HiLo byte-split unpacking) subblocks.
- **Tile Compositing**: Automatically composites multi-tile layer-0 subblocks across scenes and bounding boxes.
- **XML Metadata & Summary**: Extracts channel names, colors, pixel types, and physical voxel scaling (`X`, `Y`, `Z` distances and units).

## Build & Test

```sh
zig build
zig build test
```
