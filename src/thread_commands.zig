const std = @import("std");
const daemon = @import("daemon.zig");

const DaemonState = daemon.DaemonState;
const ServiceDecl = daemon.ServiceDecl;
const Service = daemon.Service;
const ServiceStateType = daemon.ServiceStateType;
const Client = @import("client.zig").Client;

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
        .prefix = "stdout",
        .in_fd = stdout,
        .client = ctx.client,
    }, specificWatchService);

    _ = try std.Thread.spawn(SpecificWatchServiceContext{
        .state = state,
        .service = service,
        .prefix = "stderr",
        .in_fd = stderr,
        .client = ctx.client,
    }, specificWatchService);
}

pub const SpecificWatchServiceContext = struct {
    state: *DaemonState,
    prefix: []const u8,
    service: *Service,
    client: *Client,
    in_fd: std.os.fd_t,
};

fn specificWatchService(ctx: SpecificWatchServiceContext) !void {
    var buf: [128]u8 = undefined;
    const fd_name = try std.fmt.bufPrint(&buf, "{}_{}", .{ ctx.service, ctx.prefix });
    const new_fd = try std.os.memfd_create(fd_name, 0);

    // TODO: handle resource errors here
    try std.os.dup2(ctx.in_fd, new_fd);

    var duped_stream = std.fs.File{ .handle = new_fd };
    defer duped_stream.close();

    // TODO: handle when the process closes and
    // we likely die in this loop

    while (true) {
        var buf: [512]u8 = undefined;
        const bytecount = try duped_stream.read(&buf);
        const stream_data = buf[0..bytecount];
        try ctx.client.print("data;{};{};{}!", .{ ctx.service.name, ctx.prefix, stream_data });
    }
}
