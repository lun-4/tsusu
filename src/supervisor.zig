const std = @import("std");
const daemon = @import("daemon.zig");

const DaemonState = daemon.DaemonState;
const ServiceDecl = daemon.ServiceDecl;

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

    while (true) {
        var proc = try std.ChildProcess.init(argv.items, allocator);

        try proc.spawn();

        state.pushMessage(.{
            .ServiceStarted = .{ .name = ctx.service.name, .pid = proc.pid },
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
