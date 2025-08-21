const std = @import("std");
const build_options = @import("build_options");
const kiesel = @import("kiesel");
const ptk = @import("ptk");
const Client = @import("Client.zig");
const TagDb = @import("TagDb.zig");
const discord = @import("discord.zig");
const root = @import("main.zig");
const Bot = @This();

const Agent = kiesel.execution.Agent;
const Realm = kiesel.execution.Realm;
const Script = kiesel.language.Script;

gpa: std.mem.Allocator,
tag_db: TagDb,

const Commands = enum {
    help,
    version,
    tag,
    eval,
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
    \\  tag - command for dealing with tags
    \\  
    \\Requires JS enabled:
    \\  eval - evaluates javascript
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

            const sub_command = std.meta.stringToEnum(TagCommands, sub_command_string) orelse {
                // if we don't know the subcommand, try to find it in the database and display it
                const tag = b.tag_db.getTag(sub_command_string) catch |err| switch (err) {
                    error.NoTag => return try c.chat(
                        object.channel_id,
                        object.id,
                        "no tag exists by the name of '{s}'",
                        .{sub_command_string},
                    ),
                    else => return err,
                };
                return try c.chat(object.channel_id, object.id, "{s}", .{tag.body});
            };

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
        .eval => {
            const source_text = tokenizer.rest();
            const platform = Agent.Platform.default();
            defer platform.deinit();
            var agent = try Agent.init(&platform, .{});
            defer agent.deinit();

            try Realm.initializeHostDefinedRealm(&agent, .{});
            const realm = agent.currentRealm();

            var diag: ptk.Diagnostics = .init(b.gpa);
            defer diag.deinit();
            const script = Script.parse(source_text, realm, null, .{
                .diagnostics = &diag,
                .file_name = "greg.js",
            }) catch |err| switch (err) {
                error.ParseError => {
                    var list: std.ArrayListUnmanaged(u8) = .empty;
                    defer list.deinit(b.gpa);
                    const writer = list.writer(b.gpa);
                    try diag.print(writer);
                    return try c.chat(object.channel_id, object.id, "{s}", .{list.items});
                },
                else => return err,
            };
            const result = script.evaluate() catch |err| switch (err) {
                error.ExceptionThrown => return try c.chat(object.channel_id, object.id, "{pretty}", .{agent.exception.?}),
                else => return err,
            };

            try c.chat(object.channel_id, object.id,
                \\```ansi
                \\{pretty}
                \\```
            , .{result});
        },
    }
}
