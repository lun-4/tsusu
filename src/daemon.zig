const std = @import("std");

pub fn main(sockpath: [108]u8) anyerror!void {
    std.debug.warn("daemon\n");
    const sockfd = try std.os.socket(std.os.AF_UNIX, std.os.SOCK_STREAM, 0);
    defer std.os.close(sockfd);

    for (sockpath) |char| {
        std.debug.warn("{} ", char);
    }
    std.debug.warn("\n");

    var addr = std.os.sockaddr{
        .un = std.os.sockaddr_un{
            .family = std.os.AF_UNIX,
            .path = [_]u8{0} ** 108,
        },
    };

    std.mem.copy(u8, &addr.un.path, sockpath);

    // os.bind, accept, and connect, have local hacks.

    try std.os.bind(
        sockfd,
        &addr,
        @intCast(u32, std.mem.len(u8, &sockpath) + 2),
    );

    var cli_addr = std.os.sockaddr{
        .un = std.os.sockaddr_un{
            .family = std.os.AF_UNIX,
            .path = [_]u8{0} ** 108,
        },
    };

    std.debug.warn("bind done! {}\n", sockfd);

    while (true) {
        var sockaddr_size = @intCast(u32, std.mem.len(u8, &cli_addr.un.path) + 2);

        var clifd = try std.os.accept4(
            sockfd,
            &cli_addr,
            &sockaddr_size,
            0,
        );
        defer std.os.close(clifd);
        std.debug.warn("client: {}\n", clifd);
    }
    std.time.sleep(15 * std.time.second);
}
