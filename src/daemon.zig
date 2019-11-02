const std = @import("std");

pub fn main() anyerror!void {
    std.debug.warn("daemon\n");
    const allocator = std.heap.direct_allocator;

    var server = std.net.TcpServer.init(std.net.TcpServer.Options{});
    defer server.deinit();

    var addr = try std.net.IpAddress.parse("127.0.0.1", 24696);
    try server.listen(addr);

    std.debug.warn("bind done on fd={}\n", server.sockfd);

    while (true) {
        var cli = try server.accept();
        defer cli.close();

        std.debug.warn("client fd from server: {}\n", cli.handle);
    }
}
