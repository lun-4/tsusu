const std = @import("std");

const daemon = @import("daemon.zig");

const fs = std.fs;
const os = std.os;
const mem = std.mem;

const Logger = @import("logger.zig").Logger;
const helpers = @import("helpers.zig");
const ProcessStats = @import("process_stats.zig").ProcessStats;

const util = @import("util.zig");
const prettyMemoryUsage = util.prettyMemoryUsage;

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

        const sock_path = try helpers.getPathFor(self.allocator, .Sock);

        std.debug.warn("connecting to socket ({})...\n", .{sock_path});
        return std.net.connectUnixSocket(sock_path) catch |err| {
            std.debug.warn("failed (error: {}), starting and retrying (try {})...", .{ err, self.tries });
            try self.spawnDaemon();

            // assuming spawning doesn't take more than a second
            std.time.sleep(1 * std.time.ns_per_s);
            return try self.checkDaemon();
        };
    }

    fn spawnDaemon(self: @This()) !void {
        std.debug.warn("Spawning tsusu daemon...\n", .{});
        const data_dir = try helpers.fetchDataDir(self.allocator);
        std.fs.cwd().makePath(data_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var pid = try std.os.fork();

        if (pid < 0) {
            return error.ForkFail;
        }

        if (pid > 0) {
            return;
        }

        _ = umask(0);

        const daemon_pid = os.linux.getpid();
        const pidpath = try helpers.getPathFor(self.allocator, .Pid);
        const logpath = try helpers.getPathFor(self.allocator, .Log);

        var pidfile = try std.fs.cwd().createFile(pidpath, .{ .truncate = false });
        try pidfile.seekFromEnd(0);

        var stream = pidfile.outStream();
        try stream.print("{}", .{daemon_pid});
        pidfile.close();

        var logfile = try std.fs.cwd().createFile(logpath, .{
            .truncate = false,
        });
        defer logfile.close();
        var logstream = logfile.outStream();
        var logger = Logger(std.fs.File.OutStream).init(logstream, "[d]");

        defer {
            std.os.unlink(pidpath) catch |err| {}; // do nothing on errors
        }

        _ = try setsid();

        try std.os.chdir("/");
        std.os.close(std.os.STDIN_FILENO);
        std.os.close(std.os.STDOUT_FILENO);
        std.os.close(std.os.STDERR_FILENO);
        daemon.main(&logger) catch |err| {
            logger.info("had error: {}", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| {
                logger.printTrace(trace.*);
            }
        };
    }
};

// TODO upstream mode_t to linux bits x86_64
const mode_t = u32;

fn umask(mode: mode_t) mode_t {
    const rc = os.system.syscall1(os.system.SYS.umask, @bitCast(usize, @as(isize, mode)));
    return @intCast(mode_t, rc);
}

fn setsid() !std.os.pid_t {
    const rc = os.system.syscall0(os.system.SYS.setsid);
    switch (std.os.errno(rc)) {
        0 => return @intCast(std.os.pid_t, rc),
        std.os.EPERM => return error.PermissionFail,
        else => |err| return std.os.unexpectedErrno(err),
    }
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
    if (std.mem.eql(u8, mode_arg, "destroy") or std.mem.eql(u8, mode_arg, "delete")) return .Destroy;
    if (std.mem.eql(u8, mode_arg, "start")) return .Start;
    if (std.mem.eql(u8, mode_arg, "stop")) return .Stop;
    if (std.mem.eql(u8, mode_arg, "help")) return .Help;
    if (std.mem.eql(u8, mode_arg, "list")) return .List;
    return error.UnknownMode;
}

pub fn printServices(msg: []const u8) !void {
    std.debug.warn("name | state\t\tpid\tcpu\tmemory\n", .{});
    var it = std.mem.split(msg, ";");
    while (it.next()) |service_line| {
        if (service_line.len == 0) break;

        var serv_it = std.mem.split(service_line, ",");
        const name = serv_it.next().?;
        const state_str = serv_it.next().?;

        const state = try std.fmt.parseInt(u8, state_str, 10);

        std.debug.warn("{} | ", .{name});

        switch (state) {
            0 => std.debug.warn("not running\t\t0\t0%\t0kb", .{}),
            1 => {
                const pid = try std.fmt.parseInt(std.os.pid_t, serv_it.next().?, 10);

                // we can calculate cpu and ram usage since the service
                // is currently running
                var proc_stats = ProcessStats.init();
                const stats = try proc_stats.fetchAllStats(pid);

                var buffer: [128]u8 = undefined;
                const pretty_memory_usage = try prettyMemoryUsage(&buffer, stats.memory_usage);
                std.debug.warn("running\t\t{}\t{d:.1}%\t{}", .{ pid, stats.cpu_usage, pretty_memory_usage });
            },
            2 => {
                const exit_code = try std.fmt.parseInt(u32, serv_it.next().?, 10);
                std.debug.warn("exited (code {})\t\t0%\t0kb", .{exit_code});
            },
            3 => {
                const exit_code = try std.fmt.parseInt(u32, serv_it.next().?, 10);
                std.debug.warn("restarting (code {})\t\t0%\t0kb", .{exit_code});
            },
            else => unreachable,
        }

        std.debug.warn("\n", .{});
    }
}

fn stopCommand(ctx: Context, in_stream: var, out_stream: var) !void {
    const name = try (ctx.args_it.next(allocator) orelse @panic("expected name"));
    std.debug.warn("sending stop '{}'\n", .{name});
    try out_stream.print("stop;{}!", .{name});

    std.time.sleep(1 * std.os.ns_per_s);

    const msg = try in_stream.readUntilDelimiterAlloc(ctx.allocator, '!', 1024);
    defer ctx.allocator.free(msg);
    try printServices(msg);
}

pub fn main() anyerror!void {
    // every time we start, we check if we have a daemon running.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var args_it = std.process.args();
    _ = args_it.skip();

    const mode_arg = try (args_it.next(allocator) orelse @panic("expected mode"));
    const mode = try getMode(mode_arg);

    // switch for things that don't depend on an existing daemon

    switch (mode) {
        .Destroy => {
            // TODO use sock first (send STOP command), THEN, if it fails, TERM
            const pidpath = try helpers.getPathFor(allocator, .Pid);
            //const sockpath = try helpers.getPathFor(allocator, .Sock);

            var pidfile = std.fs.cwd().openFile(pidpath, .{}) catch |err| {
                std.debug.warn("Failed to open PID file ({}). is the daemon running?\n", .{err});
                return;
            };
            var stream = pidfile.inStream();

            const pid_str = try stream.readAllAlloc(allocator, 20);
            defer allocator.free(pid_str);

            const pid_int = std.fmt.parseInt(os.pid_t, pid_str, 10) catch |err| {
                std.debug.warn("Failed to parse pid '{}': {}\n", .{ pid_str, err });
                return;
            };

            try std.os.kill(pid_int, std.os.SIGINT);

            std.debug.warn("sent SIGINT to pid {}\n", .{pid_int});
            return;
        },
        else => {},
    }

    var ctx = Context.init(allocator, args_it);
    const sock = try ctx.checkDaemon();
    defer sock.close();

    var in_stream = sock.inStream();
    var out_stream = sock.outStream();

    std.debug.warn("[c] sock fd to server: {}\n", .{sock.handle});

    const helo_msg = try in_stream.readUntilDelimiterAlloc(ctx.allocator, '!', 6);
    if (!std.mem.eql(u8, helo_msg, "helo")) {
        std.debug.warn("invalid helo, expected helo, got {}\n", .{helo_msg});
        return error.InvalidHello;
    }

    std.debug.warn("[c]first msg (should be helo): {} '{}'\n", .{ helo_msg.len, helo_msg });

    var buf = try ctx.allocator.alloc(u8, 1024);
    switch (mode) {
        .Noop => {},

        .List => {
            _ = try sock.write("list!");

            const msg = try in_stream.readUntilDelimiterAlloc(ctx.allocator, '!', 1024);
            defer ctx.allocator.free(msg);

            if (msg.len == 0) {
                std.debug.warn("<no services>\n", .{});
                return;
            }

            try printServices(msg);
        },

        .Start => {
            try out_stream.print("start;{};{}!", .{
                try (ctx.args_it.next(allocator) orelse @panic("expected name")),
                try (ctx.args_it.next(allocator) orelse @panic("expected path")),
            });

            const msg = try in_stream.readUntilDelimiterAlloc(ctx.allocator, '!', 1024);
            defer ctx.allocator.free(msg);
            try printServices(msg);
        },

        .Stop => try stopCommand(ctx, in_stream, out_stream),

        else => std.debug.warn("TODO implement mode {}\n", .{mode}),
    }
}
