const std = @import("std");

pub fn main(sockpath: [108]u8) anyerror!void {
    std.debug.warn("daemon\n");
    const sockfd = try std.os.socket(std.os.AF_UNIX, std.os.SOCK_STREAM, 0);
    defer std.os.close(sockfd);

    for (sockpath) |char| {
        std.debug.warn("{} ", char);
    }
    std.debug.warn("\n");

    // TODO make this work, it doesnt :(

    var addr: std.os.sockaddr = undefined;

    @memset(@ptrCast([*]volatile u8, &addr), 0, @sizeOf(std.os.sockaddr));

    addr.un.family = std.os.AF_UNIX;
    std.mem.copy(u8, &addr.un.path, sockpath);

    //var addr = std.os.sockaddr{
    //    .un = std.os.sockaddr_un{
    //        .family = std.os.AF_UNIX,
    //        .path = [_]u8{0} ** 108,
    //    },
    //};

    //std.mem.copy(u8, &addr.un.path, sockpath);

    try std.os.bind(sockfd, &addr);
    std.time.sleep(10 * std.time.second);
}
