const std = @import("std");
const os = std.os;

const Logger = @import("logger.zig").Logger;
const helpers = @import("helpers.zig");
//pub const io_mode = .evented;

pub const Service = struct {
    path: []const u8,
    proc: ?*std.ChildProcess = null,
};

pub const ServiceMap = std.StringHashMap(Service);
pub const FileLogger = Logger(std.fs.File.OutStream);

pub const DaemonState = struct {
    allocator: *std.mem.Allocator,
    services: ServiceMap,
    logger: FileLogger,

    pub fn init(allocator: *std.mem.Allocator, logger: FileLogger) @This() {
        return .{
            .allocator = allocator,
            .services = ServiceMap.init(allocator),
            .logger = logger,
        };
    }

    pub fn deinit() void {
        self.services.deinit();
    }

    pub fn writeServices(self: @This(), stream: var) !void {
        var services_it = self.services.iterator();
        while (services_it.next()) |kv| {
            self.logger.info("serv: {} {}", .{ kv.key, kv.value.path });
            try stream.print("{},{};", .{ kv.key, kv.value.path });
        }
        _ = try stream.write("!");
    }
};

fn readManyFromClient(
    state: *DaemonState,
    pollfd: os.pollfd,
) !void {
    var logger = state.logger;
    var allocator = state.allocator;
    var sock = std.fs.File{ .handle = pollfd.fd };
    var in_stream = sock.inStream();
    var stream = sock.outStream();

    while (true) {
        logger.info("try read client fd {}", .{sock.handle});
        const message = in_stream.readUntilDelimiterAlloc(allocator, '!', 1024) catch |err| {
            // TODO replace by continue?? where loop be
            if (err == error.WouldBlock) break;
            return err;
        };
        logger.info("got msg from fd {}, {} '{}'", .{ sock.handle, message.len, message });

        if (message.len == 0) {
            return error.Closed;
        }

        if (std.mem.eql(u8, message, "list")) {
            try state.writeServices(stream);
        } else if (std.mem.startsWith(u8, message, "start")) {
            logger.info("got req to start", .{});
            var parts_it = std.mem.split(message, ";");
            _ = parts_it.next();

            const service_name = parts_it.next().?;
            const service_path = parts_it.next().?;
            logger.info("got service start: {} {}", .{ service_name, service_path });

            if (state.services.get(service_name) == null) {
                logger.info("starting service {} with cmdline {}", .{ service_name, service_path });

                var argv = std.ArrayList([]const u8).init(allocator);
                errdefer argv.deinit();

                var path_it = std.mem.split(service_path, " ");
                while (path_it.next()) |component| {
                    try argv.append(component);
                }

                var proc = try std.ChildProcess.init(argv.items, allocator);
                try proc.spawn();
                _ = try state.services.put(service_name, .{ .path = service_path, .proc = proc });
            }

            try state.writeServices(stream);
        }
    }
}

const PollFdList = std.ArrayList(os.pollfd);

fn sigemptyset(set: *std.os.sigset_t) void {
    for (set) |*val| {
        val.* = 0;
    }
}

pub fn main(logger: FileLogger) anyerror!void {
    logger.info("main!", .{});
    const allocator = std.heap.page_allocator;

    var mask: std.os.sigset_t = undefined;

    sigemptyset(&mask);
    logger.info("sigemptyset", .{});
    for (mask) |val, idx| {
        logger.info("mask[{}] = {}", .{ idx, val });
    }

    logger.info("sigaddset term", .{});
    os.linux.sigaddset(&mask, std.os.SIGTERM);
    for (mask) |val, idx| {
        logger.info("mask[{}] = {}", .{ idx, val });
    }

    os.linux.sigaddset(&mask, std.os.SIGINT);
    logger.info("sigaddset int", .{});
    for (mask) |val, idx| {
        logger.info("mask[{}] = {}", .{ idx, val });
    }

    _ = os.linux.sigprocmask(std.os.SIG_BLOCK, &mask, null);
    // mask[20] = 16386;
    logger.info("sigprocmask", .{});
    for (mask) |val, idx| {
        logger.info("mask[{}] = {}", .{ idx, val });
    }

    const signal_fd = os.signalfd(-1, &mask, 0) catch |err| {
        logger.info("err!", .{});
        return err;
    };
    defer os.close(signal_fd);
    logger.info("signalfd: {}", .{signal_fd});

    var server = std.net.StreamServer.init(std.net.StreamServer.Options{});
    defer server.deinit();

    var addr = try std.net.Address.initUnix(try helpers.getPathFor(allocator, .Sock));

    try server.listen(addr);

    logger.info("bind+listen done on fd={}", .{server.sockfd});

    var sockets = PollFdList.init(allocator);
    defer sockets.deinit();

    try sockets.append(os.pollfd{
        .fd = server.sockfd.?,
        .events = os.POLLIN,
        .revents = 0,
    });

    try sockets.append(os.pollfd{
        .fd = signal_fd,
        .events = os.POLLIN,
        .revents = 0,
    });

    var state = DaemonState.init(allocator, logger);

    while (true) {
        var pollfds = sockets.items;
        logger.info("polling {} sockets...", .{pollfds.len});

        const available = try os.poll(pollfds, -1);
        if (available == 0) {
            logger.info("timed out, retrying", .{});
            continue;
        }

        // TODO remove our WouldBlock checks when we have an event loop here

        logger.info("got {} available fds", .{available});

        for (pollfds) |pollfd, idx| {
            logger.info("check fd {} {}=={}?", .{ pollfd.fd, pollfd.revents, os.POLLIN });
            if (pollfd.revents == 0) continue;
            //if (pollfd.revents != os.POLLIN) return error.UnexpectedSocketRevents;

            if (pollfd.fd == server.sockfd.?) {
                while (true) {
                    logger.info("try accept?", .{});
                    var conn = server.accept() catch |e| {
                        logger.info("[d??]{}", .{e});
                        unreachable;
                    };

                    var sock = conn.file;
                    try sockets.append(os.pollfd{
                        .fd = sock.handle,
                        .events = os.POLLIN,
                        .revents = 0,
                    });

                    // as soon as we get a new client, send helo
                    logger.info("server: got client {}", .{sock.handle});
                    _ = try sock.write("helo!");

                    // TODO many clients per accept someday
                    break;
                }
            } else if (pollfd.fd == signal_fd) {
                logger.info("got a signal!!!!", .{});

                var buf: [@sizeOf(os.linux.signalfd_siginfo)]u8 align(8) = undefined;
                _ = os.read(signal_fd, &buf) catch |err| {
                    logger.info("failed to read from signal fd: {}", .{err});
                    return;
                };

                var siginfo = @ptrCast(*os.linux.signalfd_siginfo, @alignCast(
                    @alignOf(*os.linux.signalfd_siginfo),
                    &buf,
                ));

                var sig = siginfo.ssi_signo;
                if (sig != os.SIGINT and sig != os.SIGTERM) {
                    logger.info("got signal {}, not INT ({}) or TERM ({}), ignoring", .{
                        sig,
                        os.SIGINT,
                        os.SIGTERM,
                    });
                    continue;
                }

                logger.info("got SIGINT or SIGTERM, stopping!", .{});

                const pidpath = try helpers.getPathFor(state.allocator, .Pid);
                const sockpath = try helpers.getPathFor(state.allocator, .Sock);

                std.os.unlink(pidpath) catch |err| {
                    logger.info("failed to delete pid file: {}", .{err});
                };
                std.os.unlink(sockpath) catch |err| {
                    logger.info("failed to delete sock file: {}", .{err});
                };

                return;
            } else {
                logger.info("got fd for read! fd={}", .{pollfd.fd});

                readManyFromClient(&state, pollfd) catch |err| {
                    std.os.close(pollfd.fd);
                    logger.info("closed fd {} from {}", .{ pollfd.fd, err });
                    _ = sockets.orderedRemove(idx);
                };
            }

            logger.info("tick tick?", .{});
        }
    }
}
