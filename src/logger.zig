const std = @import("std");

pub fn Logger(OutStream: anytype) type {
    return struct {
        stream: OutStream,
        prefix: []const u8,
        lock: std.Mutex,

        pub fn init(stream: anytype, prefix: []const u8) @This() {
            return .{ .stream = stream, .prefix = prefix, .lock = std.Mutex.init() };
        }

        pub fn deinit(self: *@This()) void {
            self.lock.deinit();
        }

        /// Log a message.
        pub fn info(self: *@This(), comptime fmt: []const u8, args: anytype) void {
            const held = self.lock.acquire();
            defer held.release();

            const tstamp = std.time.timestamp();
            self.stream.print("{} {} ", .{ tstamp, self.prefix }) catch |err| {};
            self.stream.print(fmt, args) catch |err| {
                std.debug.warn("error sending line {} {}: {}\n", .{ fmt, args, err });
            };
            _ = self.stream.write("\n") catch |err| {};
        }
    };
}
