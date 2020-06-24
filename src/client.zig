const std = @import("std");

const daemon = @import("daemon.zig");

pub const Client = struct {
    stream: daemon.OutStream,
    lock: std.Mutex,

    closed: bool = false,

    pub fn init(stream: daemon.OutStream) @This() {
        return .{
            .stream = stream,
            .lock = std.Mutex.init(),
        };
    }

    pub fn deinit(self: *@This()) void {
        std.debug.warn("client deinitting\n", .{});
        self.lock.deinit();
    }

    pub fn close(self: *@This()) void {
        const held = self.lock.acquire();
        defer held.release();
        std.debug.warn("client closing. ptr={x} self.closed={}\n", .{ @ptrToInt(self), self.closed });
        self.closed = true;
        std.debug.warn("client closed. ptr={x} self.closed={}\n", .{ @ptrToInt(self), self.closed });
    }

    pub fn write(self: *@This(), data: []const u8) !void {
        const held = self.lock.acquire();
        defer held.release();
        std.debug.warn("self={x} closed? {}\n", .{ @ptrToInt(self), self.closed });
        if (self.closed) return error.Closed;
        return try self.stream.write(data);
    }

    pub fn print(self: *@This(), comptime fmt: []const u8, args: var) !void {
        const held = self.lock.acquire();
        defer held.release();
        std.debug.warn("self={x} self.closed={}\n", .{ @ptrToInt(self), self.closed });
        if (self.closed) return error.Closed;
        return try self.stream.print(fmt, args);
    }
};
