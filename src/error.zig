const std = @import("std");

pub const CziError = error{
    // File errors
    IoError,
    InvalidFormat,
    InvalidMagic,
    MetadataParse,
    InvalidUtf8,
    Decompression,
    // Input errors
    OutOfRange,
    MissingDimension,
    InvalidArgument,
    // Internal errors
    Overflow,
    OutOfMemory,
    // Unsupported errors
    UnsupportedDirectorySchema,
    UnsupportedSubBlockSchema,
    UnsupportedCompression,
    UnsupportedPixelType,
};

pub const ErrorSource = enum {
    /// Errors arising from invalid, corrupt, or truncated file content.
    file,
    /// Errors caused by out-of-range indices or invalid caller arguments.
    input,
    /// Errors caused by internal invariants or arithmetic overflow.
    internal,
    /// Errors caused by unsupported format features or codecs.
    unsupported,

    pub fn asStr(self: ErrorSource) []const u8 {
        return switch (self) {
            .file => "File",
            .input => "Input",
            .internal => "Internal",
            .unsupported => "Unsupported",
        };
    }

    pub fn format(self: ErrorSource, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.asStr());
    }
};

pub fn classifyError(err: CziError) ErrorSource {
    return switch (err) {
        error.IoError,
        error.InvalidFormat,
        error.InvalidMagic,
        error.MetadataParse,
        error.InvalidUtf8,
        error.Decompression,
        => .file,

        error.OutOfRange,
        error.MissingDimension,
        error.InvalidArgument,
        => .input,

        error.Overflow,
        error.OutOfMemory,
        => .internal,

        error.UnsupportedDirectorySchema,
        error.UnsupportedSubBlockSchema,
        error.UnsupportedCompression,
        error.UnsupportedPixelType,
        => .unsupported,
    };
}

pub fn isFileError(err: CziError) bool {
    return classifyError(err) == .file;
}

pub fn isInputError(err: CziError) bool {
    return classifyError(err) == .input;
}

pub fn isInternalError(err: CziError) bool {
    return classifyError(err) == .internal;
}

pub fn isUnsupportedError(err: CziError) bool {
    return classifyError(err) == .unsupported;
}
