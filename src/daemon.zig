const std = @import("std");
const os = std.os;

//pub const io_mode = .evented;

pub const Service = struct {
    name: []const u8,
};

pub const ServiceList = std.ArrayList(Service);

pub const DaemonState = struct {
    allocator: *std.mem.Allocator,
    services: ServiceList,

    pub fn init(allocator: *std.mem.Allocator) @This() {
        return .{ .allocator = allocator, .services = ServiceList.init(allocator) };
    }
};

fn readManyFromClient(
    state: *DaemonState,
    pollfd: os.pollfd,
) !void {
    var buf = try state.allocator.alloc(u8, 1024);

    while (true) {
        const count = os.read(pollfd.fd, buf) catch |err| {
            // TODO replace by continue
            if (err == error.WouldBlock) break;
            return err;
        };

        if (count == 0) {
            return error.Closed;
        }

        var message = buf[0..count];
        std.debug.warn("[d]got msg: {}\n", .{message});

        if (std.mem.eql(u8, message, "list")) {
            std.debug.warn("[d]got list: {}", .{state.services});
            try os.write(pollfd.fd, "awoo");
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

pub fn main() anyerror!void {
    std.debug.warn("[d]daemon\n", .{});
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

    std.debug.warn("[d]bind+listen done on fd={}\n", .{server.sockfd});

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

    var state = DaemonState.init(allocator);

    while (true) {
        var pollfds = sockets.toSlice();
        std.debug.warn("[d]polling {} sockets...\n", .{pollfds.len});
        var available = try os.poll(pollfds, -1);
        if (available == 0) {
            std.debug.warn("[d]timed out, retrying\n", .{});
            continue;
        }

        // TODO remove our WouldBlock checks when we have an event loop here

        std.debug.warn("[d]got {} available fds\n", .{available});

        for (pollfds) |pollfd, idx| {
            if (pollfd.revents == 0) continue;
            if (pollfd.revents != os.POLLIN) return error.UnexpectedSocketRevents;

            if (pollfd.fd == server.sockfd.?) {
                while (true) {
                    std.debug.warn("[d]try accept?\n", .{});
                    var conn = server.accept() catch |e| {
                        std.debug.warn("[d??]{}\n", .{e});
                        unreachable;
                    };
                    var sock = conn.file;

                    try sockets.append(os.pollfd{
                        .fd = sock.handle,
                        .events = os.POLLIN,
                        .revents = 0,
                    });

                    // as soon as we get a new client, send helo
                    try sock.write("HELO;");
                    std.debug.warn("[d]server: got client {}\n", .{sock.handle});

                    // TODO many clients per accept someday
                    break;
                }
                std.debug.warn("[d]end thing\n", .{});

                //} else if (pollfd.fd == signal_fd) {
                //    std.debug.warn("got sigint");
                //    return;
            } else {
                readManyFromClient(&state, pollfd) catch |err| {
                    std.os.close(pollfd.fd);
                    std.debug.warn("[d]closed fd {} from {}\n", .{ pollfd.fd, err });
                    _ = sockets.orderedRemove(idx);
                };
            }
            std.debug.warn("[d]tick tick?\n", .{});
        }
    }
}
