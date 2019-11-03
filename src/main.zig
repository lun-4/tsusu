const std = @import("std");

const daemon = @import("daemon.zig");

const fs = std.fs;
const os = std.os;
const mem = std.mem;

pub const Context = struct {
    allocator: *std.mem.Allocator,
    args_it: std.process.ArgIterator,
    tries: usize = 0,

    pub fn init(allocator: *std.mem.Allocator, args_it: std.process.ArgIterator) Context {
        return Context{
            .allocator = allocator,
            .args_it = args_it,
        };
    }

    pub fn checkDaemon(self: *Context) anyerror!std.fs.File {
        if (self.tries >= 3) return error.SpawnFail;
        self.tries += 1;

        return std.net.connectUnixSocket(
            "/home/luna/.local/share/tsusu.sock",
        ) catch |err| {
            try spawnDaemon();

            // assuming spawning doesn't take more than 500ms.
            std.time.sleep(500 * std.time.millisecond);
            return try self.checkDaemon();
        };
    }
};

fn spawnDaemon() !void {
    var pid = try std.os.fork();

    if (pid < 0) {
        return error.ForkFail;
    }

    if (pid > 0) {
        return;
    }

    const daemon_pid = os.linux.getpid();
    const pidpath = "/home/luna/.local/share/tsusu.pid";
    var pidfile = try std.fs.File.openWrite(pidpath);
    var stream = &pidfile.outStream().stream;
    try stream.print("{}", daemon_pid);
    pidfile.close();

    defer {
        std.os.unlink(pidpath) catch |err| {}; // do nothing on errors
    }

    // TODO setsid
    // TODO umask

    try daemon.main();
}

pub fn main() anyerror!void {
    // every time we start, we check if we have a daemon running.
    var arena = std.heap.ArenaAllocator.init(std.heap.direct_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var args_it = std.process.args();
    _ = args_it.skip();

    var ctx = Context.init(allocator, args_it);
    const sock = try ctx.checkDaemon();
    defer sock.close();

    std.debug.warn("sock fd from client connected: {}\n", sock.handle);

    //const mode = args_it.next(allocator);
    //if (std.mem.eql(u8, mode, "destroy")) {}
}
