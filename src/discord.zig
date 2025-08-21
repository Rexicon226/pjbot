//! Contains definitions pertaining to the Discord APIs
//!
//! TODO: move the json definitions into here probably

pub const Intents = packed struct(u26) {
    guilds: bool = false,
    guild_members: bool = false,
    guild_moderation: bool = false,
    guild_expressions: bool = false,
    guild_integrations: bool = false,
    guild_webhooks: bool = false,
    guild_invites: bool = false,
    guild_voice_states: bool = false,
    guild_presences: bool = false,
    guild_messages: bool = false,
    guild_message_reactions: bool = false,
    guild_message_typing: bool = false,
    direct_messages: bool = false,
    direct_message_reactions: bool = false,
    direct_message_typing: bool = false,
    message_content: bool = false,
    guild_scheduled_events: bool = false,
    _padding1: u3 = 0,
    auto_moderation_configuration: bool = false,
    auto_moderation_execution: bool = false,
    _padding2: u2 = 0,
    guild_message_polls: bool = false,
    direct_message_polls: bool = false,
};

pub const MessageCreate = struct {
    author: struct {
        username: []const u8,
    },
    channel_id: []const u8,
    content: []const u8,
    id: []const u8,
};

pub const MessageSend = struct {
    content: []const u8,
    message_reference: ?struct {
        message_id: []const u8,
    },
};
