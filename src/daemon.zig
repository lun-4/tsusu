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

// please work
fn signalfd(fd: os.fd_t, mask: *const os.sigset_t, flags: i32) !os.fd_t {
    const rc = os.system.syscall4(
        os.system.SYS_signalfd4,
        @bitCast(usize, @as(isize, fd)),
        @ptrToInt(mask),
        @bitCast(usize, @as(usize, os.linux.NSIG / 8)),
        @intCast(usize, flags),
    );

    switch (std.os.errno(rc)) {
        0 => return @intCast(std.os.fd_t, rc),
        os.EBADF => return error.BadFile,
        os.EINVAL => return error.InvalidValue,
        // os.EBADF, os.EINVAL => unreachable,
        os.ENFILE, os.ENOMEM => return error.SystemResources,
        os.EMFILE => return error.ProcessResources,
        os.ENODEV => return error.InodeMountFail,
        else => |err| return std.os.unexpectedErrno(err),
    }
}

fn sigprocmask(flags: u32, noalias set: ?*const os.sigset_t, noalias oldset: ?*os.sigset_t) !void {
    const rc = os.linux.sigprocmask(flags, set, oldset);
    switch (std.os.errno(rc)) {
        0 => {},
        os.EFAULT, os.EINVAL => unreachable,
        else => |err| return std.os.unexpectedErrno(err),
    }
}

fn sigemptyset(set: *std.os.sigset_t) void {
    for (set) |*val| {
        val.* = 0;
    }
}

//unsigned s = sig-1;
//if (s >= _NSIG-1 || sig-32U < 3) {
// errno = EINVAL;
// return -1;
//}
//set->__bits[s/8/sizeof *set->__bits] |= 1UL<<(s&8*sizeof *set->__bits-1);
//return 0;

pub fn sigaddset(set: *os.sigset_t, sig: u32) void {
    const s = sig - 1;
    // shift in musl: s&8*sizeof *set->__bits-1
    const shift = @intCast(u5, s & (usize.bit_count - 1));
    const val = @intCast(u32, 1) << shift;
    (set.*)[@intCast(usize, s) / usize.bit_count] |= val;
}

pub fn main(logger: Logger) anyerror!void {
    logger.info("main!", .{});
    const allocator = std.heap.direct_allocator;

    var mask: std.os.sigset_t = undefined;

    sigemptyset(&mask);
    logger.info("sigemptyset", .{});
    for (mask) |val, idx| {
        logger.info("mask[{}] = {}", .{ idx, val });
    }

    logger.info("sigaddset term", .{});
    sigaddset(&mask, std.os.SIGTERM);
    for (mask) |val, idx| {
        logger.info("mask[{}] = {}", .{ idx, val });
    }

    sigaddset(&mask, std.os.SIGINT);
    logger.info("sigaddset int", .{});
    for (mask) |val, idx| {
        logger.info("mask[{}] = {}", .{ idx, val });
    }

    try sigprocmask(std.os.SIG_BLOCK, &mask, null);
    mask[20] = 16386;
    logger.info("sigprocmask", .{});
    for (mask) |val, idx| {
        logger.info("mask[{}] = {}", .{ idx, val });
    }

    const signal_fd = signalfd(-1, &mask, 0) catch |err| {
        logger.info("err!", .{});
        return err;
    };
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
            } else if (pollfd.fd == signal_fd) {
                logger.info("got a signal!!!!", .{});
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
