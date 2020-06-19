const std = @import("std");
const os = std.os;

const Logger = @import("logger.zig").Logger;
const helpers = @import("helpers.zig");

const supervisors = @import("supervisor.zig");

const superviseProcess = supervisors.superviseProcess;
const SupervisorContext = supervisors.SupervisorContext;

pub const ServiceState = union(enum) {
    NotRunning: void,
    Running: std.os.pid_t,
    Restarting: u32,
    Stopped: u32,
};

pub const Service = struct {
    path: []const u8,
    supervisor: ?*std.Thread = null,

    state: ServiceState = ServiceState{ .NotRunning = {} },
};

pub const ServiceMap = std.StringHashMap(*Service);
pub const FileLogger = Logger(std.fs.File.OutStream);

pub const MessageOP = enum(u8) {
    ServiceStarted,
    ServiceExited,
};

pub const Message = union(MessageOP) {
    ServiceStarted: struct { name: []const u8, pid: std.os.pid_t },
    ServiceExited: struct { name: []const u8, exit_code: u32 },
};

pub const ServiceDecl = struct {
    name: []const u8,
    cmdline: []const u8,
};

const BufferType = std.io.FixedBufferStream([]const u8);

const FileInStream = std.io.InStream(std.fs.File, std.os.ReadError, std.fs.File.read);
const FileOutStream = std.io.OutStream(std.fs.File, std.os.WriteError, std.fs.File.write);

pub const MsgSerializer = std.io.Serializer(
    .Little,
    .Byte,
    FileOutStream,
);

pub const MsgDeserializer = std.io.Deserializer(
    .Little,
    .Byte,
    FileInStream,
);

// Caller owns the returned memory.
fn deserializeSlice(
    allocator: *std.mem.Allocator,
    deserializer: var,
    comptime T: type,
    size: usize,
) ![]T {
    var value = try allocator.alloc(T, size);

    var i: usize = 0;
    while (i < size) : (i += 1) {
        value[i] = try deserializer.deserialize(T);
    }

    return value;
}

fn deserializeString(allocator: *std.mem.Allocator, deserializer: var) ![]u8 {
    const string_length = try deserializer.deserialize(u32);
    std.debug.assert(string_length > 0);

    var result = try deserializeSlice(allocator, deserializer, u8, string_length);
    std.debug.assert(result.len == string_length);
    return result;
}

fn serializeString(serializer: var, string: []const u8) !void {
    try serializer.serialize(@intCast(u32, string.len));
    for (string) |byte| {
        try serializer.serialize(byte);
    }
}

pub const DaemonState = struct {
    allocator: *std.mem.Allocator,
    services: ServiceMap,
    logger: *FileLogger,

    status_pipe: [2]std.os.fd_t,

    pub fn init(allocator: *std.mem.Allocator, logger: *FileLogger) !@This() {
        return DaemonState{
            .allocator = allocator,
            .services = ServiceMap.init(allocator),
            .logger = logger,
            .status_pipe = try std.os.pipe(),
        };
    }

    pub fn deinit() void {
        self.services.deinit();
    }

    pub fn pushMessage(self: *@This(), message: Message) !void {
        var file = std.fs.File{ .handle = self.status_pipe[1] };
        var stream = file.outStream();
        var serializer = MsgSerializer.init(stream);

        const opcode = @enumToInt(@as(MessageOP, message));
        try serializer.serialize(opcode);
        switch (message) {
            .ServiceStarted => |data| {
                try serializeString(&serializer, data.name);
                try serializer.serialize(data.pid);
            },
            .ServiceExited => |data| {
                try serializeString(&serializer, data.name);
                try serializer.serialize(data.exit_code);
            },
        }
    }

    pub fn writeServices(self: @This(), stream: var) !void {
        var services_it = self.services.iterator();
        while (services_it.next()) |kv| {
            self.logger.info("serv: {} {}", .{ kv.key, kv.value.path });

            var buf: [50]u8 = undefined;

            try stream.print("{},", .{kv.key});

            const state_string = switch (kv.value.state) {
                .NotRunning => try stream.print("0", .{}),
                .Running => |pid| try stream.print("1,{}", .{pid}),
                .Stopped => |code| try stream.print("2,{}", .{code}),
                .Restarting => |code| try stream.print("3,{}", .{code}),
            };

            try stream.print(";", .{});
        }
        _ = try stream.write("!");
    }

    pub fn addSupervisor(self: *@This(), service: ServiceDecl, thread: *std.Thread) !void {
        var service_ptr = try self.allocator.create(Service);
        service_ptr.* =
            .{ .path = service.cmdline, .supervisor = thread };
        _ = try self.services.put(
            service.name,
            service_ptr,
        );
    }

    fn readStatusMessage(self: *@This()) !void {
        var statusFile = std.fs.File{ .handle = self.status_pipe[0] };
        var stream = statusFile.inStream();
        var deserializer = MsgDeserializer.init(stream);

        const opcode = try deserializer.deserialize(u8);

        switch (@intToEnum(MessageOP, opcode)) {
            .ServiceStarted => {
                const service_name = try deserializeString(self.allocator, &deserializer);
                defer self.allocator.free(service_name);

                const pid = try deserializer.deserialize(std.os.pid_t);
                self.logger.info("serivce {} started on pid {}", .{ service_name, pid });
                self.services.get(service_name).?.value.state = ServiceState{ .Running = pid };
            },

            .ServiceExited => {
                const service_name = try deserializeString(self.allocator, &deserializer);
                defer self.allocator.free(service_name);

                const exit_code = try deserializer.deserialize(u32);
                self.logger.info("serivce {} exited with status {}", .{ service_name, exit_code });
                self.services.get(service_name).?.value.state = ServiceState{ .Stopped = exit_code };
            },
        }
    }

    pub fn handleMessages(self: *@This()) !void {
        var sockets = PollFdList.init(self.allocator);
        defer sockets.deinit();

        try sockets.append(os.pollfd{
            .fd = self.status_pipe[0],
            .events = os.POLLIN,
            .revents = 0,
        });

        while (true) {
            const available = try os.poll(sockets.items, -1);
            if (available == 0) {
                self.logger.info("timed out, retrying", .{});
                continue;
            }

            for (sockets.items) |pollfd, idx| {
                if (pollfd.revents == 0) continue;
                if (pollfd.fd == self.status_pipe[0]) {
                    // got status data to read
                    self.readStatusMessage() catch |err| {
                        self.logger.info("Failed to read status message: {}", .{err});
                    };
                }
            }
        }
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
    errdefer allocator.free(message);

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
    } else if (std.mem.startsWith(u8, message, "stop")) {
        var parts_it = std.mem.split(message, ";");
        _ = parts_it.next();

        // TODO: error handling on malformed messages
        const service_name = parts_it.next().?;

        const kv_opt = state.services.get(service_name);
        if (kv_opt) |kv| {
            const service = kv.value;
            switch (service.state) {
                .Running => |pid| {
                    try kill(pid, os.SIGTERM);
                },
                else => {},
            }
        }

        try state.writeServices(stream);
    }
}

pub const KillProcessContext = struct {
    state: DaemonState,
    pid: std.os.pid_t,
};

pub const KillError = error{PermissionDenied} || UnexpectedError;

// TODO maybe pr this back to zig
pub fn kill(pid: std.os.pid_t, sig: u8) KillError!void {
    switch (errno(std.os.system.kill(pid, sig))) {
        0 => return,
        std.os.EINVAL => unreachable, // invalid signal
        std.os.EPERM => return error.PermissionDenied,
        std.os.ESRCH => return error.UnknownPID,
        else => |err| return std.os.unexpectedErrno(err),
    }
}

pub fn termThenKillProcess(ctx: KillProcessContext) !void {
    var state = ctx.state;
    const pid = ctx.pid;
    try kill(pid, os.SIGTERM);
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

    var state = try DaemonState.init(allocator, logger);

    const daemon_message_thread = try std.Thread.spawn(
        &state,
        DaemonState.handleMessages,
    );

    while (true) {
        var pollfds = sockets.items;
        logger.info("polling {} sockets...", .{pollfds.len});

        const available = try os.poll(pollfds, -1);
        if (available == 0) {
            logger.info("timed out, retrying", .{});
            continue;
        }

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
        }
    }
}
