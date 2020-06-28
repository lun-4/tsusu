const std = @import("std");
const daemon = @import("daemon.zig");

const ServiceLogger = @import("service_logger.zig").ServiceLogger;

const DaemonState = daemon.DaemonState;
const ServiceDecl = daemon.ServiceDecl;
const Service = daemon.Service;
const ServiceStateType = daemon.ServiceStateType;
const RcClient = daemon.RcClient;

pub const KillServiceContext = struct {
    state: *DaemonState,
    service: *const Service,
    client: *RcClient,
};

pub const KillError = error{ PermissionDenied, UnknownPID } || std.os.UnexpectedError;

// TODO maybe pr this back to zig
pub fn kill(pid: std.os.pid_t, sig: u8) KillError!void {
    switch (std.os.errno(std.os.system.kill(pid, sig))) {
        0 => return,
        std.os.EINVAL => unreachable, // invalid signal
        std.os.EPERM => return error.PermissionDenied,
        std.os.ESRCH => return error.UnknownPID,
        else => |err| return std.os.unexpectedErrno(err),
    }
}

pub fn killService(ctx: KillServiceContext) !void {
    defer ctx.client.decRef();

    var state = ctx.state;
    var allocator = ctx.state.allocator;
    const service = ctx.service;

    const pid = service.state.Running.pid;
    const logger_thread = service.state.Running.logger_thread;

    // before sending our signals to the process, we need to kill the
    // logger thread. it will panic if it tries to read from
    // stdout/stderr when they're killed.
    ServiceLogger.stopLogger(logger_thread) catch |err| {
        try ctx.client.ptr.?.print("err failed to stop logger thread: {}\n", .{err});
        return;
    };

    // First, we make the daemon send a SIGTERM to the child process.
    // Then we wait 1 second, and try to send a SIGKILL. If the process is
    // already dead, the UnknownPID error will be silently ignored.

    kill(pid, std.os.SIGTERM) catch |err| {
        if (err == error.UnknownPID) {
            try ctx.client.ptr.?.print("err pid not found for SIGTERM!", .{});
            return;
        }

        return err;
    };

    std.time.sleep(1 * std.time.ns_per_s);

    // UnknownPID errors here must be silenced.
    kill(pid, std.os.SIGKILL) catch |err| {
        if (err != error.UnknownPID) {
            return err;
        }
    };

    // Wait 250 milliseconds to give the system time to catch up on that
    // SIGKILL and we have updated state.
    std.time.sleep(250 * std.time.ns_per_ms);

    ctx.state.logger.info("sent wanted signals to pid {}", .{pid});
    try state.writeServices(ctx.client.ptr.?.stream());
}

pub const WatchServiceContext = struct {
    state: *DaemonState,
    service: *Service,
    client: *RcClient,
};

/// Caller owns the returned memory.
fn deserializeString(allocator: *std.mem.Allocator, deserializer: var) ![]const u8 {
    const length = try deserializer.deserialize(u16);

    var msg = try allocator.alloc(u8, length);

    var i: usize = 0;
    while (i < length) : (i += 1) {
        msg[i] = try deserializer.deserialize(u8);
    }

    return msg;
}

pub fn watchService(ctx: WatchServiceContext) !void {
    defer ctx.client.decRef();

    var state = ctx.state;
    var service = ctx.service;

    const pipes = try std.os.pipe();
    const read_fd = pipes[0];
    const write_fd = pipes[1];

    // give write_fd to service logger thread
    try service.addLoggerClient(write_fd);

    defer {
        service.removeLoggerClient(write_fd);

        // this thread owns the lifetime of both fds, so it must
        // close both (after removing the references to them in the service)
        std.os.close(read_fd);
        std.os.close(write_fd);
    }

    // read from read_fd in a loop
    var read_file = std.fs.File{ .handle = read_fd };
    var deserializer = daemon.MsgDeserializer.init(read_file.reader());
    while (true) {
        const opcode = try deserializer.deserialize(u8);

        if (opcode == 1) {
            const err_msg = try deserializeString(ctx.state.allocator, &deserializer);
            defer ctx.state.allocator.free(err_msg);

            std.debug.warn("Failed to link client to daemon: '{}'", .{err_msg});
            ctx.client.ptr.?.print("err {}!", .{err_msg}) catch |err| {
                if (err == error.Closed) {
                    // if client is closed, don't care
                    return;
                } else return err;
            };
        }

        if (opcode == 2 or opcode == 3) {
            const data_msg = try deserializeString(ctx.state.allocator, &deserializer);
            defer ctx.state.allocator.free(data_msg);

            const std_name = if (opcode == 2) "stdout" else "stderr";
            ctx.client.ptr.?.print("data;{};{};{}!", .{ ctx.service.name, std_name, data_msg }) catch |err| {
                if (err == error.Closed) {
                    // if client is closed, don't care
                    return;
                } else return err;
            };
        }
    }
}
