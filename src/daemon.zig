const std = @import("std");
const os = std.os;

pub fn unixListen(sockfd: os.fd_t) !std.fs.File {
    const nonblock = if (std.io.is_async) os.SOCK_NONBLOCK else 0;
    const accept_flags = nonblock | os.SOCK_CLOEXEC;

    var accepted_addr: os.sockaddr_un = undefined;
    var adr_len: os.socklen_t = @sizeOf(std.os.sockaddr_un);

    if (os.accept4(sockfd, @ptrCast(*os.sockaddr, &accepted_addr), &adr_len, accept_flags)) |fd| {
        return std.fs.File.openHandle(fd);
    } else |err| switch (err) {
        // We only give SOCK_NONBLOCK when I/O mode is async, in which case this error
        // is handled by os.accept4.
        error.WouldBlock => unreachable,
        else => |e| return e,
    }
}

pub fn main() anyerror!void {
    std.debug.warn("daemon\n");
    const allocator = std.heap.direct_allocator;

    const opt_non_block = if (std.io.mode == .evented) os.SOCK_NONBLOCK else 0;
    const sockfd = try os.socket(
        os.AF_UNIX,
        os.SOCK_STREAM | os.SOCK_CLOEXEC | opt_non_block,
        0,
    );
    var server_sock = std.fs.File.openHandle(sockfd);
    defer server_sock.close();

    const path = "/home/luna/.local/share/tsusu.sock";
    var sock_addr = std.os.sockaddr_un{
        .family = std.os.AF_UNIX,
        .path = undefined,
    };
    if (path.len > sock_addr.path.len) return error.NameTooLong;
    std.mem.copy(u8, &sock_addr.path, path);

    const size = @intCast(u32, @sizeOf(os.sockaddr_un) - sock_addr.path.len + path.len);
    try std.os.bind(sockfd, @ptrCast(*os.sockaddr, &sock_addr), size);
    try std.os.listen(sockfd, 128);

    std.debug.warn("bind done on fd={}\n", sockfd);

    while (true) {
        var cli = try unixListen(sockfd);
        defer cli.close();
        std.debug.warn("client fd from server: {}\n", cli.handle);
    }
}
