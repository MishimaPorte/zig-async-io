const std = @import("std");

const Allocator = @import("std").mem.Allocator;
const AmqpConnection = @import("connection.zig").AmqpConnection;
const Frame = @import("frame.zig").Frame;
const Class = @import("frame.zig").Class;
const Atomic = @import("std").atomic.Value;
const Tuple = @import("std").meta.Tuple;
const Queue = @import("Queue.zig");

pub const Channel = struct {
    c: *AmqpConnection,
    state: Atomic(ChannelState),

    const ChannelState = enum(u8) {
        Open,
        Closed,
        pub fn asText(self: ChannelState) []const u8 {
            return switch (self) {
                .Open => "Open",
                .Closed => "Closed",
            };
        }
    };

    const ChannelError = error{
        ChannelClosed,
        UnsupportedMethod,
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
                if (frame.awaitClass(Class.Channel.id)) return self.processChannelFrame(allocator, frame);

                std.log.debug("frame incoming into open channel: type '{s}', on state '{s}' on class id {} on method id {}", .{
                    frame.header.type.asText(),
                    self.state.load(.acquire).asText(),
                    frame.classId(),
                    frame.methodId(),
                });
                try frame.log();
                switch (frame.classId()) {
                    Class.Queue.id => {
                        std.log.err("received queue frame: {}", .{frame.methodId()});
                        try self.processQueueFrame(allocator, frame);
                    },
                    Class.Basic.id => return error.WrongState,
                    else => return error.UnsupportedMethod,
                }
                // return error.WrongState;
            },
        }
    }

    fn processQueueFrame(self: *Channel, allocator: Allocator, frame: *const Frame) !void {
        const QueueMethod = Class.Queue.Method;
        switch (frame.methodId()) {
            QueueMethod.declare.asU16() => {
                try Queue.declare(self, allocator, frame);
            },
            QueueMethod.bind.asU16() => return error.WrongState,
            QueueMethod.purge.asU16() => return error.WrongState,
            QueueMethod.delete.asU16() => return error.WrongState,
            QueueMethod.unbind.asU16() => return error.WrongState,

            // all oks are exclusively server-generated
            else => return error.UnsupportedMethod,
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
