const std = @import("std");
// Method start body constant =
// frame type byte + 2 bytes of channel id +
// 4 size bytes + 2 bytes for class id and
// 2 bytes of method id
pub const body_start = 1 + 2 + 4 + 2 + 2;

pub const Class = struct {
    pub const Connection = struct {
        pub const id = 10;
        pub const start = 10;
        pub const start_ok = 11;
        pub const secure = 20;
        pub const secure_ok = 21;
        pub const tune = 30;
        pub const tune_ok = 31;
        pub const open = 40;
        pub const open_ok = 41;
        pub const close = 50;
        pub const close_ok = 51;
    };
    pub const Channel = struct {
        pub const id = 20;
        pub const open = 10;
        pub const open_ok = 11;
        pub const flow = 20;
        pub const flow_ok = 21;
        pub const close = 40;
        pub const close_ok = 41;
    };
    pub const Queue = struct {
        pub const id = 50;
        pub const declare = 10;
        pub const declare_ok = 11;
        pub const bind = 20;
        pub const bind_ok = 21;
        pub const purge = 30;
        pub const purge_ok = 31;
        pub const delete = 40;
        pub const delete_ok = 41;
        pub const unbind = 50;
        pub const unbind_ok = 51;
    };
    pub const Basic = struct {
        pub const id = 60;
        pub const qos = 10;
        pub const qos_ok = 11;
        pub const consume = 20;
        pub const consume_ok = 21;
        pub const cancel = 30;
        pub const cancel_ok = 31;
        pub const publish = 40;
        pub const return_ = 50;
        pub const deliver = 60;
        pub const get = 70;
        pub const get_ok = 71;
        pub const get_empty = 72;
        pub const ack = 80;
        pub const reject = 90;
        pub const recover_async = 100;
        pub const recover = 110;
        pub const recover_ok = 111;
    };
};

pub const Frame = struct {
    //actual frame data, no header and endframe octet
    data: []u8,
    header: Header,

    const Header = struct {
        type: enum(u8) {
            ProtocolHeader = 0,
            Method = 1,
            Header = 2,
            Body = 3,
            Heartbeat = 4,
            Err = 5,
            pub fn asU8(self: @This()) u8 {
                return @intFromEnum(self);
            }
        },
        channel_id: u16,
        len: u32,
    };
    pub const ParseError = error{
        EndFrameOctetMissing,
        NotEnoughBytes,
    };
    pub const EndFrameOctet: u8 = '\xce';

    pub fn setMethod(self: *Frame, class_id: u16, method_id: u16) void {
        std.debug.assert(self.header.type == .Method);
        std.debug.assert(self.header.len > 4);
        std.mem.writeInt(u16, @ptrCast(self.data[7..].ptr), class_id, .big); //channel id
        std.mem.writeInt(u16, @ptrCast(self.data[9..].ptr), method_id, .big); //channel id
    }

    pub fn methodId(self: Frame) u16 {
        std.debug.assert(self.header.type == .Method);
        std.debug.assert(self.header.len > 4);
        std.mem.readInt(u16, @ptrCast(self.data[7..].ptr), .big);
    }
    pub fn classId(self: Frame) u16 {
        std.debug.assert(self.header.type == .Method);
        std.debug.assert(self.header.len > 4);
        std.mem.readInt(u16, @ptrCast(self.data[9..].ptr), .big);
    }

    pub fn fromHeader(allocator: *std.mem.Allocator, header: Header) !Frame {
        var mem = try allocator.alloc(u8, header.len + 8);
        mem[mem.len - 1] = EndFrameOctet;
        mem[0] = header.type.asU8();
        std.mem.writeInt(u16, @ptrCast(mem.ptr), 0, .big); //channel id
        std.mem.writeInt(u32, @ptrCast(mem[3..].ptr), header.len, .big); //size
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
            .channel_id = std.mem.readInt(u16, @ptrCast(data[1..3].ptr), .big),
            .len = std.mem.readInt(u32, @ptrCast(data[3..7].ptr), .big),
        };

        if (header.len + 8 <= data.len) {
            if (data[header.len + 7] != EndFrameOctet) return error.EndFrameOctetMissing;
            return .{
                .data = data[8..header.len],
                .header = header,
            };
        } else return error.NotEnoughBytes;
    }
};
