const std = @import("std");
// Method start body constant =
// frame type byte + 2 bytes of channel id +
// 4 size bytes + 2 bytes for class id and
// 2 bytes of method id
pub const body_start = 1 + 2 + 4 + 2 + 2;
const Tuple = @import("std").meta.Tuple;

pub const Class = struct {
    pub const Connection = struct {
        pub const id: u16 = 10;
        pub const Method = enum(u16) {
            start = 10,
            start_ok = 11,
            secure = 20,
            secure_ok = 21,
            tune = 30,
            tune_ok = 31,
            open = 40,
            open_ok = 41,
            close = 50,
            close_ok = 51,
            pub fn asU16(self: @This()) u16 {
                return @intFromEnum(self);
            }
        };
    };
    pub const Channel = struct {
        pub const id: u16 = 20;
        pub const Method = enum(u16) {
            open = 10,
            open_ok = 11,
            flow = 20,
            flow_ok = 21,
            close = 40,
            close_ok = 41,
            pub fn asU16(comptime self: @This()) u16 {
                return @intFromEnum(self);
            }
        };
    };
    pub const Queue = struct {
        pub const id: u16 = 50;
        pub const Method = enum(u16) {
            declare = 10,
            declare_ok = 11,
            bind = 20,
            bind_ok = 21,
            purge = 30,
            purge_ok = 31,
            delete = 40,
            delete_ok = 41,
            unbind = 50,
            unbind_ok = 51,
            pub fn asU16(self: @This()) u16 {
                return @intFromEnum(self);
            }
        };
    };
    pub const Basic = struct {
        pub const id: u16 = 60;
        pub const Method = enum(u16) {
            qos = 10,
            qos_ok = 11,
            consume = 20,
            consume_ok = 21,
            cancel = 30,
            cancel_ok = 31,
            publish = 40,
            return_ = 50,
            deliver = 60,
            get = 70,
            get_ok = 71,
            get_empty = 72,
            ack = 80,
            reject = 90,
            recover_async = 100,
            recover = 110,
            recover_ok = 111,
            pub fn asU16(self: @This()) u16 {
                return @intFromEnum(self);
            }
        };
    };
};

pub const Frame = struct {
    //actual frame data, no header and endframe octet
    data: []u8,
    header: Header,
    pub const FrameType = enum(u8) {
        ProtocolHeader = 0,
        Method = 1,
        Header = 2,
        Body = 3,
        Heartbeat = 4,
        Err = 5,
        pub fn asU8(self: @This()) u8 {
            return @intFromEnum(self);
        }
    };
    pub const Header = struct {
        type: FrameType,
        channel_id: u16,
        len: u32,
    };
    pub const ParseError = error{
        EndFrameOctetMissing,
        NotEnoughBytes,
    };
    pub const EndFrameOctet: u8 = '\xce';

    pub fn bodyOffset(self: *const Frame, num: usize) []u8 {
        return self.data[body_start + num ..];
    }

    pub fn bodyOffsetPtr(self: *const Frame, num: usize) [*]u8 {
        return self.data[body_start + num ..].ptr;
    }

    pub fn bodyArrayPtr(self: *const Frame, comptime offset: usize, comptime size: usize) *[size]u8 {
        return @ptrCast(self.data[comptime body_start + offset..]);
    }

    pub fn setMethod(self: *Frame, class_id: u16, method_id: u16) void {
        std.debug.assert(self.header.type == .Method);
        std.debug.assert(self.header.len > 4);
        std.mem.writeInt(u16, @ptrCast(self.data[7..].ptr), class_id, .big); //channel id
        std.mem.writeInt(u16, @ptrCast(self.data[9..].ptr), method_id, .big); //channel id
    }

    pub fn classId(self: Frame) u16 {
        std.debug.assert(self.header.type == .Method);
        std.debug.assert(self.header.len > 4);
        return std.mem.readInt(u16, @ptrCast(self.data[7..9].ptr), .big);
    }

    pub fn methodId(self: Frame) u16 {
        std.debug.assert(self.header.type == .Method);
        std.debug.assert(self.header.len > 4);
        return std.mem.readVarInt(u16, self.data[9..11], .big);
    }

    pub fn fromHeader(allocator: *std.mem.Allocator, header: Header) !Frame {
        var mem = try allocator.alloc(u8, header.len + 8);
        mem[mem.len - 1] = EndFrameOctet;
        mem[0] = header.type.asU8();
        std.mem.writeInt(u16, @ptrCast(mem.ptr), 0, .big); //channel id
        std.mem.writeInt(u32, @ptrCast(mem[3..].ptr), header.len, .big); //size
    }

    pub fn awaitMethod(self: *const Frame, comptime class_id: u16, comptime meth_id: u16) bool {
        switch (self.header.type) {
            .Method => switch (self.classId()) {
                class_id => switch (self.methodId()) {
                    meth_id => return true,
                    else => return false,
                },
                else => return false,
            },
            else => return false, // returning wrong state everywhere is bad but not that bad
        }
    }

    pub fn awaitClass(self: *const Frame, comptime class_id: u16) bool {
        switch (self.header.type) {
            .Method => switch (self.classId()) {
                class_id => return true,
                else => return false,
            },
            else => return false, // returning wrong state everywhere is bad but not that bad
        }
    }

    pub fn fromAllocator(allocator: std.mem.Allocator, header: Header) !*Frame {
        var frame = try allocator.create(Frame);
        frame.header = header;
        const buf = try allocator.alloc(u8, header.len + 8);
        buf[buf.len - 1] = EndFrameOctet;
        buf[0] = header.type.asU8();
        std.mem.writeInt(u16, @ptrCast(buf[1..].ptr), header.channel_id, .big); //channel id
        std.mem.writeInt(u32, @ptrCast(buf[3..].ptr), header.len, .big); //size
        frame.data = buf;
        return frame;
    }

    // use only in allocator-allocated frames;
    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }

    pub fn fromHeaderAndByteSlice(header: Header, buf: []u8) !Frame {
        buf[buf.len - 1] = EndFrameOctet;
        buf[0] = header.type.asU8();
        std.mem.writeInt(u16, @ptrCast(buf.ptr), 0, .big); //channel id
        std.mem.writeInt(u32, @ptrCast(buf[3..].ptr), header.len, .big); //size
        return Frame{
            .header = header,
            .data = buf,
        };
    }

    pub fn fromByteSlice(data: []u8) ParseError!Frame {
        const header = Header{
            .type = @enumFromInt(data[0]),
            .channel_id = std.mem.readVarInt(u16, data[1..3], .big),
            .len = std.mem.readVarInt(u32, data[3..7], .big),
        };

        if (header.len + 8 <= data.len) {
            if (data[header.len + 7] != EndFrameOctet) return error.EndFrameOctetMissing;
            return .{
                .data = data[0 .. header.len + 7],
                .header = header,
            };
        } else return error.NotEnoughBytes;
    }
};
