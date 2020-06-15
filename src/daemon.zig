const std = @import("std");
const os = std.os;

const Logger = @import("logger.zig").Logger;
const helpers = @import("helpers.zig");

const supervisors = @import("supervisor.zig");

const superviseProcess = supervisors.superviseProcess;
const SupervisorContext = supervisors.SupervisorContext;

pub const Service = struct {
    path: []const u8,
    supervisor: ?*std.Thread = null,
};

// 250 messages at any given time
const MAX_MAILBOX_SIZE = 250;

pub const ServiceMap = std.StringHashMap(Service);
pub const FileLogger = Logger(std.fs.File.OutStream);

pub const Message = struct {};
pub const Mailbox = std.ArrayList(Message);

pub const ServiceDecl = struct {
    name: []const u8,
    cmdline: []const u8,
};

pub const DaemonState = struct {
    allocator: *std.mem.Allocator,
    services: ServiceMap,
    logger: *FileLogger,

    mailbox: Mailbox,

    pub fn init(allocator: *std.mem.Allocator, logger: *FileLogger) @This() {
        return .{
            .allocator = allocator,
            .services = ServiceMap.init(allocator),
            .logger = logger,
            .mailbox = Mailbox.init(allocator),
        };
    }

    pub fn deinit() void {
        self.services.deinit();
    }

    pub fn pushMessage(self: *@This(), message: *Message) !void {
        if (self.mailbox.items.len > MAX_MAILBOX_SIZE) return error.FullMailbox;
        try self.mailbox.append(message);
    }

    pub fn writeServices(self: @This(), stream: var) !void {
        var services_it = self.services.iterator();
        while (services_it.next()) |kv| {
            self.logger.info("serv: {} {}", .{ kv.key, kv.value.path });
            try stream.print("{},{};", .{ kv.key, kv.value.path });
        }
        _ = try stream.write("!");
    }

    pub fn addSupervisor(self: *@This(), service: ServiceDecl, thread: *std.Thread) !void {
        _ = try self.services.put(
            service.name,
            .{ .path = service.cmdline, .supervisor = thread },
        );
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

    const message = try in_stream.readUntilDelimiterAlloc(allocator, '!', 1024);

    logger.info("got msg from fd {}, {} '{}'", .{ sock.handle, message.len, message });

    if (message.len == 0) {
        return error.Closed;
    }

    if (std.mem.eql(u8, message, "list")) {
        try state.writeServices(stream);
    } else if (std.mem.startsWith(u8, message, "start")) {
        var parts_it = std.mem.split(message, ";");
        _ = parts_it.next();

        // TODO: error handling on malformed messages
        const service_name = parts_it.next().?;
        const service_cmdline = parts_it.next().?;
        logger.info("got service start: {} {}", .{ service_name, service_cmdline });

        var service = try allocator.create(ServiceDecl);
        service.* =
            ServiceDecl{ .name = service_name, .cmdline = service_cmdline };

        if (state.services.get(service_name) != null) {
            _ = try stream.write("err exists!");
            return;
        }

        logger.info("starting service {} with cmdline {}", .{ service_name, service_cmdline });

        // the supervisor thread actually waits on the process in a loop
        // so that we can do things like exponential backoff, etc.
        const supervisor_thread = try std.Thread.spawn(
            SupervisorContext{ .state = state, .service = service },
            superviseProcess,
        );
        try state.addSupervisor(service.*, supervisor_thread);
        try state.writeServices(stream);
    }
}

const PollFdList = std.ArrayList(os.pollfd);

fn sigemptyset(set: *std.os.sigset_t) void {
    for (set) |*val| {
        val.* = 0;
    }
}

pub fn main(logger: *FileLogger) anyerror!void {
    logger.info("main!", .{});
    const allocator = std.heap.page_allocator;

    var mask: std.os.sigset_t = undefined;

    sigemptyset(&mask);
    os.linux.sigaddset(&mask, std.os.SIGTERM);
    os.linux.sigaddset(&mask, std.os.SIGINT);

    _ = os.linux.sigprocmask(std.os.SIG_BLOCK, &mask, null);
    // mask[20] = 16386;

    const signal_fd = try os.signalfd(-1, &mask, 0);
    defer os.close(signal_fd);
    logger.info("signalfd: {}", .{signal_fd});

    var server = std.net.StreamServer.init(std.net.StreamServer.Options{});
    defer server.deinit();

    var addr = try std.net.Address.initUnix(try helpers.getPathFor(allocator, .Sock));

    try server.listen(addr);

    logger.info("listen done on fd={}", .{server.sockfd});

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

        for (pollfds) |pollfd, idx| {
            if (pollfd.revents == 0) continue;
            //if (pollfd.revents != os.POLLIN) return error.UnexpectedSocketRevents;

            if (pollfd.fd == server.sockfd.?) {
                while (true) {
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
                    _ = try sock.write("helo!");

                    // TODO many clients per accept someday
                    break;
                }
            } else if (pollfd.fd == signal_fd) {
                var buf: [@sizeOf(os.linux.signalfd_siginfo)]u8 align(8) = undefined;
                _ = os.read(signal_fd, &buf) catch |err| {
                    logger.info("failed to read from signal fd: {}", .{err});
                    return;
                };

                var siginfo = @ptrCast(*os.linux.signalfd_siginfo, @alignCast(
                    @alignOf(*os.linux.signalfd_siginfo),
                    &buf,
                ));

                var sig = siginfo.signo;
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
