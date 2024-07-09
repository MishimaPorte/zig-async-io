const std = @import("std");

const Allocator = @import("std").mem.Allocator;
const AmqpConnection = @import("connection.zig").AmqpConnection;
const Frame = @import("frame.zig").Frame;
const Class = @import("frame.zig").Class;
const Atomic = @import("std").atomic.Value;
const Tuple = @import("std").meta.Tuple;

pub const Channel = struct {
    c: *AmqpConnection,
    state: Atomic(ChannelState),

    const ChannelState = enum(u8) {
        Open,
        Closed,
    };

    const ChannelError = error{
        ChannelClosed,
    };

    fn processChannelFrame(_: *Channel, _: Allocator, frame: *const Frame) !void {
        switch (@as(Class.Channel.Method, @enumFromInt(frame.methodId()))) {
            else => {
                std.debug.print("incoming channel frame: {any}\n", .{frame});
            },
        }
    }

    pub fn processFrame(self: *Channel, allocator: Allocator, frame: *const Frame) !void {
        switch (self.state.load(.acquire)) {
            .Closed => if (frame.awaitMethod(Class.Channel.id, Class.Channel.Method.open.asU16())) {
                try self.open(allocator, frame);
            } else return error.ChannelClosed,
            .Open => {
                if (frame.awaitClass(Class.Channel.id)) try self.processChannelFrame(allocator, frame);
                std.debug.print("frame incoming into an open channel: {any}\n", .{frame});
                // return error.WrongState;
            },
        }
    }

    fn open(self: *Channel, allocator: Allocator, frame: *const Frame) !void {
        const resp = try Frame.fromAllocator(allocator, .{
            .channel_id = frame.header.channel_id,
            .len = 8,
            .type = .Method,
        });
        resp.setMethod(Class.Channel.id, Class.Channel.Method.open_ok.asU16());
        try self.c.sendFrame(resp);
        self.state.store(.Open, .release);
    }
};
