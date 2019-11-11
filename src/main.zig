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
            std.time.sleep(1000 * std.time.millisecond);
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

pub const Mode = enum {
    Destroy,
    Start,
    Stop,
    Help,
    List,
};

fn getMode(mode_arg: []const u8) !Mode {
    if (std.mem.eql(u8, mode_arg, "destroy")) return .Destroy;
    if (std.mem.eql(u8, mode_arg, "start")) return .Start;
    if (std.mem.eql(u8, mode_arg, "stop")) return .Stop;
    if (std.mem.eql(u8, mode_arg, "help")) return .Help;
    if (std.mem.eql(u8, mode_arg, "list")) return .List;
    return error.UnknownMode;
}

pub fn main() anyerror!void {
    // every time we start, we check if we have a daemon running.
    var arena = std.heap.ArenaAllocator.init(std.heap.direct_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var args_it = std.process.args();
    _ = args_it.skip();

    const mode_arg = try (args_it.next(allocator) orelse @panic("expected mode"));
    const mode = try getMode(mode_arg);

    // switch for things that don't depend on an existing daemon

    switch (mode) {
        .Destroy => {
            const pidpath = "/home/luna/.local/share/tsusu.pid";
            var pidfile = std.fs.File.openRead(pidpath) catch |err| {
                std.debug.warn("Failed to open PID file. is the daemon running?\n");
                return;
            };

            var buf: [100]u8 = undefined;
            const count = try pidfile.read(&buf);
            const pid_str = buf[0..count];

            var pid_int = std.fmt.parseInt(os.pid_t, pid_str, 10) catch |err| {
                std.debug.warn("Failed to parse pid '{}': {}\n", pid_str, err);
                return;
            };

            // TODO pr back to zig about ESRCH being unknown pid,
            // and not a race condition
            try std.os.kill(pid_int, std.os.SIGINT);

            // TODO make daemon do unlinking upon sigint
            std.os.unlink(pidpath) catch |err| {};
            const sockpath = "/home/luna/.local/share/tsusu.sock";
            std.os.unlink(sockpath) catch |err| {};

            std.debug.warn("sent SIGINT to pid {}\n", pid_int);
            return;
        },
        else => {},
    }

    var ctx = Context.init(allocator, args_it);
    const sock = try ctx.checkDaemon();
    defer sock.close();

    std.debug.warn("sock fd from client connected: {}\n", sock.handle);

    switch (mode) {
        .List => std.debug.warn("TODO send list"),
        else => std.debug.warn("TODO implement mode {}\n", mode),
    }
}
