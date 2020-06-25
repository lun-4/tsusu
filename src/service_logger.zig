const std = @import("std");

const daemon = @import("daemon.zig");
const util = @import("util.zig");

pub const ServiceLogger = struct {
    pub const Context = struct {
        state: *daemon.DaemonState,
        service: *daemon.ServiceDecl,

        stdout: std.os.fd_t,
        stderr: std.os.fd_t,

        message_fd: std.os.fd_t,
    };

    pub fn stopLogger(logger_fd: std.os.fd_t) !void {
        var file = std.fs.File{ .handle = logger_fd };
        var serializer = daemon.MsgSerializer.init(file.writer());
        try serializer.serialize(@as(u8, 1));
    }

    pub fn addOutputFd(logger_fd: std.os.fd_t, output_fd: std.fs.fd_t) !void {
        var file = std.fs.File{ .handle = logger_fd };
        var serializer = daemon.MsgSerializer.init(file.writer());
        try serializer.serialize(@as(u8, 1));
    }

    pub fn handleProcessStream(ctx: Context, fd: std.os.fd_t) !void {
        // poll() is level-triggered, that means we can just read 512 bytes
        // then hand off to the next poll() call, which will still signal
        // the socket as available.
        var buf: [512]u8 = undefined;
        const bytes = try std.os.read(fd, &buf);
        const msg = buf[0..bytes];

        std.debug.warn("got logline: {}\n", .{msg});

        // XXX: write to logfile
    }

    pub fn handleSignalMessage(ctx: Context) !void {
        var file = std.fs.File{ .handle = ctx.message_fd };
        var stream = file.inStream();
        var deserializer = daemon.MsgDeserializer.init(stream);

        const opcode = try deserializer.deserialize(u8);
        if (opcode == 1) return error.ShouldStop;
    }

    pub fn handler(ctx: Context) !void {
        var sockets = [_]std.os.pollfd{
            .{ .fd = ctx.stdout, .events = std.os.POLLIN, .revents = 0 },
            .{ .fd = ctx.stderr, .events = std.os.POLLIN, .revents = 0 },
            .{ .fd = ctx.message_fd, .events = std.os.POLLIN, .revents = 0 },
        };

        while (true) {
            const available = try std.os.poll(&sockets, -1);
            if (available == 0) {
                ctx.state.logger.info("timed out, retrying", .{});
                continue;
            }

            for (sockets) |pollfd, idx| {
                if (pollfd.revents == 0) continue;
                if (pollfd.fd == ctx.stdout or pollfd.fd == ctx.stderr) {
                    try @This().handleProcessStream(ctx, pollfd.fd);
                } else if (pollfd.fd == ctx.message_fd) {
                    @This().handleSignalMessage(ctx) catch |err| {
                        if (err == error.ShouldStop) return else return err;
                    };
                }
            }
        }
    }
};
