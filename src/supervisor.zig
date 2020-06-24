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
            state.logger.info("Failed to send started message to daemon: {}", .{err});
        };

        // XXX: spawn threads for logging of stderr and stdout
        //_ = std.Thread.spawn(ServiceLogger.Context{}, ServiceLogger.handler) catch |err| {
        //    state.logger.info("Failed to start stdout thread: {}", .{err});
        //};

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
