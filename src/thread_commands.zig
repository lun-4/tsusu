const std = @import("std");
const daemon = @import("daemon.zig");

const DaemonState = daemon.DaemonState;
const ServiceDecl = daemon.ServiceDecl;
const Service = daemon.Service;
const ServiceStateType = daemon.ServiceStateType;

pub const WatchServiceContext = struct {
    state: *DaemonState,
    service: *Service,
    stream: daemon.OutStream,
};

pub fn watchService(ctx: WatchServiceContext) !void {
    var state = ctx.state;
    var service = ctx.service;

    const stdout = service.state.Running.stdout;
    const stderr = service.state.Running.stderr;

    // spawn two threads that write to the stream for each
    // file descriptor

    try std.Thread.spawn(SpecificWatchServiceContext{
        .state = state,
        .in_file = stdout,
        .stream = stream,
    }, specificWatchService);

    try std.Thread.spawn(SpecificWatchServiceContext{
        .state = state,
        .in_file = stderr,
        .stream = stream,
    }, specificWatchService);
}

pub const SpecificWatchServiceContext = struct {
    state: *DaemonState,
    service: *Service,
    stream: daemon.OutStream,
};

fn specificWatchService(ctx: SpecificWatchServiceContext) !void {
    // XXX: construct the wanted memfd id via service data
    const new_fd = std.os.memfd_create("test", 0);

    // TODO: handle resource errors here
    try std.os.dup2(ctx.in_file.handle, new_fd);

    var duped_stream = std.fs.File{ .handle = new_fd };
    defer duped_stream.close();

    // TODO: handle when the process closes and
    // we likely die in this loop

    while (true) {
        var buf: [512]u8 = undefined;
        const bytecount = try duped_stream.read(&buf);
        const stream_data = buf[0..bytecount];
        _ = try ctx.stream.write(stream_data);
    }
}
