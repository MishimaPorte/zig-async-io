const std = @import("std");
const linux = std.os.linux;
const net = std.net;
const posix = std.posix;
const fr = @import("frame.zig");
const StaticTable = @import("table.zig").StaticTable;
const Frame = fr.Frame;
const Class = fr.Class;
const body_start = fr.body_start;

const stdout = std.io.getStdOut().writer();
const event_count = 20;

const ConnectionState = struct {
    fd: posix.fd_t,
    num: usize,
    data: []u8,
    status: enum { READING, WRITING },
    fsm_state: enum {
        None,
        ReceivedPH,
    } = .None,

    const ConnectionError = error{
        WrongState,
    };

    pub fn connStart(self: *ConnectionState, allocator: *std.mem.Allocator) !void {
        const buf = allocator.alloc(u8, 72);
        _ = buf;
        switch (self.fsm_state) {
            .None => {
                return error.WrongState;
            },
            .ReceivedPH => {
                return;
            },
        }
    }

    pub fn receive(self: *ConnectionState, frame: Frame) !void {
        std.debug.print("frame incoming with header: {}\n", .{frame.header});
        switch (self.fsm_state) {
            .None => {
                return error.WrongState;
            },
            .ReceivedPH => {
                var buf: [72]u8 = undefined;
                // connection.start method
                // rather unreadable and unmaintainable
                var out_frame = try Frame.fromHeaderAndByteSlice(.{
                    .type = .Method,
                    .channel_id = 0,
                    .len = 65,
                }, &buf);
                out_frame.setMethod(Class.Connection.id, Class.Connection.start);
                out_frame.data[body_start] = 0;
                out_frame.data[body_start + 1] = 9;
                var table = StaticTable.init(out_frame.data[body_start + 2 ..]);
                try table.addString("host", "127.0.0.1");
                try table.addString("product", "zmq");
                try table.addString("platform", "urmom"); // too heavy to maintain i believe
                return;
            },
        }
    }

    pub fn write(self: *ConnectionState, out_fd: i32, tid: usize) !void {
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
            const errno = posix.errno(@as(i64, @bitCast(written)));
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
            if (self.num == 5368709120) {
                std.log.info("t[{d}]: finished", .{tid});
                self.status = .READING;
                self.num = 0;
            }
            var i64_written: i64 = @intCast(self.num);
            const written = linux.sendfile(self.fd, out_fd, &i64_written, 5368709120);
            const errno = posix.errno(@as(i64, @bitCast(written)));
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
        }
    }

    pub fn read(self: *ConnectionState, allocator: *const std.mem.Allocator, tid: usize) !void {
        const len = posix.read(self.fd, self.data[self.num..]) catch |err| switch (err) {
            error.WouldBlock => {
                self.status = .WRITING;
                self.num = 0;
                return;
            },
            else => {
                std.log.err("t[{d}]: error in reading from the socket: {}", .{ tid, err });
                self.num = 0;
                return;
            },
        };
        if (len == 8 and std.mem.eql(u8, self.data[0..8], &[8]u8{ 'A', 'M', 'Q', 'P', 0, 0, 9, 1 })) {
            std.log.debug("t[{d}]: protocol header accepted: \"{s}\"", .{ tid, self.data[0..8] });
            self.fsm_state = .ReceivedPH;
            return;
        }
        self.num = self.num + len;
        if (self.num == self.data.len) {
            self.data = allocator.realloc(self.data, self.data.len * 2) catch |err| {
                std.log.err("t[{d}]: error in reallocation: {}", .{ tid, err });
                return;
            };
        }
        if (self.num >= 7) {
            // TODO: not parse thingie every time i guess
            const frame = Frame.fromByteSlice(self.data[0..self.num]) catch |err| switch (err) {
                error.EndFrameOctetMissing => return err,
                error.NotEnoughBytes => return, // wait for more bytes!
            };
            defer {
                std.mem.copyForwards(
                    u8,
                    self.data[0..],
                    self.data[frame.header.len + 8 .. self.num],
                );
                self.num = self.num - (frame.header.len + 8);
            }
            return self.receive(frame);
        }
    }

    pub fn reigniteEpoll(self: *ConnectionState, allocator: *const std.mem.Allocator, ev: *linux.epoll_event, epoll_fd: i32, tid: usize) void {
        ev.events = linux.EPOLL.OUT | linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.ONESHOT;
        ev.data.ptr = @intFromPtr(self);
        posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_MOD, self.fd, ev) catch |err| {
            std.log.err("t[{d}]: error in adding a fd into epoll, closing it: {}", .{ tid, err });
            self.deinit(allocator);
        };
    }
    pub fn deinit(self: *ConnectionState, allocator: *const std.mem.Allocator) void {
        defer allocator.destroy(self);
        defer allocator.free(self.data);
        posix.close(self.fd);
    }
};

fn readIncoming(allocator: *const std.mem.Allocator, out_fd: posix.fd_t, epoll_fd: i32, tid: usize, ev: *linux.epoll_event) void {
    const state: *ConnectionState = @ptrFromInt(ev.data.ptr);

    if (ev.events & linux.EPOLL.OUT != 0 and state.status == .WRITING) {
        state.write(out_fd, tid) catch return state.deinit(allocator);
        state.reigniteEpoll(allocator, ev, epoll_fd, tid);
    } else if (ev.events & linux.EPOLL.IN != 0 and state.status == .READING) {
        state.read(allocator, tid) catch return state.deinit(allocator);
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
    const state = allocator.create(ConnectionState) catch |err| {
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
        const ev_count = linux.epoll_wait(epoll_fd, &events, event_count, 5);
        for (events[0..ev_count]) |*ev| {
            if (ev.data.fd == listen_fd) {
                acceptNew(allocator, epoll_fd, tid, ev);
            } else {
                readIncoming(allocator, out_fd, epoll_fd, tid, ev);
            }
        }
    }
}
