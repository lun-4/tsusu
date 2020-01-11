const std = @import("std");
const os = std.os;

const Logger = @import("logger.zig").Logger;
//pub const io_mode = .evented;

pub const Service = struct {
    path: []const u8,
    proc: ?*std.ChildProcess = null,
};

pub const ServiceMap = std.StringHashMap(Service);

pub const DaemonState = struct {
    allocator: *std.mem.Allocator,
    services: ServiceMap,
    logger: Logger,

    pub fn init(allocator: *std.mem.Allocator, logger: Logger) @This() {
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
        try stream.write("!");
    }
};

fn readManyFromClient(
    state: *DaemonState,
    pollfd: os.pollfd,
) !void {
    var logger = state.logger;
    var allocator = state.allocator;
    var sock = std.fs.File.openHandle(pollfd.fd);
    var in_stream = &sock.inStream().stream;
    var stream = &sock.outStream().stream;

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
            var parts_it = std.mem.separate(message, ";");
            _ = parts_it.next();

            const service_name = parts_it.next().?;
            const service_path = parts_it.next().?;
            logger.info("got service start: {} {}", .{ service_name, service_path });

            if (state.services.get(service_name) == null) {
                logger.info("starting service {} with cmdline {}", .{ service_name, service_path });

                var argv = std.ArrayList([]const u8).init(allocator);
                errdefer argv.deinit();

                var path_it = std.mem.separate(service_path, " ");
                while (path_it.next()) |component| {
                    try argv.append(component);
                }

                var proc = try std.ChildProcess.init(argv.toSlice(), allocator);
                try proc.spawn();
                _ = try state.services.put(service_name, .{ .path = service_path, .proc = proc });
            }

            try state.writeServices(stream);
        }
    }
}

const PollFdList = std.ArrayList(os.pollfd);

// int signalfd(int fd, const sigset_t *mask, int flags);

fn signalfd(fd: i32, mask: *const std.os.sigset_t, flags: i32) usize {
    const rc = os.system.syscall3(
        os.system.SYS_signalfd,
        @bitCast(usize, isize(fd)),
        @ptrToInt(mask),
        @intCast(usize, flags),
    );
    return rc;
}

pub fn main(logger: Logger) anyerror!void {
    logger.info("main!", .{});
    const allocator = std.heap.direct_allocator;

    // TODO this doesnt work
    //var mask: std.os.sigset_t = undefined;
    //std.mem.secureZero(usize, &mask);
    //std.os.linux.sigaddset(&mask, std.os.SIGINT);
    //_ = std.os.linux.sigprocmask(std.os.SIG_BLOCK, &mask, null);
    //const signal_fd = @intCast(i32, signalfd(-1, &mask, 0));

    // TODO use std.c.signalfd?

    var server = std.net.StreamServer.init(std.net.StreamServer.Options{});
    defer server.deinit();

    var addr = try std.net.Address.initUnix("/home/luna/.local/share/tsusu.sock");

    try server.listen(addr);

    logger.info("bind+listen done on fd={}", .{server.sockfd});

    var sockets = PollFdList.init(allocator);
    defer sockets.deinit();

    try sockets.append(os.pollfd{
        .fd = server.sockfd.?,
        .events = os.POLLIN,
        .revents = 0,
    });

    //try sockets.append(os.pollfd{
    //    .fd = signal_fd,
    //    .events = os.POLLIN,
    //    .revents = 0,
    //});

    var state = DaemonState.init(allocator, logger);

    while (true) {
        var pollfds = sockets.toSlice();
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
                    try sock.write("helo!");

                    // TODO many clients per accept someday
                    break;
                }
                logger.info("end thing", .{});

                //} else if (pollfd.fd == signal_fd) {
                //    logger.info("got sigint");
                //    return;
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
