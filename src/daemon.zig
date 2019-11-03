const std = @import("std");
const os = std.os;

pub fn unixAccept(sockfd: os.fd_t) !std.fs.File {
    const nonblock = if (std.io.is_async) os.SOCK_NONBLOCK else 0;
    const accept_flags = nonblock | os.SOCK_CLOEXEC;

    var accepted_addr: os.sockaddr_un = undefined;
    var adr_len: os.socklen_t = @sizeOf(std.os.sockaddr_un);
    var fd = try os.accept4(
        sockfd,
        @ptrCast(*os.sockaddr, &accepted_addr),
        &adr_len,
        accept_flags,
    );
    return std.fs.File.openHandle(fd);
}

fn readManyFromClient(allocator: *std.mem.Allocator, pollfd: os.pollfd) !void {
    var buf = try allocator.alloc(u8, 1024);
    while (true) {
        const count = os.read(pollfd.fd, buf) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };

        if (count == 0) {
            return error.Closed;
        }

        var message = buf[0..count];
        std.debug.warn("got msg: {}\n", message);
    }
}

const PollFdList = std.ArrayList(os.pollfd);

pub fn main() anyerror!void {
    std.debug.warn("daemon\n");
    const allocator = std.heap.direct_allocator;

    var server_sock = try std.net.bindUnixSocket("/home/luna/.local/share/tsusu.sock");
    defer server_sock.close();

    try std.os.listen(server_sock.handle, 128);

    std.debug.warn("bind done on fd={}\n", server_sock.handle);

    var sockets = PollFdList.init(allocator);
    defer sockets.deinit();

    try sockets.append(os.pollfd{
        .fd = server_sock.handle,
        .events = os.POLLIN,
        .revents = 0,
    });

    while (true) {
        var pollfds = sockets.toSlice();
        std.debug.warn("polling {} sockets...\n", pollfds.len);
        var available = try os.poll(pollfds, -1);
        if (available == 0) {
            std.debug.warn("timed out, retrying\n");
            continue;
        }

        // TODO remove WouldBlock checks when we have an event loop here

        for (pollfds) |pollfd, idx| {
            if (pollfd.revents == 0) continue;
            if (pollfd.revents != os.POLLIN) return error.UnexpectedSocketRevents;

            if (pollfd.fd == server_sock.handle) {
                while (true) {
                    var cli = unixAccept(server_sock.handle) catch |err| {
                        if (err == error.WouldBlock) break;
                        return err;
                    };

                    try sockets.append(os.pollfd{
                        .fd = cli.handle,
                        .events = os.POLLIN,
                        .revents = 0,
                    });

                    std.debug.warn("server: got client {}\n", cli.handle);
                }
            } else {
                readManyFromClient(allocator, pollfd) catch |err| {
                    std.os.close(pollfd.fd);
                    std.debug.warn("closed fd {} from {}\n", pollfd.fd, err);
                    _ = sockets.orderedRemove(idx);
                };
            }
        }
    }
}
