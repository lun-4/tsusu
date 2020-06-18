const std = @import("std");

// TODO make this receive a stream and write into it directly instead of
// dealing with memory.
pub fn prettyMemoryUsage(buffer: []u8, kilobytes: u64) ![]const u8 {
    const megabytes = kilobytes / 1024;
    const gigabytes = megabytes / 1024;

    if (kilobytes < 1024) {
        return try std.fmt.bufPrint(buffer, "{} KB", .{kilobytes});
    } else if (megabytes < 1024) {
        return try std.fmt.bufPrint(buffer, "{d:.2} MB", .{megabytes});
    } else if (gigabytes < 1024) {
        return try std.fmt.bufPrint(buffer, "{d:.2} GB", .{gigabytes});
    } else {
        return try std.fmt.bufPrint(buffer, "how", .{});
    }
}
