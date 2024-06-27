const std = @import("std");
const linux = std.os.linux;
const net = std.net;
const posix = std.posix;

const stdout = std.io.getStdOut().writer();
const event_count = 20;

const EpollState = struct {
    fd: posix.fd_t,
    num: usize,
    status: enum { READING, WRITING },
    data: []u8,

    pub fn write(self: *EpollState, out_fd: i32, tid: usize) !void {
        if (self.num == 0) {
            _ = posix.write(self.fd,
                \\HTTP/1.1 200 OK
                \\Server: kek
                \\Content-Length: 5368709120
                \\
                \\
            ) catch |err| {
                std.log.err("t[{d}]: error in writing header to socket: {}", .{ tid, err });
                return;
            };
            const written = linux.sendfile(self.fd, out_fd, null, 5368709120);
            const errno = posix.errno(written);
            switch (errno) {
                .SUCCESS => {
                    self.num = self.num + written;
                },
                .AGAIN => {
                    std.debug.panic("eagain", .{});
                },
                else => {
                    std.log.err("t[{d}]: error in writing body to socket: {}", .{ tid, errno });
                    return error{Error}.Error;
                },
            }
        } else {
            var i64_written: i64 = @intCast(self.num);
            const written = linux.sendfile(self.fd, out_fd, &i64_written, 5368709120);
            const errno = posix.errno(written);
            switch (errno) {
                .SUCCESS => {
                    self.num = self.num + written;
                },
                .AGAIN => {
                    // never occurs...
                    std.debug.panic("eagain", .{});
                },
                else => {
                    std.log.err("t[{d}]: error in writing body to socket: {}", .{ tid, errno });
                    return error{Error}.Error;
                },
            }
            if (self.num == 5368709120) {
                std.log.info("t[{d}]: finished", .{tid});
                self.status = .READING;
                self.num = 0;
            }
        }
    }

    pub fn read(self: *EpollState, allocator: *const std.mem.Allocator, tid: usize) void {
        const len = posix.read(self.fd, self.data[self.num..]) catch |err| switch (err) {
            posix.ReadError.WouldBlock => {
                std.log.info("t[{d}]: read wouldblock!", .{tid});
                return;
            },
            else => {
                std.log.err("t[{d}]: error in reading from the socket: {}", .{ tid, err });
                self.num = 0;
                return;
            },
        };
        self.num = self.num + len;
        if (self.num == self.data.len) {
            self.data = allocator.realloc(self.data, self.data.len * 2) catch |err| {
                std.log.err("t[{d}]: error in reallocation: {}", .{ tid, err });
                return;
            };
        } else if (self.num < self.data.len) {
            self.status = .WRITING;
            self.num = 0;
        }
    }

    pub fn reigniteEpoll(self: *EpollState, allocator: *const std.mem.Allocator, ev: *linux.epoll_event, epoll_fd: i32, tid: usize) void {
        ev.events = linux.EPOLL.OUT | linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.ONESHOT;
        ev.data.ptr = @intFromPtr(self);
        posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_MOD, self.fd, ev) catch |err| {
            std.log.err("t[{d}]: error in adding a fd into epoll, closing it: {}", .{ tid, err });
            self.deinit(allocator);
        };
    }
    pub fn deinit(self: *EpollState, allocator: *const std.mem.Allocator) void {
        defer allocator.destroy(self);
        defer allocator.free(self.data);
        posix.close(self.fd);
    }
};

fn readIncoming(allocator: *const std.mem.Allocator, out_fd: posix.fd_t, epoll_fd: i32, tid: usize, ev: *linux.epoll_event) void {
    const state: *EpollState = @ptrFromInt(ev.data.ptr);

    if (ev.events & linux.EPOLL.OUT != 0 and state.status == .WRITING) {
        state.write(out_fd, tid) catch return state.deinit(allocator);
        state.reigniteEpoll(allocator, ev, epoll_fd, tid);
    } else if (ev.events & linux.EPOLL.IN != 0 and state.status == .READING) {
        state.read(allocator, tid);
        state.reigniteEpoll(allocator, ev, epoll_fd, tid);
    } else if (ev.events & linux.EPOLL.OUT != 0 and state.status == .READING) {
        state.reigniteEpoll(allocator, ev, epoll_fd, tid);
    } else state.deinit(allocator);
}

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
    state.num = 0;
    state.status = .READING;
    state.fd = fd;
    state.data = allocator.alloc(u8, 1024) catch |err| {
        posix.close(fd);
        std.log.err("t[{d}]: failed to allocate fd state: {}", .{ tid, err });
        return;
    };

    var event = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.ET | linux.EPOLL.ONESHOT,
        .data = linux.epoll_data{
            .ptr = @intFromPtr(state),
        },
    };
    posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, fd, &event) catch |err| {
        std.log.err("t[{d}]: error in adding a fd into epoll, closing it: {}", .{ tid, err });
        posix.close(fd);
    };
}

pub fn work(allocator: *const std.mem.Allocator, out_fd: i32, epoll_fd: i32, listen_fd: i32, tid: usize) void {
    var events: [event_count]linux.epoll_event = undefined;
    while (true) {
        const ev_count = linux.epoll_wait(epoll_fd, &events, event_count, 0);
        for (events[0..ev_count]) |*ev| {
            if (ev.data.fd == listen_fd) {
                acceptNew(allocator, epoll_fd, tid, ev);
            } else {
                readIncoming(allocator, out_fd, epoll_fd, tid, ev);
            }
        }
    }
}
