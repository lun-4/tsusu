const std = @import("std");
const os = std.os;

const Logger = @import("logger.zig").Logger;
const helpers = @import("helpers.zig");
const util = @import("util.zig");

const supervisors = @import("supervisor.zig");
const thread_commands = @import("thread_commands.zig");

const superviseProcess = supervisors.superviseProcess;
const SupervisorContext = supervisors.SupervisorContext;

const killService = thread_commands.killService;
const KillServiceContext = thread_commands.KillServiceContext;

const WatchServiceContext = thread_commands.WatchServiceContext;
const watchService = thread_commands.watchService;

const HeapRc = @import("rc.zig").HeapRc;
const Client = @import("client.zig").Client;
pub const RcClient = HeapRc(Client);

pub const FdList = std.ArrayList(std.os.fd_t);

pub const ServiceStateType = enum(u8) {
    NotRunning,
    Running,
    Restarting,
    Stopped,
};

pub const RunningState = struct {
    pid: std.os.pid_t,

    /// File desctiptor for stdout
    stdout: std.os.fd_t,
    stderr: std.os.fd_t,

    /// File desctiptor for the thread that reads from stdout and writes it
    /// to a logfile
    logger_thread: std.os.fd_t,
};

pub const ServiceState = union(ServiceStateType) {
    NotRunning: void,
    Running: RunningState,
    Restarting: struct { exit_code: u32, clock_ns: u64, sleep_ns: u64 },
    Stopped: u32,
};

pub const Service = struct {
    name: []const u8,
    cmdline: []const u8,

    state: ServiceState = ServiceState{ .NotRunning = {} },
    stop_flag: bool = false,

    /// List of file descriptors for clients that want to
    /// have logs of the service fanned out to them.
    logger_client_fds: FdList,

    pub fn addLoggerClient(self: *@This(), fd: std.os.fd_t) !void {
        try self.logger_client_fds.append(fd);
    }

    pub fn removeLoggerClient(self: *@This(), client_fd: std.os.fd_t) void {
        for (self.logger_client_fds.items) |fd, idx| {
            if (fd == client_fd) {
                const fd_at_idx = self.logger_client_fds.orderedRemove(idx);
                std.debug.assert(fd_at_idx == client_fd);
                break;
            }
        }
    }
};

pub const ServiceMap = std.StringHashMap(*Service);
pub const FileLogger = Logger(std.fs.File.OutStream);

pub const MessageOP = enum(u8) {
    ServiceStarted,
    ServiceExited,
    ServiceRestarting,
};

pub const Message = union(MessageOP) {
    ServiceStarted: struct {
        name: []const u8,
        pid: std.os.pid_t,
        stdout: std.fs.File,
        stderr: std.fs.File,

        logger_thread: std.os.fd_t,
    },
    ServiceExited: struct {
        name: []const u8,
        exit_code: u32,
    },
    ServiceRestarting: struct {
        name: []const u8,
        exit_code: u32,
        clock_ts_ns: u64,
        sleep_ns: u64,
    },
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

pub const ClientMap = std.AutoHashMap(std.os.fd_t, *RcClient);

pub const DaemonState = struct {
    allocator: *std.mem.Allocator,
    services: ServiceMap,
    clients: ClientMap,
    logger: *FileLogger,

    status_pipe: [2]std.os.fd_t,

    pub fn init(allocator: *std.mem.Allocator, logger: *FileLogger) !@This() {
        return DaemonState{
            .allocator = allocator,
            .services = ServiceMap.init(allocator),
            .clients = ClientMap.init(allocator),
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
                try serializer.serialize(data.stdout.handle);
                try serializer.serialize(data.stderr.handle);
                try serializer.serialize(data.logger_thread);
            },
            .ServiceExited => |data| {
                try serializeString(&serializer, data.name);
                try serializer.serialize(data.exit_code);
            },
            .ServiceRestarting => |data| {
                try serializeString(&serializer, data.name);
                try serializer.serialize(data.exit_code);
                try serializer.serialize(data.clock_ts_ns);
                try serializer.serialize(data.sleep_ns);
            },
        }
    }

    fn writeService(
        self: @This(),
        stream: var,
        key: []const u8,
        service: *Service,
    ) !void {
        try stream.print("{},", .{key});

        const state_string = switch (service.state) {
            .NotRunning => try stream.print("0", .{}),
            .Running => |data| try stream.print("1,{}", .{data.pid}),
            .Stopped => |code| try stream.print("2,{}", .{code}),
            .Restarting => |data| {
                // show remaining amount of ns until service restarts fully
                const current_clock = @intCast(i64, util.monotonicRead());
                const end_ts_ns = @intCast(i64, data.clock_ns + data.sleep_ns);
                const remaining_ns = current_clock - end_ts_ns;
                try stream.print("3,{},{}", .{ data.exit_code, remaining_ns });
            },
        };

        try stream.print(";", .{});
    }

    pub fn writeServices(self: @This(), stream: var) !void {
        var services_it = self.services.iterator();
        while (services_it.next()) |kv| {
            try self.writeService(stream, kv.key, kv.value);
        }
        _ = try stream.write("!");
    }

    pub fn addService(self: *@This(), name: []const u8, service: *Service) !void {
        _ = try self.services.put(
            name,
            service,
        );
    }

    pub fn addClient(self: *@This(), fd: std.os.fd_t, client: *RcClient) !void {
        std.debug.warn("add client fd={} ptr={x}\n", .{ fd, @ptrToInt(client.ptr.?) });
        _ = try self.clients.put(fd, client);
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
                const stdout = try deserializer.deserialize(std.os.fd_t);
                const stderr = try deserializer.deserialize(std.os.fd_t);
                const logger_thread = try deserializer.deserialize(std.os.fd_t);
                self.logger.info(
                    "serivce {} started on pid {} stdout={} stderr={}",
                    .{ service_name, pid, stdout, stderr },
                );
                self.services.get(service_name).?.value.state = ServiceState{
                    .Running = RunningState{
                        .pid = pid,
                        .stdout = stdout,
                        .stderr = stderr,

                        .logger_thread = logger_thread,
                    },
                };
            },

            .ServiceExited => {
                const service_name = try deserializeString(self.allocator, &deserializer);
                defer self.allocator.free(service_name);

                const exit_code = try deserializer.deserialize(u32);
                self.logger.info("serivce {} exited with status {}", .{ service_name, exit_code });
                self.services.get(service_name).?.value.state = ServiceState{ .Stopped = exit_code };
            },

            .ServiceRestarting => {
                const service_name = try deserializeString(self.allocator, &deserializer);
                defer self.allocator.free(service_name);

                const exit_code = try deserializer.deserialize(u32);
                const clock_ns = try deserializer.deserialize(u64);
                const sleep_ns = try deserializer.deserialize(u64);

                self.logger.info("serivce {} restarting, will be back in {}ns", .{ service_name, sleep_ns });

                self.services.get(service_name).?.value.state = ServiceState{
                    .Restarting = .{
                        .exit_code = exit_code,
                        .clock_ns = clock_ns,
                        .sleep_ns = sleep_ns,
                    },
                };
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

pub const OutStream = std.io.OutStream(std.fs.File, std.fs.File.WriteError, std.fs.File.write);

fn readManyFromClient(
    state: *DaemonState,
    pollfd: os.pollfd,
) !void {
    var logger = state.logger;
    var allocator = state.allocator;
    var sock = std.fs.File{ .handle = pollfd.fd };
    var in_stream = sock.inStream();
    var stream: OutStream = sock.outStream();

    var client: *RcClient = undefined;

    // reuse allocated RcClient in state, and if it doesnt exist, create
    // a new client.
    var client_kv_opt = state.clients.get(pollfd.fd);
    if (client_kv_opt) |client_kv| {
        client = client_kv.value;
    } else {
        // freeing of the RcClient and Client wrapped struct is done
        // by themselves. memory of this is managed via refcounting
        client = try RcClient.init(allocator);
        client.ptr.?.* = Client.init(pollfd.fd);

        // increment reference (for the main thread)
        _ = client.incRef();

        // link fd to client inside state
        try state.addClient(pollfd.fd, client);
    }

    const message = try in_stream.readUntilDelimiterAlloc(allocator, '!', 512);
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
        var existing_kv = state.services.get(service_name);
        if (existing_kv != null) {
            // start existing service
            var service = existing_kv.?.value;

            service.stop_flag = false;

            // XXX: we just need to start the supervisor thread again
            // and point the service in memory to it

            // XXX: refactor the supervisor to follow the pattern of other
            // threaded commands. it should be easier to manage. also
            // use Service instead of ServiceDecl. we should
            // remove ServiceDecl

            const supervisor_thread = try std.Thread.spawn(
                SupervisorContext{ .state = state, .service = service },
                superviseProcess,
            );

            std.time.sleep(250 * std.time.ns_per_ms);
            try state.writeServices(stream);
            return;
        }

        // TODO maybe some refcounting magic could go here
        const service_cmdline = parts_it.next() orelse {
            try stream.print("err path needed for new service!", .{});
            return;
        };
        logger.info("got service start: {} {}", .{ service_name, service_cmdline });

        var service = try allocator.create(Service);
        service.* =
            Service{
            .name = service_name,
            .cmdline = service_cmdline,
            .logger_client_fds = FdList.init(state.allocator),
        };

        logger.info("starting service {} with cmdline {}", .{ service_name, service_cmdline });

        // the supervisor thread actually waits on the process in a loop
        // so that we can do things like exponential backoff, etc.
        const supervisor_thread = try std.Thread.spawn(
            SupervisorContext{ .state = state, .service = service },
            superviseProcess,
        );

        try state.addService(service_name, service);

        // TODO: remove this, make starting itself run in a thread.
        std.time.sleep(250 * std.time.ns_per_ms);
        try state.writeServices(stream);
    } else if (std.mem.startsWith(u8, message, "service")) {
        var parts_it = std.mem.split(message, ";");
        _ = parts_it.next();

        // TODO: error handling on malformed messages
        const service_name = parts_it.next().?;

        const kv_opt = state.services.get(service_name);
        if (kv_opt) |kv| {
            try state.writeService(stream, kv.key, kv.value);
            try stream.print("!", .{});
        } else {
            try stream.print("err unknown service!", .{});
        }
    } else if (std.mem.startsWith(u8, message, "stop")) {
        var parts_it = std.mem.split(message, ";");
        _ = parts_it.next();

        // TODO: error handling on malformed messages
        const service_name = parts_it.next().?;

        const kv_opt = state.services.get(service_name);
        if (kv_opt) |kv| {
            kv.value.stop_flag = true;

            switch (kv.value.state) {
                .Running => {},
                else => {
                    try stream.print("err service not running!", .{});
                    return;
                },
            }

            _ = try std.Thread.spawn(
                KillServiceContext{
                    .state = state,
                    .service = kv.value,
                    .client = client.incRef(),
                },
                killService,
            );
        } else {
            try stream.print("err unknown service!", .{});
        }
    } else if (std.mem.startsWith(u8, message, "logs")) {
        var parts_it = std.mem.split(message, ";");
        _ = parts_it.next();

        // TODO: error handling on malformed messages
        const service_name = parts_it.next().?;

        const kv_opt = state.services.get(service_name);
        if (kv_opt) |kv| {
            switch (kv.value.state) {
                .Running => {},
                else => {
                    try stream.print("err service not running!", .{});
                    return;
                },
            }

            _ = try std.Thread.spawn(
                WatchServiceContext{
                    .state = state,
                    .service = kv.value,
                    .client = client.incRef(),
                },
                watchService,
            );
        } else {
            try stream.print("err unknown service!", .{});
        }
    }
}

const PollFdList = std.ArrayList(os.pollfd);

fn sigemptyset(set: *std.os.sigset_t) void {
    for (set) |*val| {
        val.* = 0;
    }
}

fn readFromSignalFd(allocator: *std.mem.Allocator, logger: *FileLogger, signal_fd: std.os.fd_t) !void {
    var buf: [@sizeOf(os.linux.signalfd_siginfo)]u8 align(8) = undefined;
    _ = try os.read(signal_fd, &buf);

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

        return;
    }

    logger.info("got SIGINT or SIGTERM, stopping!", .{});

    // TODO: stop all services one by one

    const pidpath = try helpers.getPathFor(allocator, .Pid);
    const sockpath = try helpers.getPathFor(allocator, .Sock);

    std.os.unlink(pidpath) catch |err| {
        logger.info("failed to delete pid file: {}", .{err});
    };
    std.os.unlink(sockpath) catch |err| {
        logger.info("failed to delete sock file: {}", .{err});
    };

    return error.Shutdown;
}

fn handleNewClient(logger: *FileLogger, server: *std.net.StreamServer, sockets: *PollFdList) void {
    var conn = server.accept() catch |err| {
        logger.info("Failed to accept: {}", .{err});
        return;
    };

    var sock = conn.file;

    _ = sock.write("helo!") catch |err| {
        logger.info("Failed to send helo: {}", .{err});
        return;
    };

    sockets.append(os.pollfd{
        .fd = sock.handle,
        .events = os.POLLIN,
        .revents = 0,
    }) catch |err| {
        _ = sock.write("err out of memory!") catch |write_err| {
            logger.info("Failed to send message from {} in append: {}", .{ err, write_err });
        };
    };

    return;
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
                handleNewClient(logger, &server, &sockets);
            } else if (pollfd.fd == signal_fd) {
                readFromSignalFd(state.allocator, logger, signal_fd) catch |err| {
                    if (err == error.Shutdown) return else logger.info("failed to read from signal fd: {}\n", .{err});
                };
            } else {
                logger.info("got fd for read! fd={}", .{pollfd.fd});

                readManyFromClient(&state, pollfd) catch |err| {
                    logger.info("got error, fd={} err={}", .{ pollfd.fd, err });

                    // signal that the client must not be used, any other
                    // operations on it will give error.Closed
                    var kv_opt = state.clients.get(pollfd.fd);
                    if (kv_opt) |kv| {
                        // decrease reference for main thread and mark
                        // the fd as closed

                        // TODO: investigate why tsusu seems to destroy itself when
                        // we don't force-close the fd here, since everyone
                        // else should get EndOfStream, just like us...
                        kv.value.ptr.?.close();

                        kv.value.decRef();
                        _ = state.clients.remove(pollfd.fd);
                    }

                    _ = sockets.orderedRemove(idx);
                };
            }
        }
    }
}
