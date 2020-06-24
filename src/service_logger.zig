const std = @import("std");

const daemon = @import("daemon.zig");

pub const ServiceLogger = struct {
    pub const Context = struct {
        state: *DaemonState,
        service: *Service,

        stream_fd: std.os.fd_t,
        message_fd: std.os.fd_t,
    };

    pub fn handleReadableStream(ctx: Context) !void {
        // poll() is level-triggered, that means we can just read 512 bytes
        // then hand off to the next poll() call, which will still signal
        // the socket as available.
        var buf: [512]u8 = undefined;
        const bytes = try std.os.read(ctx.stream_fd, &buf);
        const msg = buf[0..bytes];

        // write to logfile
    }

    pub fn handleSignalMessage(ctx: Context) !void {
        var file = std.fs.File{ .handle = ctx.message_fd };
        var stream = file.inStream();
        var deserializer = daemon.MsgDeserializer.init(stream);

        const opcode = try deserializer.deserialize(u8);
        if (opcode == 0) return error.ShouldStop;
    }

    pub fn handler(ctx: Context) !void {
        var sockets = [_]std.os.pollfd{
            .{ .fd = ctx.stream_fd, .events = std.os.POLLIN, .revents = 0 },
            .{ .fd = ctx.message_fd, .events = std.os.POLLIN, .revents = 0 },
        };

        while (true) {
            const available = try os.poll(&sockets, -1);
            if (available == 0) {
                ctx.state.logger.info("timed out, retrying", .{});
                continue;
            }

            for (sockets.items) |pollfd, idx| {
                if (pollfd.revents == 0) continue;
                if (pollfd.fd == ctx.stream_fd) {
                    @This().handleReadableStream(ctx);
                } else if (pollfd.fd == ctx.message_fd) {
                    @This().handleSignalMessage(ctx) catch |err| {
                        if (err == error.ShouldStop) return else return err;
                    };
                }
            }
        }
    }
};
