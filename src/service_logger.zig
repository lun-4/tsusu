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

    pub fn handleProcessStream(ctx: Context, fd: std.os.fd_t, file: std.fs.File) !void {
        // poll() is level-triggered, that means we can just read 512 bytes
        // then hand off to the next poll() call, which will still signal
        // the socket as available.
        var buf: [512]u8 = undefined;
        const bytes = try std.os.read(fd, &buf);
        const msg = buf[0..bytes];

        // formatting of the logfile is done by the app, and not us
        _ = try file.write(msg);
    }

    pub fn handleSignalMessage(ctx: Context) !void {
        var file = std.fs.File{ .handle = ctx.message_fd };
        var stream = file.inStream();
        var deserializer = daemon.MsgDeserializer.init(stream);

        const opcode = try deserializer.deserialize(u8);
        if (opcode == 1) {
            ctx.state.logger.info("service logger for {} got stop signal", .{ctx.service.name});
            return error.ShouldStop;
        }
    }

    fn openLogFile(logfile_path: []const u8) !std.fs.File {
        var logfile = try std.fs.cwd().createFile(
            logfile_path,
            .{
                .read = false,
                .truncate = false,
            },
        );

        try logfile.seekFromEnd(0);

        return logfile;
    }

    pub fn handler(ctx: Context) !void {
        var sockets = [_]std.os.pollfd{
            .{ .fd = ctx.stdout, .events = std.os.POLLIN, .revents = 0 },
            .{ .fd = ctx.stderr, .events = std.os.POLLIN, .revents = 0 },
            .{ .fd = ctx.message_fd, .events = std.os.POLLIN, .revents = 0 },
        };

        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var allocator = &fba.allocator;

        // TODO: better folder..? maybe we cant use getAppDataDir
        const data_dir = try std.fs.getAppDataDir(allocator, "tsusu");
        std.fs.cwd().makeDir(data_dir) catch |err| {
            if (err != std.os.MakeDirError.PathAlreadyExists) return err;
        };

        const log_folder = try std.fmt.allocPrint(allocator, "{}/logs", .{data_dir});
        std.fs.cwd().makeDir(log_folder) catch |err| {
            if (err != std.os.MakeDirError.PathAlreadyExists) return err;
        };

        const stdout_logfile_path = try std.fmt.allocPrint(
            allocator,
            "{}/{}-out.log",
            .{ log_folder, ctx.service.name },
        );
        const stderr_logfile_path = try std.fmt.allocPrint(
            allocator,
            "{}/{}-err.log",
            .{ log_folder, ctx.service.name },
        );

        // open logfiles for stdout and stder
        var stdout_logfile = try @This().openLogFile(stdout_logfile_path);
        defer stdout_logfile.close();

        var stderr_logfile = try @This().openLogFile(stderr_logfile_path);
        defer stderr_logfile.close();

        ctx.state.logger.info(
            "Opened stdout/stderr log files for {}, {}, {}",
            .{ ctx.service.name, stdout_logfile_path, stderr_logfile_path },
        );

        while (true) {
            const available = try std.os.poll(&sockets, -1);
            if (available == 0) {
                ctx.state.logger.info("timed out, retrying", .{});
                continue;
            }

            for (sockets) |pollfd, idx| {
                if (pollfd.revents == 0) continue;
                if (pollfd.fd == ctx.stdout) {
                    try @This().handleProcessStream(ctx, pollfd.fd, stdout_logfile);
                } else if (pollfd.fd == ctx.stderr) {
                    try @This().handleProcessStream(ctx, pollfd.fd, stderr_logfile);
                } else if (pollfd.fd == ctx.message_fd) {
                    @This().handleSignalMessage(ctx) catch |err| {
                        if (err == error.ShouldStop) return else return err;
                    };
                }
            }
        }
    }
};
