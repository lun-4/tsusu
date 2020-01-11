const std = @import("std");

const daemon = @import("daemon.zig");

const fs = std.fs;
const os = std.os;
const mem = std.mem;

const Logger = @import("logger.zig").Logger;

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

// TODO upstream mode_t to linux bits x86_64
const mode_t = u32;

fn umask(mode: mode_t) mode_t {
    const rc = os.system.syscall1(os.system.SYS_umask, @bitCast(usize, @as(isize, mode)));
    return @intCast(mode_t, rc);
}

fn setsid() !std.os.pid_t {
    const rc = os.system.syscall0(os.system.SYS_setsid);
    switch (std.os.errno(rc)) {
        0 => return @intCast(std.os.pid_t, rc),
        std.os.EPERM => return error.PermissionFail,
        else => |err| return std.os.unexpectedErrno(err),
    }
}

fn spawnDaemon() !void {
    var pid = try std.os.fork();

    if (pid < 0) {
        return error.ForkFail;
    }

    if (pid > 0) {
        return;
    }

    const val = umask(0);
    std.debug.warn("[d]new umask: {}\n", .{val});

    const daemon_pid = os.linux.getpid();
    const pidpath = "/home/luna/.local/share/tsusu.pid";
    const logpath = "/home/luna/.local/share/tsusu.log";

    var pidfile = try std.fs.cwd().createFile(pidpath, .{});
    var stream = &pidfile.outStream().stream;
    try stream.print("{}", .{daemon_pid});
    pidfile.close();

    var logfile = try std.fs.cwd().createFile(logpath, .{
        .truncate = false,
    });
    defer logfile.close();
    var logstream = &logfile.outStream().stream;
    var logger = Logger.init(logstream, "[d]");

    defer {
        std.os.unlink(pidpath) catch |err| {}; // do nothing on errors
    }

    const sid = try setsid();
    try std.os.chdir("/");
    std.os.close(std.os.STDIN_FILENO);
    std.os.close(std.os.STDOUT_FILENO);
    std.os.close(std.os.STDERR_FILENO);
    try daemon.main(logger);
}

pub const Mode = enum {
    Destroy,
    Start,
    Stop,
    Help,
    List,
    Noop,
};

fn getMode(mode_arg: []const u8) !Mode {
    if (std.mem.eql(u8, mode_arg, "noop")) return .Noop;
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
                std.debug.warn("Failed to open PID file. is the daemon running?\n", .{});
                return;
            };

            var buf: [100]u8 = undefined;
            const count = try pidfile.read(&buf);
            const pid_str = buf[0..count];

            var pid_int = std.fmt.parseInt(os.pid_t, pid_str, 10) catch |err| {
                std.debug.warn("Failed to parse pid '{}': {}\n", .{ pid_str, err });
                return;
            };

            // TODO pr back to zig about ESRCH being unknown pid,
            // and not a race condition
            try std.os.kill(pid_int, std.os.SIGINT);

            // TODO make daemon do unlinking upon sigint
            std.os.unlink(pidpath) catch |err| {};
            const sockpath = "/home/luna/.local/share/tsusu.sock";
            std.os.unlink(sockpath) catch |err| {};

            std.debug.warn("sent SIGINT to pid {}\n", .{pid_int});
            return;
        },
        else => {},
    }

    var ctx = Context.init(allocator, args_it);
    const sock = try ctx.checkDaemon();
    defer sock.close();

    var in_stream = &sock.inStream().stream;
    var out_stream = &sock.outStream().stream;

    std.debug.warn("[c]sock fd from client connected: {}\n", .{sock.handle});
    const helo_msg = try in_stream.readUntilDelimiterAlloc(ctx.allocator, '!', 10);

    std.debug.warn("[c]first msg (should be helo): {} '{}'\n", .{ helo_msg.len, helo_msg });

    var buf = try ctx.allocator.alloc(u8, 1024);
    switch (mode) {
        .Noop => {},
        .List => blk: {
            std.debug.warn("[c]try send\n", .{});
            try sock.write("list!");
            std.debug.warn("[c]sent. waiting read\n", .{});
            const msg = try in_stream.readUntilDelimiterAlloc(ctx.allocator, '!', 1024);
            std.debug.warn("[c]list res: {} '{}'\n", .{ msg.len, msg });
        },

        .Start => blk: {
            std.debug.warn("[c]try send\n", .{});
            try out_stream.print("start;{};{}!", .{
                try (ctx.args_it.next(allocator) orelse @panic("expected name")),
                try (ctx.args_it.next(allocator) orelse @panic("expected path")),
            });
            std.debug.warn("[c]sent\n", .{});
            const msg = try in_stream.readUntilDelimiterAlloc(ctx.allocator, '!', 1024);
            std.debug.warn("[c]send res: {} '{}'\n", .{ msg.len, msg });
        },

        else => std.debug.warn("TODO implement mode {}\n", .{mode}),
    }
}
