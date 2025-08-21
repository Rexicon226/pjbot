const std = @import("std");
const builtin = @import("builtin");
const Client = @import("Client.zig");
const Bot = @import("Bot.zig");

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
};
pub const version = std.SemanticVersion.parse("0.1.0") catch unreachable;

const Config = struct {
    api_token: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();
    const config_path = args.next() orelse usage();
    const config = try parseConfig(config_path, allocator);

    var bot: Bot = .{
        .gpa = allocator,
        .tag_db = .empty,
    };
    defer bot.deinit();

    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    var rng: std.Random.DefaultPrng = .init(10);

    var client: Client = .{
        .gpa = allocator,
        .bot = &bot,
        .client = &http_client,
        .rng = rng.random(),
        .token = config.api_token,
        .user_id = "pjbot/0.1",
        .intents = .{
            .guilds = true,
            .guild_messages = true,
            .message_content = true,
        },
    };

    const gateway_response = try client.getGateway();
    while (true) {
        client.run(gateway_response) catch |err| switch (err) {
            error.Closed => break,
            else => return err,
        };
    }

    std.debug.print("closing\n", .{});
}

fn parseConfig(path: []const u8, allocator: std.mem.Allocator) !Config {
    const contents = try std.fs.cwd().readFileAllocOptions(
        allocator,
        path,
        1024,
        null,
        @alignOf(u8),
        0,
    );
    defer allocator.free(contents);
    return try std.zon.parse.fromSlice(Config, allocator, contents, null, .{});
}

fn usage() noreturn {
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll(
        \\Usage: 
        \\  ./bot config.zon
        \\
    ) catch @panic("failed to print usage");
    std.posix.exit(1);
}
