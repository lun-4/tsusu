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
        self.lock.deinit();
    }

    pub fn close(self: *@This()) void {
        const held = self.lock.acquire();
        defer held.release();
        std.debug.warn("client closing\n", .{});
        self.closed = true;
        std.debug.warn("client closed\n", .{});
    }

    pub fn write(self: *@This(), data: []const u8) !void {
        const held = self.lock.acquire();
        defer held.release();
        std.debug.warn("closed? {}\n", .{self.closed});
        if (self.closed) return error.Closed;
        return try self.stream.write(data);
    }

    pub fn print(self: *@This(), comptime fmt: []const u8, args: var) !void {
        const held = self.lock.acquire();
        defer held.release();
        std.debug.warn("closed? {}\n", .{self.closed});
        if (self.closed) return error.Closed;
        return try self.stream.print(fmt, args);
    }
};
