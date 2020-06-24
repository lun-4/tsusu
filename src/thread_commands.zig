const std = @import("std");
const daemon = @import("daemon.zig");

const DaemonState = daemon.DaemonState;
const ServiceDecl = daemon.ServiceDecl;
const Service = daemon.Service;
const ServiceStateType = daemon.ServiceStateType;
const Client = @import("client.zig").Client;

pub const KillServiceContext = struct {
    state: *DaemonState,
    service: *const Service,
    stream: daemon.OutStream,
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
    var state = ctx.state;
    var allocator = ctx.state.allocator;
    const service = ctx.service;
    var stream = ctx.stream;

    // try stream.print("ack!", .{});

    // std.debug.assert(@as(ServiceStateType, service.state) == .Running);
    const pid = service.state.Running.pid;

    // First, we make the daemon send a SIGTERM to the child process.
    // Then we wait 1 second, and try to send a SIGKILL. If the process is
    // already dead, the UnknownPID error will be silently ignored.

    kill(pid, std.os.SIGTERM) catch |err| {
        if (err == error.UnknownPID) {
            try stream.print("err pid not found for SIGTERM!", .{});
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

    try state.writeServices(stream);
}

pub const WatchServiceContext = struct {
    state: *DaemonState,
    service: *Service,
    client: *Client,
};

pub fn watchService(ctx: WatchServiceContext) !void {
    var state = ctx.state;
    var service = ctx.service;

    const stdout = service.state.Running.stdout;
    const stderr = service.state.Running.stderr;

    // spawn two threads that write to the stream for each
    // file descriptor

    _ = try std.Thread.spawn(SpecificWatchServiceContext{
        .state = state,
        .service = service,
        .typ = .Out,
        .in_fd = stdout,
        .client = ctx.client,
    }, specificWatchService);

    _ = try std.Thread.spawn(SpecificWatchServiceContext{
        .state = state,
        .service = service,
        .typ = .Err,
        .in_fd = stderr,
        .client = ctx.client,
    }, specificWatchService);
}

pub const SpecificWatchType = enum { Out, Err };

pub const SpecificWatchServiceContext = struct {
    state: *DaemonState,
    typ: SpecificWatchType,
    service: *Service,
    client: *Client,
    in_fd: std.os.fd_t,
};

fn specificWatchService(ctx: SpecificWatchServiceContext) !void {
    var buf: [128]u8 = undefined;
    const prefix = switch (ctx.typ) {
        .Out => "stdout",
        .Err => "stderr",
    };
    const fd_name = try std.fmt.bufPrint(&buf, "{}_{}", .{ ctx.service.name, prefix });
    const new_fd = try std.os.memfd_create(fd_name, 0);

    // TODO: handle resource errors here
    try std.os.dup2(ctx.in_fd, new_fd);

    var duped_stream = std.fs.File{ .handle = new_fd };
    defer duped_stream.close();

    // TODO: handle when the process closes and
    // we likely die in this loop

    while (true) {
        var line_buf: [512]u8 = undefined;
        const bytecount = try duped_stream.read(&line_buf);
        const stream_data = line_buf[0..bytecount];
        try ctx.client.print("data;{};{};{}!", .{ ctx.service.name, prefix, stream_data });
    }
}
