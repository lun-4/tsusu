const std = @import("std");

pub const Resource = enum {
    Sock,
    Log,
    Pid,
};

pub fn fetchDataDir(allocator: *std.mem.Allocator) ![]const u8 {
    return try std.fs.getAppDataDir(allocator, "tsusu");
}

pub fn getPathFor(
    allocator: *std.mem.Allocator,
    resource: Resource,
) ![]const u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{
        try fetchDataDir(allocator),
        switch (resource) {
            .Sock => "tsusu.sock",
            .Log => "tsusu.log",
            .Pid => "tsusu.pid",
        },
    });
}
