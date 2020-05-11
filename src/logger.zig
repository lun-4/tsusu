const std = @import("std");

pub fn Logger(OutStream: var) type {
    return struct {
        stream: OutStream,
        prefix: []const u8,

        pub fn init(stream: var, prefix: []const u8) @This() {
            return .{ .stream = stream, .prefix = prefix };
        }

        /// Log a message.
        pub fn info(self: @This(), comptime fmt: []const u8, args: var) void {
            const tstamp = std.time.timestamp();
            self.stream.print("{} {} ", .{ tstamp, self.prefix }) catch |err| {};
            self.stream.print(fmt, args) catch |err| {
                std.debug.warn("error sending line {} {}: {}\n", .{ fmt, args, err });
            };
            _ = self.stream.write("\n") catch |err| {};
        }
    };
}
