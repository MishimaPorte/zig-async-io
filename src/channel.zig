const Allocator = @import("std").mem.Allocator;
const AmqpConnection = @import("connection.zig").AmqpConnection;
const Frame = @import("frame.zig").Frame;
const Class = @import("frame.zig").Class;
const Atomic = @import("std").atomic.Value;
const Tuple = @import("std").meta.Tuple;

pub const Channel = struct {
    c: *const AmqpConnection,
    state: Atomic(ChannelState),
    await_sending: packed struct(u32) {
        cid: u16,
        mid: u16,
    },

    const ChannelState = enum(u8) {
        Preopen,
        Open,
        Closed,
        Cancelled,
    };

    pub fn processFrame(self: *Channel, allocator: Allocator, frame: *const Frame) !void {
        switch (self.state.load(.release)) {
            .Preopen => if (frame.awaitMethod(Class.Channel.id, Class.Channel.Method.open.asU16())) {
                try self.open(allocator, frame);
            } else return error.WrongState,
            .Open => return error.WrongState,
            .Closed => return error.WrongState,
            .Cancelled => return error.WrongState,
        }
        self.c.sendFrame(frame);
    }

    fn open(self: *Channel, allocator: Allocator, frame: *const Frame) !void {
        const resp = try Frame.fromAllocator(allocator, .{
            .channel_id = frame.header.channel_id,
            .len = 8,
            .type = .Method,
        });
        frame.setMethod(Class.Channel.id, Class.Channel.Method.open_ok.asU16());
        self.c.sendFrame(resp);
        self.state.store(.Open, .acquire);
    }
};
