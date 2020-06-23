const std = @import("std");
const daemon = @import("daemon.zig");

const DaemonState = daemon.DaemonState;
const ServiceDecl = daemon.ServiceDecl;
const Service = daemon.Service;
const ServiceStateType = daemon.ServiceStateType;

pub const SupervisorContext = struct {
    state: *DaemonState,
    service: *ServiceDecl,
};

pub fn superviseProcess(ctx: SupervisorContext) !void {
    var state = ctx.state;
    var allocator = state.allocator;

    state.logger.info("supervisor start\n", .{});

    var argv = std.ArrayList([]const u8).init(allocator);
    errdefer argv.deinit();

    var path_it = std.mem.split(ctx.service.cmdline, " ");
    while (path_it.next()) |component| {
        try argv.append(component);
    }

    state.logger.info("sup:{}: arg0 = {}\n", .{ ctx.service.name, argv.items[0] });

    var kv = state.services.get(ctx.service.name).?;

    while (!kv.value.stop_flag) {
        var proc = try std.ChildProcess.init(argv.items, allocator);

        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;

        try proc.spawn();

        state.pushMessage(.{
            .ServiceStarted = .{
                .name = ctx.service.name,
                .pid = proc.pid,
                .stdout = proc.stdout.?,
                .stderr = proc.stderr.?,
            },
        }) catch |err| {
            state.logger.info("Failed to send started message to daemon.", .{});
        };

        const term_result = try proc.wait();

        // XXX: check state flag for service, if stopped, must not restart,
        // return instead.

        switch (term_result) {
            .Exited, .Signal, .Stopped, .Unknown => |exit_code| {
                state.pushMessage(.{
                    .ServiceExited = .{ .name = ctx.service.name, .exit_code = exit_code },
                }) catch |err| {
                    state.logger.info("Failed to send exited message to daemon.", .{});
                };
            },
            else => unreachable,
        }

        std.time.sleep(5 * std.time.ns_per_s);
    }
}

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
