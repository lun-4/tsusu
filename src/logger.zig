const std = @import("std");

pub fn Logger(OutStream: var) type {
    return struct {
        stream: OutStream,
        prefix: []const u8,
        lock: std.Mutex,

        pub fn init(stream: var, prefix: []const u8) @This() {
            return .{ .stream = stream, .prefix = prefix, .lock = std.Mutex.init() };
        }

        pub fn deinit(self: *@This()) void {
            self.lock.deinit();
        }

        /// Log a message.
        pub fn info(self: *@This(), comptime fmt: []const u8, args: var) void {
            const held = self.lock.acquire();
            defer held.release();

            const tstamp = std.time.timestamp();
            self.stream.print("{} {} ", .{ tstamp, self.prefix }) catch |err| {};
            self.stream.print(fmt, args) catch |err| {
                std.debug.warn("error sending line {} {}: {}\n", .{ fmt, args, err });
            };
            _ = self.stream.write("\n") catch |err| {};
        }

        pub fn printTrace(self: *@This(), stack_trace: std.builtin.StackTrace) void {
            if (std.builtin.strip_debug_info) {
                self.stream.print("Unable to dump stack trace: debug info stripped\n", .{}) catch return;
                return;
            }

            const debug_info = std.debug.getSelfDebugInfo() catch |err| {
                self.stream.print("Unable to dump stack trace: Unable to open debug info: {}\n", .{@errorName(err)}) catch return;
                return;
            };

            std.debug.writeStackTrace(stack_trace, self.stream, std.heap.page_allocator, debug_info, std.debug.detectTTYConfig()) catch |err| {
                self.stream.print("Unable to dump stack trace: {}\n", .{@errorName(err)}) catch return;
                return;
            };
        }
    };
}
