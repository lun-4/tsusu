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
        //state.pushMessage(.{
        //    .ServiceStarted = .{ .name = ctx.service.name },
        //});

        const term_result = try proc.spawnAndWait();

        //state.pushMessage(.{
        //    .ServiceExited = .{ .name = ctx.service.name, .term = term_result },
        //});

        std.time.sleep(5 * std.time.s_per_ns);
    }
}
