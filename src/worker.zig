const std = @import("std");
const linux = std.os.linux;
const net = std.net;
const posix = std.posix;

const stdout = std.io.getStdOut().writer();
const event_count = 20;

const EpollState = struct {
    fd: posix.fd_t,
    read: usize,
    data: []u8,
};

fn acceptNew(allocator: *const std.mem.Allocator, epoll_fd: i32, tid: usize, ev: *const linux.epoll_event) void {
    var remote: net.Address = undefined;
    var addr_len: linux.socklen_t = @sizeOf(net.Address);

    const flags = posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const fd = posix.accept(ev.data.fd, &remote.any, &addr_len, flags) catch |err| {
        std.log.err("t[{d}]: error in accepting: {}", .{ tid, err });
        return;
    };

    const state = allocator.create(EpollState) catch |err| {
        std.log.err("t[{d}]: failed to allocate fd state: {}", .{ tid, err });
        return;
    };
    state.read = 0;
    state.fd = fd;
    state.data = allocator.alloc(u8, 1024) catch |err| {
        posix.close(fd);
        std.log.err("t[{d}]: failed to allocate fd state: {}", .{ tid, err });
        return;
    };

    var event = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.ONESHOT,
        .data = linux.epoll_data{
            .ptr = @intFromPtr(state),
        },
    };
    posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, fd, &event) catch |err| {
        std.log.err("t[{d}]: error in adding a fd into epoll, closing it: {}", .{ tid, err });
        posix.close(fd);
    };
}

fn readIncoming(allocator: *const std.mem.Allocator, epoll_fd: i32, tid: usize, ev: *linux.epoll_event) void {
    const state: *EpollState = @ptrFromInt(ev.data.ptr);
    if (ev.events != 1) {
        defer allocator.destroy(state);
        defer allocator.free(state.data);
        posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_DEL, state.fd, ev) catch |err| {
            std.log.err("t[{d}]: error deleting from epoll: {}", .{ tid, err });
            return;
        };
        return;
    }
    defer {
        ev.events = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.ONESHOT;
        ev.data.ptr = @intFromPtr(state);
        posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_MOD, state.fd, ev) catch |err| {
            posix.close(state.fd);
            defer allocator.destroy(state);
            defer allocator.free(state.data);
            std.log.err("t[{d}]: error in adding a fd into epoll, closing it: {}", .{ tid, err });
            posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_DEL, state.fd, ev) catch |e| {
                std.log.err("t[{d}]: error deleting from epoll: {}", .{ tid, e });
            };
        };
    }
    const len = posix.read(state.fd, state.data[state.read..]) catch |err| switch (err) {
        posix.ReadError.WouldBlock => {
            std.log.err("t[{d}]: wouldblock!", .{tid});
            return;
        },
        else => {
            std.log.err("t[{d}]: error in reading from the socket: {}", .{ tid, err });
            state.read = 0;
            return;
        },
    };
    state.read = state.read + len;
    std.debug.print("read: {}, len: {}, data len: {}\n", .{ state.read, len, state.data.len });
    if (state.read == state.data.len) {
        state.data = allocator.realloc(state.data, state.data.len * 2) catch |err| {
            std.log.err("t[{d}]: error in reallocation: {}", .{ tid, err });
            return;
        };
    } else {
        _ = posix.write(state.fd, state.data[0..state.read]) catch |err| {
            std.log.err("t[{d}]: error in writing to socket: {}", .{ tid, err });
            return;
        };
        state.read = 0;
    }
}

pub fn work(allocator: *const std.mem.Allocator, epoll_fd: i32, listen_fd: i32, tid: usize) void {
    var events: [event_count]linux.epoll_event = undefined;
    while (true) {
        const ev_count = linux.epoll_wait(epoll_fd, &events, event_count, 0);
        for (events[0..ev_count]) |*ev| {
            if (ev.data.fd == listen_fd) acceptNew(allocator, epoll_fd, tid, ev) else readIncoming(allocator, epoll_fd, tid, ev);
        }
    }
}
