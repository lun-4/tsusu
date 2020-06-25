const std = @import("std");

const daemon = @import("daemon.zig");

pub const Client = struct {
    fd: std.os.fd_t,
    lock: std.Mutex,
    closed: bool = false,

    pub fn init(fd: std.os.fd_t) @This() {
        return .{
            .fd = fd,
            .lock = std.Mutex.init(),
        };
    }

    pub fn deinit(self: *@This()) void {
        std.debug.warn("client deinit @ {x}\n", .{@ptrToInt(self)});
        self.lock.deinit();
        std.os.close(self.fd);
    }

    pub fn close(self: *@This()) void {
        const held = self.lock.acquire();
        defer held.release();
        self.closed = true;
    }

    pub fn stream(self: *@This()) std.fs.File.Writer {
        var file = std.fs.File{ .handle = self.fd };
        return file.writer();
    }

    pub fn write(self: *@This(), data: []const u8) !void {
        const held = self.lock.acquire();
        defer held.release();
        if (self.closed) return error.Closed;
        return try self.stream().write(data);
    }

    pub fn print(self: *@This(), comptime fmt: []const u8, args: var) !void {
        const held = self.lock.acquire();
        defer held.release();
        if (self.closed) return error.Closed;
        return try self.stream().print(fmt, args);
    }
};
