const std = @import("std");
const net = std.net;
const work = @import("connection.zig").work;
const linux = std.os.linux;
const posix = std.posix;
const workerthreadcount = @import("__Build_Config").workerthreadcount;

pub fn main() !void {
    const listen_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 2282);
    const server = listen_address.listen(.{
        .reuse_address = true,
    }) catch |err| return err;
    std.log.info("starting listening...", .{});

    const epoll_flags = linux.EPOLL.CLOEXEC;
    const epoll_fd = try posix.epoll_create1(epoll_flags);
    defer posix.close(epoll_fd);

    var event = linux.epoll_event{
        // .events = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.ONESHOT,
        .events = linux.EPOLL.IN,
        .data = linux.epoll_data{
            .fd = server.stream.handle,
        },
    };
    try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, server.stream.handle, &event);

    var tpool: [10]std.Thread = undefined;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    for (0..workerthreadcount) |i| {
        tpool[i] = try std.Thread.spawn(.{}, work, .{ gpa_allocator, epoll_fd, server.stream.handle, i + 1 });
        tpool[i].detach();
    }
    work(gpa_allocator, epoll_fd, server.stream.handle, 0);
    return void{};
}
