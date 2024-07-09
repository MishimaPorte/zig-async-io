const std = @import("std");
const linux = std.os.linux;
const net = std.net;
const posix = std.posix;
const Atomic = @import("std").atomic.Value;
const Mutex = @import("std").Thread.Mutex;

const Table = @import("amqp_encoding.zig").Table;
const TableParser = @import("amqp_encoding.zig").TableParser;
const Value = @import("amqp_encoding.zig").Value;

const Frame = @import("frame.zig").Frame;
const Header = @import("frame.zig").Frame.Header;
const FrameType = @import("frame.zig").Frame.FrameType;
const Class = @import("frame.zig").Class;
const body_start = @import("frame.zig").body_start;

const Channel = @import("channel.zig").Channel;

const stdout = std.io.getStdOut().writer();
const event_count = 20;

fn Connection(
    comptime max_channels: usize,
    comptime max_frame_size: usize,
    comptime heartbeat_delay: usize,
) type {
    return struct {
        fd: posix.fd_t,
        num: usize,
        data: []u8,
        fd_status: enum { reading, writing },
        state: ConnectionState = .None,
        out_q: std.fifo.LinearFifo(*Frame, .Dynamic),

        /// password that was used for authorization for connection
        password: []u8,
        /// login that was used for authorization for this connection
        login: []u8,
        /// virtual host that the client negotiated for this connection
        vhost: []u8,
        channels: [max_channels]Channel,
        const ChannelBitmap = std.PackedIntArray(u1, max_channels);
        const Conn = @This();
        const ConnectionState = enum {
            None,
            ReceivedPH,
            WaitingStartOk,
            StartOkReceived,
            WaitingTuneOk,
            WaitingOpen,
            OpenReceived,
            OPEN,
        };

        const ConnectionError = error{
            WrongState,
            TooManyChannels,
            InvalidChannelId,
        };

        pub fn receive(self: *Conn, allocator: std.mem.Allocator, frame: *const Frame) !void {
            std.log.debug("frame incoming with header: {} on state {} on class id {} on method id {}", .{ frame.header, self.state, frame.classId(), frame.methodId() });
            self.state = switch (self.state) {
                // connection class is fully synchronous, so all the frames must come in order.
                // state management is trivial in this case.
                .None => return error.WrongState,
                .ReceivedPH => return error.WrongState,
                .StartOkReceived => return error.WrongState,
                .OpenReceived => return error.WrongState,
                .WaitingStartOk => if (frame.awaitMethod(
                    Class.Connection.id,
                    Class.Connection.Method.start_ok.asU16(),
                )) b: {
                    self.startOk(allocator, frame) catch |err| return err;
                    try self.sendTune(allocator);
                    break :b .StartOkReceived;
                } else return error.WrongState,
                .WaitingTuneOk => if (frame.awaitMethod(
                    Class.Connection.id,
                    Class.Connection.Method.tune_ok.asU16(),
                )) b: {
                    try self.tuneOk(frame);
                    break :b .WaitingOpen;
                } else return error.WrongState,
                .WaitingOpen => if (frame.awaitMethod(
                    Class.Connection.id,
                    Class.Connection.Method.open.asU16(),
                )) b: {
                    const vhost = try Value.Read.shortString(frame.bodyOffset(0));
                    if (frame.data.len != body_start + vhost.len + 3) return error.NotEnoughBytes;
                    self.vhost = try allocator.alloc(u8, vhost.len);
                    @memcpy(self.vhost, vhost);
                    std.log.info("connection vhost: '{s}'", .{self.vhost});
                    try self.sendOpenOk(allocator);
                    break :b .OpenReceived;
                } else return error.WrongState,
                .OPEN => if (frame.awaitClass(Class.Connection.id)) {
                    @panic("not implemented");
                } else return self.handleSubConnectionFrame(allocator, frame),
            };
        }

        fn getFreeChid(self: *Conn) !u16 {
            self.channel_bitmap_mutex.lock();
            defer self.channel_bitmap_mutex.unlock();
            for (0..self.channel_bitmap.len) |i| {
                if (self.channel_bitmap.get(i) == 0) {
                    self.channel_bitmap.set(i, 1);
                    return i;
                }
            }
            return error.TooManyChannels;
        }

        fn handleSubConnectionFrame(self: *Conn, allocator: std.mem.Allocator, frame: *const Frame) !void {
            if (frame.header.channel_id > max_channels) return error.InvalidChannelId;
            try self.channels[frame.header.channel_id - 1].processFrame(allocator, frame);
        }

        fn sendOpenOk(self: *Conn, allocator: std.mem.Allocator) !void {
            var frame = try Frame.fromAllocator(allocator, .{
                .type = FrameType.Method,
                .len = 5,
                .channel_id = 0,
            });
            frame.setMethod(Class.Connection.id, Class.Connection.Method.open_ok.asU16());
            frame.data[body_start] = 0;
            try self.out_q.writeItem(frame);
        }

        fn sendTune(self: *Conn, allocator: std.mem.Allocator) !void {
            var frame = try Frame.fromAllocator(allocator, .{
                .type = FrameType.Method,
                .len = 12,
                .channel_id = 0,
            });
            frame.setMethod(Class.Connection.id, Class.Connection.Method.tune.asU16());
            std.mem.writeInt(u16, frame.bodyArrayPtr(0, 2), comptime max_channels, .big);
            std.mem.writeInt(u32, frame.bodyArrayPtr(2, 4), comptime max_frame_size, .big);
            std.mem.writeInt(u16, frame.bodyArrayPtr(6, 2), comptime heartbeat_delay, .big);
            try self.out_q.writeItem(frame);
        }

        fn tuneOk(_: *Conn, frame: *const Frame) !void {
            const chan_max = std.mem.readInt(u16, frame.bodyArrayPtr(0, 2), .big);
            const frame_max = std.mem.readInt(u32, frame.bodyArrayPtr(2, 4), .big);
            const heartbeat = std.mem.readInt(u16, frame.bodyArrayPtr(6, 2), .big);
            std.log.info("tuned: {d} chan max, {d} frame max and {d} heartbeat", .{ chan_max, frame_max, heartbeat });
            return;
        }

        fn startOk(self: *Conn, allocator: std.mem.Allocator, frame: *const Frame) !void {
            const parser: TableParser = TableParser.init(frame.bodyOffset(0));
            const table_len = parser.buf.len + 4;

            const mech = try Value.Read.shortString(frame.bodyOffset(table_len));
            const resp = try Value.Read.bigString(frame.bodyOffset(table_len + 1 + mech.len));
            try self.parseAuthResponse(allocator, resp);
            _ = try Value.Read.shortString(frame.bodyOffset(table_len + 5 + mech.len + resp.len));
            std.log.info("authenticated with creads: login '{s}' and password '{s}'", .{ self.login, self.password });
            return;
        }

        const AuthErrors = error{
            BadAuthResponse,
        };
        fn parseAuthResponse(self: *Conn, allocator: std.mem.Allocator, resp: []u8) !void {
            if (resp[0] != 0) return error.BadAuthResponse;
            const name = std.mem.span(@as([*:0]u8, @ptrCast(resp[1..].ptr)));
            self.login = try allocator.alloc(u8, name.len);
            @memcpy(self.login, resp[1 .. name.len + 1]);
            self.password = try allocator.alloc(u8, resp.len - 2 - name.len);
            @memcpy(self.password, resp[2 + name.len ..]);
        }

        pub fn write(self: *Conn, allocator: std.mem.Allocator, tid: usize) !void {
            if (self.out_q.readableLength() > 0) {
                const frame = self.out_q.peekItem(0);
                const written = posix.write(self.fd, frame.data[self.num..]) catch |err| {
                    switch (err) {
                        error.WouldBlock => {
                            return;
                        },
                        else => {
                            self.out_q.discard(0);
                            self.fd_status = .reading;
                            self.num = 0;
                            std.log.err("t[{d}]: error in writing header to socket: {}", .{ tid, err });
                            return err;
                        },
                    }
                };
                self.num = self.num + written;
                if (self.num == frame.data.len) {
                    const frm = self.out_q.readItem() orelse unreachable;
                    std.log.debug("emitted a frame: {}", .{frm.header});
                    if (frm.classId() == Class.Connection.id) {
                        try self.transition(@enumFromInt(frm.methodId()));
                    }
                    frm.deinit(allocator);
                    self.fd_status = .reading;
                    self.num = 0;
                    // transition le state if a connection class frame is being sent
                    // otherwise do not.
                    return;
                }
            } else { //do nothing i guess if the output queue is empty?..
                self.fd_status = .writing;
                self.num = 0;
            }
        }

        // used to move state whenever a frame connection-oriented frame is sent through this connection
        // i hate finite state machines
        fn transition(self: *Conn, out_method: Class.Connection.Method) !void {
            errdefer std.log.warn("state transition badness", .{});
            self.state = switch (self.state) {
                .None => return error.WrongState, // receive a protocol header first you moron
                .ReceivedPH => switch (out_method) {
                    .start => .WaitingStartOk,
                    else => return error.WrongState, // send a connection.start frame you moron
                },
                .WaitingStartOk => return error.WrongState, // receive connection.start-ok you moron
                .StartOkReceived => switch (out_method) {
                    .tune => .WaitingTuneOk,
                    else => return error.WrongState, // send a connection.tune frame you moron
                },
                .WaitingTuneOk => return error.WrongState,
                .WaitingOpen => return error.WrongState,
                .OpenReceived => switch (out_method) {
                    .open_ok => .OPEN,
                    else => return error.WrongState, // send a connection.open-ok frame you moron
                },
                .OPEN => @panic("not implemented"),
            };
            return void{};
        }

        fn sendConnectionStart(self: *Conn, allocator: std.mem.Allocator) !void {
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
            Value.Write.bigString(out_frame.data[body_start + 2 + table_size ..], "PLAIN");
            Value.Write.bigString(out_frame.data[body_start + 2 + table_size + 9 ..], "en_US");
            try self.out_q.writeItem(out_frame);
        }

        pub fn read(self: *Conn, allocator: std.mem.Allocator, tid: usize) !void {
            const len = posix.read(self.fd, self.data[self.num..]) catch |err| switch (err) {
                error.WouldBlock => {
                    self.fd_status = .writing;
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
                std.log.debug("t[{d}]: protocol header accepted!: \"{s}\"", .{ tid, self.data[0..8] });
                if (self.state == .None) self.state = .ReceivedPH else {
                    return error.WrongState;
                }
                try self.sendConnectionStart(allocator);
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
                return self.receive(allocator, &frame);
            }
        }

        pub fn reigniteEpoll(self: *Conn, allocator: std.mem.Allocator, epoll_fd: i32, tid: usize) void {
            var ev: linux.epoll_event = .{
                .data = .{ .ptr = @intFromPtr(self) },
                .events = linux.EPOLL.OUT | linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.ONESHOT,
            };
            posix.epoll_ctl(
                epoll_fd,
                linux.EPOLL.CTL_MOD,
                self.fd,
                &ev,
            ) catch |err| {
                std.log.err("t[{d}]: error in adding a fd into epoll, closing it: {}", .{ tid, err });
                self.deinit(allocator);
            };
        }

        // this is a thinnest possible writer to declare and interface with
        pub inline fn sendFrame(self: *Conn, frame: *Frame) !void {
            try self.out_q.writeItem(frame);
        }

        pub fn deinit(self: *Conn, allocator: std.mem.Allocator) void {
            std.log.warn("deallocating a connection", .{});
            while (self.out_q.readItem()) |item| {
                item.deinit(allocator);
            }
            self.out_q.deinit();
            allocator.free(self.data);
            allocator.free(self.login);
            allocator.free(self.password);
            allocator.free(self.vhost);
            posix.close(self.fd);
            allocator.destroy(self);
        }
    };
}
const build_config = @import("build_config");
pub const AmqpConnection = Connection(
    build_config.max_channels_per_connection,
    build_config.max_frame_size,
    build_config.heartbeat_rate,
);

// refactor this into a more generic control loop, decoupling connection frame ingesting mechanism
// from posix read calls and epoll and overall socket thing.
// AmqpConnection should have like a method "processFrame" and thats it  TODO:
fn processIo(allocator: std.mem.Allocator, epoll_fd: i32, tid: usize, ev: linux.epoll_event) void {
    const state: *AmqpConnection = @ptrFromInt(ev.data.ptr);

    if (ev.events & linux.EPOLL.OUT != 0 and state.fd_status == .writing) {
        state.write(allocator, tid) catch return state.deinit(allocator);
        state.reigniteEpoll(allocator, epoll_fd, tid);
    } else if (ev.events & linux.EPOLL.IN != 0 and state.fd_status == .reading) {
        state.read(allocator, tid) catch return state.deinit(allocator);
        state.reigniteEpoll(allocator, epoll_fd, tid);
    } else if (ev.events & linux.EPOLL.OUT != 0 and state.fd_status == .reading) {
        if (state.out_q.readableLength() > 0) {
            state.fd_status = .writing;
            state.num = 0;
            state.write(allocator, tid) catch return state.deinit(allocator);
        }
        state.reigniteEpoll(allocator, epoll_fd, tid);
    } else state.deinit(allocator);
}

fn acceptNew(allocator: std.mem.Allocator, epoll_fd: i32, tid: usize, ev: linux.epoll_event) void {
    var remote: net.Address = undefined;
    var addr_len: linux.socklen_t = @sizeOf(net.Address);

    const flags = posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const fd = posix.accept(ev.data.fd, &remote.any, &addr_len, flags) catch |err| {
        std.log.err("t[{d}]: error in accepting: {}", .{ tid, err });
        return;
    };
    const state = allocator.create(AmqpConnection) catch |err| {
        std.log.err("t[{d}]: failed to allocate fd state: {}", .{ tid, err });
        return;
    };
    state.num = 0;
    state.state = .None;
    state.fd_status = .reading;
    state.fd = fd;
    @memset(&state.channels, Channel{
        .state = .{ .raw = .Closed },
        .c = state,
    });
    state.out_q = std.fifo.LinearFifo(*Frame, .Dynamic).init(allocator);
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
        const ev_count = linux.epoll_wait(epoll_fd, &events, event_count, 1);
        for (events[0..ev_count]) |ev| {
            if (ev.data.fd == listen_fd) {
                acceptNew(allocator, epoll_fd, tid, ev);
            } else {
                processIo(allocator, epoll_fd, tid, ev);
            }
        }
    }
}
