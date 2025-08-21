const std = @import("std");
const Client = @import("Client.zig");
const TagDb = @import("TagDb.zig");
const discord = @import("discord.zig");
const root = @import("main.zig");
const Bot = @This();

gpa: std.mem.Allocator,
tag_db: TagDb,

const Commands = enum {
    help,
    version,
    tag,
};

const TagCommands = enum {
    add,
    owner,
};

const usage =
    \\Sinon's Great Bot (or something)
    \\
    \\Prefix with `%s` for commands.
    \\
    \\  help - replies with this usage text
    \\  version - prints the version of the bot
    \\
;

pub fn deinit(b: *Bot) void {
    const allocator = b.gpa;
    b.tag_db.deinit(allocator);
}

pub fn run(b: *Bot, c: *Client, object: discord.MessageCreate) !void {
    const original_content = object.content;
    const author = object.author.username;
    const without_prefix = std.mem.trimLeft(u8, original_content["%s".len..], &.{' '});

    var tokenizer = std.mem.tokenizeScalar(u8, without_prefix, ' ');
    const command = c: {
        const first_word = tokenizer.next() orelse return try c.chat(object.channel_id, object.id, "unknown command", .{});
        const command = std.meta.stringToEnum(Commands, first_word) orelse return try c.chat(
            object.channel_id,
            object.id,
            "unknown command: {s}",
            .{first_word},
        );
        break :c command;
    };

    switch (command) {
        .help => try c.chat(
            object.channel_id,
            object.id,
            usage,
            .{},
        ),
        .version => try c.chat(
            object.channel_id,
            object.id,
            "{}",
            .{root.version},
        ),
        .tag => {
            const sub_command_string = tokenizer.next() orelse
                return try c.chat(object.channel_id, object.id, "no sub command provided", .{});
            const sub_command = std.meta.stringToEnum(TagCommands, sub_command_string) orelse
                return try c.chat(object.channel_id, object.id, "unknown tag subcommand: {s}", .{sub_command_string});

            switch (sub_command) {
                .add => {
                    const name = tokenizer.next() orelse
                        return try c.chat(object.channel_id, object.id, "no tag name provided", .{});
                    const body = tokenizer.rest();

                    b.tag_db.createTag(b.gpa, name, author, body) catch |err| switch (err) {
                        error.AlreadyExists => return try c.chat(
                            object.channel_id,
                            object.id,
                            "a tag by the name '{s}' already exists: ",
                            .{sub_command_string},
                        ),
                        else => return err,
                    };

                    try c.chat(
                        object.channel_id,
                        object.id,
                        "added tag '{s}' under '{s}'",
                        .{ name, author },
                    );
                },
                .owner => {
                    const name = tokenizer.next() orelse
                        return try c.chat(object.channel_id, object.id, "no tag name provided", .{});

                    const tag = b.tag_db.getTag(name) catch |err| switch (err) {
                        error.NoTag => return try c.chat(
                            object.channel_id,
                            object.id,
                            "no tag exists by the name of '{s}'",
                            .{name},
                        ),
                        else => return err,
                    };

                    try c.chat(
                        object.channel_id,
                        object.id,
                        "tag '{s}' is owned by '{s}'",
                        .{ name, tag.owner },
                    );
                },
            }
        },
    }
}
