const std = @import("std");
const linux = std.os.linux;
const net = std.net;
const posix = std.posix;
const fr = @import("frame.zig");
const amqp = @import("amqp_encoding.zig");
const Table = amqp.Table;
const ValueWriter = amqp.ValueWriter;
const Frame = fr.Frame;
const Header = Frame.Header;
const FrameType = Frame.FrameType;
const Class = fr.Class;
const body_start = fr.body_start;

const stdout = std.io.getStdOut().writer();
const event_count = 20;

const ConnectionState = struct {
    fd: posix.fd_t,
    num: usize,
    data: []u8,
    status: enum { READING, WRITING },
    fsm_state: FSMState = .None,
    outgoing_queue: std.fifo.LinearFifo(*Frame, .Dynamic),

    const FSMState = enum {
        None,
        ReceivedPH,
        WaitingStartOk,
    };

    const ConnectionError = error{
        WrongState,
    };

    pub fn receive(self: *ConnectionState, _: std.mem.Allocator, frame: Frame) !void {
        std.debug.print("frame incoming with header: {}\n", .{frame.header});
        switch (self.fsm_state) {
            .None => {
                return error.WrongState;
            },
            .ReceivedPH => {
                return error.WrongState;
            },
        }
    }

    pub fn write(self: *ConnectionState, allocator: std.mem.Allocator, tid: usize) !void {
        if (self.outgoing_queue.readableLength() != 0) {
            const frame = self.outgoing_queue.peekItem(0);

            const written = posix.write(self.fd, frame.data[self.num..]) catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        return;
                    },
                    else => {
                        self.outgoing_queue.discard(0);
                        self.status = .READING;
                        self.num = 0;
                        std.log.err("t[{d}]: error in writing header to socket: {}", .{ tid, err });
                        return err;
                    },
                }
            };
            self.num = self.num + written;
            if (self.num == frame.data.len) {
                const frm = self.outgoing_queue.readItem() orelse unreachable;
                frm.deinit(allocator);
                self.status = .READING;
                self.num = 0;
                // transition le state if a connection class frame is being sent
                // otherwise do not.
                if (frm.classId() == Class.Connection.id) {
                    try self.transition(@enumFromInt(frm.methodId()));
                }
                return;
            }
        } else {
            const frm = self.outgoing_queue.readItem() orelse unreachable;
            frm.deinit(allocator);
            self.status = .READING;
            self.num = 0;
            if (frm.classId() == Class.Connection.id) {
                try self.transition(@enumFromInt(frm.methodId()));
            }
            return;
        }
    }

    // used to move state whenever a frame connection-oriented frame is sent through this connection
    // i hate finite state machines
    pub fn transition(self: *ConnectionState, out_method: Class.Connection.Method) !void {
        self.fsm_state = switch (self.fsm_state) {
            .None => return error.WrongState, // receive a protocol header first you moron
            .ReceivedPH => switch (out_method) {
                .start => .WaitingStartOk,
                else => return error.WrongState, // send a connection.start frame you moron
            },
            .WaitingStartOk => return error.WrongState, // receive connection.start-ok you moron
        };
        return void{};
    }

    pub fn read(self: *ConnectionState, allocator: std.mem.Allocator, tid: usize) !void {
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
            if (self.fsm_state == .None) self.fsm_state = .ReceivedPH else {
                return error.WrongState;
            }
            // connection.start method
            // rather unreadable and unmaintainable
            { // frame connection.start start
                var out_frame = try Frame.fromAllocator(allocator, .{
                    .type = .Method,
                    .channel_id = 0,
                    .len = 98,
                });
                out_frame.setMethod(Class.Connection.id, Class.Connection.Method.start.asU16());
                out_frame.data[body_start] = 0;
                out_frame.data[body_start + 1] = 9;
                // could have implemented as a hash table but using it here is kind of overengineering
                var table = Table(.static).init(out_frame.data[body_start + 2 ..]) catch unreachable;
                try table.addStringField("host", "127.0.0.1");
                try table.addStringField("product", "zmq");
                try table.addStringField("platform", "urmom"); // too heavy to maintain i believe
                const table_size = table.writeSize();
                ValueWriter.writeBigString(out_frame.data[body_start + 2 + table_size ..], "PLAIN");
                ValueWriter.writeBigString(out_frame.data[body_start + 2 + table_size + 9 ..], "en_US");
                try self.outgoing_queue.writeItem(out_frame);
            } // frame connection.start end
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
            return self.receive(allocator, frame);
        }
    }

    pub fn reigniteEpoll(self: *ConnectionState, allocator: std.mem.Allocator, ev: *linux.epoll_event, epoll_fd: i32, tid: usize) void {
        ev.events = linux.EPOLL.OUT | linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.ONESHOT;
        ev.data.ptr = @intFromPtr(self);
        posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_MOD, self.fd, ev) catch |err| {
            std.log.err("t[{d}]: error in adding a fd into epoll, closing it: {}", .{ tid, err });
            self.deinit(allocator);
        };
    }
    pub fn deinit(self: *ConnectionState, allocator: std.mem.Allocator) void {
        defer allocator.destroy(self);
        defer self.outgoing_queue.deinit();
        defer allocator.free(self.data);
        posix.close(self.fd);
    }
};

fn processIo(allocator: std.mem.Allocator, epoll_fd: i32, tid: usize, ev: *linux.epoll_event) void {
    const state: *ConnectionState = @ptrFromInt(ev.data.ptr);
    if (ev.events & linux.EPOLL.OUT != 0 and state.status == .WRITING) {
        state.write(allocator, tid) catch return state.deinit(allocator);
        state.reigniteEpoll(allocator, ev, epoll_fd, tid);
    } else if (ev.events & linux.EPOLL.IN != 0 and state.status == .READING) {
        state.read(allocator, tid) catch return state.deinit(allocator);
        state.reigniteEpoll(allocator, ev, epoll_fd, tid);
    } else if (ev.events & linux.EPOLL.OUT != 0 and state.status == .READING) {
        if (state.outgoing_queue.readableLength() > 0) {
            state.status = .WRITING;
            state.num = 0;
            state.write(allocator, tid) catch return state.deinit(allocator);
        }
        state.reigniteEpoll(allocator, ev, epoll_fd, tid);
    } else state.deinit(allocator);
}

fn acceptNew(allocator: std.mem.Allocator, epoll_fd: i32, tid: usize, ev: *const linux.epoll_event) void {
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
    state.outgoing_queue = std.fifo.LinearFifo(*Frame, .Dynamic).init(allocator);
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

pub fn work(allocator: std.mem.Allocator, epoll_fd: i32, listen_fd: i32, tid: usize) void {
    var events: [event_count]linux.epoll_event = undefined;
    while (true) {
        const ev_count = linux.epoll_wait(epoll_fd, &events, event_count, 5);
        for (events[0..ev_count]) |*ev| {
            if (ev.data.fd == listen_fd) {
                acceptNew(allocator, epoll_fd, tid, ev);
            } else {
                processIo(allocator, epoll_fd, tid, ev);
            }
        }
    }
}
