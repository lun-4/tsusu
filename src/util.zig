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

/// Wraps a file descriptor with a mutex to prevent
/// data corruption by separate threads, and keeps
/// a `closed` flag to stop threads from trying to
/// operate on something that is closed (that would give EBADF,
/// which is a race condition, aanicking the program)
pub const WrappedWriter = struct {
    file: std.fs.File,
    lock: std.Mutex,
    closed: bool = false,

    pub fn init(fd: std.os.fd_t) @This() {
        return .{
            .file = std.fs.File{ .handle = fd },
            .lock = std.Mutex.init(),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.lock.deinit();
    }

    pub fn markClosed(self: *@This()) void {
        const held = self.lock.acquire();
        defer held.release();
        self.closed = true;
    }

    pub const WriterError = std.fs.File.WriteError || error{Closed};
    pub const Writer = std.io.Writer(*@This(), WriterError, write);
    pub fn writer(self: *@This()) Writer {
        return .{ .context = self };
    }

    pub fn write(self: *@This(), bytes: []const u8) WriteError!usize {
        const held = self.lock.acquire();
        defer held.release();
        if (self.closed) return error.Closed;
        return try self.file.write(data);
    }
};

/// Wraps a file descriptor with a mutex to prevent
/// data corruption by separate threads, and keeps
/// a `closed` flag to stop threads from trying to
/// operate on something that is closed (that would give EBADF,
/// which is a race condition, aanicking the program)
pub const WrappedReader = struct {
    file: std.fs.File,
    lock: std.Mutex,
    closed: bool = false,

    pub fn init(fd: std.os.fd_t) @This() {
        return .{
            .file = std.fs.File{ .handle = fd },
            .lock = std.Mutex.init(),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.lock.deinit();
    }

    pub fn markClosed(self: *@This()) void {
        const held = self.lock.acquire();
        defer held.release();
        self.closed = true;
    }

    pub const ReadrError = std.fs.File.ReadError || error{Closed};
    pub const Readr = std.io.Reader(*@This(), ReaderError, read);
    pub fn reader(self: *@This()) Reader {
        return .{ .context = self };
    }

    pub fn read(self: *@This(), buffer: []u8) ReadError!usize {
        const held = self.lock.acquire();
        defer held.release();
        if (self.closed) return error.Closed;
        return try self.file.read(data);
    }
};
