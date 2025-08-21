const std = @import("std");
const builtin = @import("builtin");
const discord = @import("discord.zig");
const Bot = @import("Bot.zig");
const Client = @This();

const Connection = std.http.Client.Connection;
const log = std.log.scoped(.client);

gpa: std.mem.Allocator,
client: *std.http.Client,
bot: *Bot,
heartbeat_interval: u64 = 0,
token: []const u8,
user_id: []const u8,
rng: std.Random,
intents: discord.Intents,

last_sequence: ?u64 = null,
session_id: ?[]const u8 = null,
resume_gateway_url: ?[]const u8 = null,

const FrameHeader = packed struct(u16) {
    opcode: enum(u4) {
        continuation = 0x00,
        text = 0x1,
        binary = 0x2,
        close = 0x8,
        ping = 0x9,
        pong = 0xA,
        _,
    },
    rsv: u3,
    last: bool,
    length: enum(u7) {
        zero = 0,
        two = 126,
        eight = 127,
        _,
    },
    masked: bool,
};

const Payload = struct {
    op: Opcode,
    t: ?[]const u8,
    s: ?u64,
    d: std.json.Value,

    const Opcode = enum(u32) {
        dispatch = 0,
        heartbeat = 1,
        identify = 2,
        reconnect = 7,
        invalid_session = 9,
        hello = 10,
        heartbeat_ack = 11,
    };

    // server payloads
    const Hello = struct {
        heartbeat_interval: u64,
    };

    const Ready = struct {
        v: u64,
        user: User,
        guilds: []const Guild,
        session_id: []const u8,
        resume_gateway_url: []const u8,
        application: Application,

        const User = struct {
            id: u64,
            username: []const u8,
        };

        const Guild = struct {
            id: u64,
            unavailable: bool,
        };

        const Application = struct {
            id: u64,
            flags: u64,
        };
    };

    // client payloads
    const Identify = struct {
        op: u64,
        d: struct {
            token: []const u8,
            properties: struct {
                os: []const u8,
                browser: []const u8,
                device: []const u8,
            },
            compress: bool = false,
            large_threshold: u64 = 50,
            intents: u64,
        },
    };

    const Heartbeat = struct {
        op: u64,
        d: ?u64,
    };
};

const Event = enum {
    ready,
    message_create,
    typing_start,

    const map = std.StaticStringMap(Event).initComptime(.{
        .{ "READY", .ready },
        .{ "MESSAGE_CREATE", .message_create },
        .{ "TYPING_START", .typing_start },
    });
};

pub fn run(c: *Client, gr: GatewayResponse) !void {
    const gateway_path = try std.fmt.allocPrint(c.gpa, "{s}/?v=10&encoding=json", .{gr.url});
    defer c.gpa.free(gateway_path);

    var challenge: [20]u8 = undefined;
    std.crypto.random.bytes(&challenge);
    var base64_digest: [28]u8 = undefined;
    std.debug.assert(std.base64.standard.Encoder.encode(&base64_digest, &challenge).len == base64_digest.len);

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try c.client.open(.GET, try .parse(gateway_path), .{
        .version = .@"HTTP/1.1",
        .server_header_buffer = &server_header_buffer,
        .extra_headers = &.{
            .{ .name = "upgrade", .value = "websocket" },
            .{ .name = "connection", .value = "upgrade" },
            .{ .name = "sec-websocket-key", .value = &base64_digest },
            .{ .name = "sec-websocket-version", .value = "13" },
        },
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    if (req.response.status != .switching_protocols) return error.Unexpected;
    const connection = req.connection.?;
    const reader = connection.reader();

    var payload_buffer: [64 * 1024]u8 = undefined;

    loop: while (true) {
        // read enough for the header
        var hdr: [2]u8 = undefined;
        _ = try reader.readAll(&hdr);
        const header: FrameHeader = @bitCast(hdr);
        if (!header.last) @panic("TODO");
        if (header.rsv != 0) @panic("TODO");

        const length = switch (header.length) {
            inline .two, .eight => |t| try reader.readInt(if (t == .two) u16 else u64, .big),
            .zero => @panic("TODO"),
            _ => switch (header.opcode) {
                .text => @intFromEnum(header.length),
                .close => {
                    std.debug.assert(@intFromEnum(header.length) == 2);
                    const reason = try reader.readInt(u16, .big);
                    std.debug.print("closing reason: {d}\n", .{reason});
                    return error.Closed;
                },
                else => |t| std.debug.panic("TODO: {s}", .{@tagName(t)}),
            },
        };
        const bytes = try reader.readAll(payload_buffer[0..length]);
        std.debug.assert(bytes == length);
        const payload = payload_buffer[0..length];

        const parsed = try std.json.parseFromSlice(
            Payload,
            c.gpa,
            payload,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        switch (parsed.value.op) {
            .hello => {
                const heartbeat_object = parsed.value.d.object.get("heartbeat_interval").?;
                const heartbeat_interval: u64 = @intCast(heartbeat_object.integer);
                c.heartbeat_interval = heartbeat_interval;
                log.info("setting interval: {d}", .{heartbeat_interval});

                try c.heartbeat(connection);
                try c.identify(connection);
            },
            .heartbeat => try c.heartbeat(connection),
            .heartbeat_ack => {
                std.debug.print("TODO: record heartbeat ack and timeout if needed\n", .{});
            },
            .dispatch => {
                c.last_sequence = parsed.value.s.?;
                const event = Event.map.get(parsed.value.t.?) orelse {
                    log.warn("unknown dispatch command {s}", .{parsed.value.t.?});
                    continue :loop;
                };
                log.info("dispatch command: {s}", .{@tagName(event)});
                switch (event) {
                    .ready => {
                        const ready_object = try std.json.parseFromValue(
                            Payload.Ready,
                            c.gpa,
                            parsed.value.d,
                            .{ .ignore_unknown_fields = true },
                        );
                        defer ready_object.deinit();

                        if (ready_object.value.v != 10) return error.UnsupportedGatewayVersion;

                        if (c.session_id != null or c.resume_gateway_url != null) continue :loop; // already set
                        c.session_id = try c.gpa.dupe(u8, ready_object.value.session_id);
                        c.resume_gateway_url = try c.gpa.dupe(u8, ready_object.value.resume_gateway_url);
                    },
                    .message_create => {
                        const create_object = try std.json.parseFromValue(
                            discord.MessageCreate,
                            c.gpa,
                            parsed.value.d,
                            .{ .ignore_unknown_fields = true },
                        );
                        defer create_object.deinit();

                        const content = create_object.value.content;
                        if (std.mem.startsWith(u8, content, "%s")) {
                            try c.bot.run(c, create_object.value);
                        }
                    },
                    .typing_start => {}, // nothing for us to do
                }
            },
            else => |t| std.debug.panic("TODO: {s}", .{@tagName(t)}),
        }
    }
}

pub fn heartbeat(c: *Client, conn: *Connection) !void {
    const payload: Payload.Heartbeat = .{
        .op = 1,
        .d = c.last_sequence,
    };
    try c.sendWebSocketMessage(conn, payload);
}

fn identify(c: *Client, conn: *Connection) !void {
    const payload: Payload.Identify = .{
        .op = 2,
        .d = .{
            .token = c.token,
            .intents = @as(u26, @bitCast(c.intents)),
            .properties = .{
                .os = @tagName(builtin.os.tag),
                .browser = c.user_id,
                .device = c.user_id,
            },
        },
    };
    try c.sendWebSocketMessage(conn, payload);
}

fn sendWebSocketMessage(c: *Client, conn: *Connection, value: anytype) !void {
    const encoded = try std.json.stringifyAlloc(c.gpa, value, .{});
    defer c.gpa.free(encoded);

    log.debug("sending: {s}", .{encoded});

    const header: FrameHeader = .{
        .opcode = .text,
        .rsv = 0,
        .last = true, // see TODO below
        .masked = true,
        .length = switch (encoded.len) {
            0...125 => @enumFromInt(encoded.len),
            126...65535 => .two,
            else => @panic("TODO"),
        },
    };

    var mask: [4]u8 = undefined;
    c.rng.bytes(&mask);
    for (encoded, 0..) |*byte, i| {
        byte.* ^= mask[i % 4];
    }

    const writer = conn.writer();
    try writer.writeStruct(header);
    switch (header.length) {
        inline .two, .eight => |t| try writer.writeInt(
            if (t == .two) u16 else u64,
            @intCast(encoded.len),
            .big,
        ),
        else => {},
    }
    try writer.writeAll(&mask);
    try writer.writeAll(encoded);
    try conn.flush();
}

pub fn chat(
    c: *Client,
    channel_id: []const u8,
    maybe_message_id: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const url = try std.fmt.allocPrint(
        c.gpa,
        "https://discord.com/api/v10/channels/{s}/messages",
        .{channel_id},
    );
    defer c.gpa.free(url);

    const send: discord.MessageSend = .{
        .content = try std.fmt.allocPrint(c.gpa, fmt, args),
        .message_reference = if (maybe_message_id) |message_id| .{
            .message_id = message_id,
        } else null,
    };

    const encoded = try std.json.stringifyAlloc(c.gpa, send, .{});
    defer c.gpa.free(encoded);

    const response = try c.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = c.token },
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .payload = encoded,
    });
    if (response.status != .ok) return error.FailedToSendMessage;
}

const GatewayResponse = struct {
    url: []const u8,
    session_start_limit: Limit,
    shards: u32,

    const Limit = struct {
        max_concurrency: u32,
        remaining: u32,
        reset_after: u32,
        total: u32,
    };
};

pub fn getGateway(c: *Client) !GatewayResponse {
    var response: std.ArrayList(u8) = .init(c.gpa);
    defer response.deinit();
    const status = try c.client.fetch(.{
        .location = .{ .url = "https://discord.com/api/v10/gateway/bot" },
        .extra_headers = &.{.{ .name = "Authorization", .value = c.token }},
        .response_storage = .{ .dynamic = &response },
    });
    if (status.status != .ok) return error.FailedToGetGateway;

    const parsed = try std.json.parseFromSliceLeaky(
        GatewayResponse,
        c.gpa,
        response.items,
        .{ .allocate = .alloc_always },
    );

    log.info("got gateway at: {s}", .{parsed.url});
    log.debug("gateway object: {}", .{parsed});

    return parsed;
}
