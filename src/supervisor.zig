const std = @import("std");
const daemon = @import("daemon.zig");

const DaemonState = daemon.DaemonState;
const ServiceDecl = daemon.ServiceDecl;
const Service = daemon.Service;
const ServiceStateType = daemon.ServiceStateType;

const ServiceLogger = @import("service_logger.zig").ServiceLogger;

pub const SupervisorContext = struct {
    state: *DaemonState,
    service: *Service,
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

        // spawn thread for logging of stderr and stdout
        var logger_pipe = try std.os.pipe();
        defer std.os.close(logger_pipe[0]);
        defer std.os.close(logger_pipe[1]);

        var file = std.fs.File{ .handle = logger_pipe[1] };
        var stream = file.outStream();
        var serializer = daemon.MsgSerializer.init(stream);
        _ = std.Thread.spawn(ServiceLogger.Context{
            .state = ctx.state,
            .service = ctx.service,
            .stdout = proc.stdout.?.handle,
            .stderr = proc.stderr.?.handle,
            .message_fd = logger_pipe[0],
        }, ServiceLogger.handler) catch |err| {
            state.logger.info("Failed to start logging thread: {}", .{err});
        };

        state.pushMessage(.{
            .ServiceStarted = .{
                .name = ctx.service.name,
                .pid = proc.pid,
                .stdout = proc.stdout.?,
                .stderr = proc.stderr.?,
                .logger_thread = logger_pipe[1],
            },
        }) catch |err| {
            state.logger.info("Failed to send started message to daemon: {}", .{err});
        };

        const term_result = try proc.wait();

        // we don't care about the status of the process if we're here,
        // since it exited already, we must destroy the threads
        // we made for stdout/err
        ServiceLogger.stopLogger(logger_pipe[1]) catch |err| {
            state.logger.info("Failed to signal logger thread to stop: {}", .{err});
        };

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
