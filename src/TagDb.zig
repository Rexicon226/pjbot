const std = @import("std");
const TagDb = @This();

map: std.StringHashMapUnmanaged(Tag.Index),
tags: std.ArrayListUnmanaged(Tag),

pub const empty: TagDb = .{
    .map = .empty,
    .tags = .empty,
};

const Tag = struct {
    owner: []const u8,
    body: []const u8,

    const Index = enum(u32) {
        _,
    };
};

pub fn deinit(db: *TagDb, allocator: std.mem.Allocator) void {
    for (db.tags.items) |tag| {
        allocator.free(tag.body);
        allocator.free(tag.owner);
    }
    db.map.deinit(allocator);
}

/// Duplicates and takes ownership of `name`, `owner`, and `body`.
pub fn createTag(
    db: *TagDb,
    allocator: std.mem.Allocator,
    name: []const u8,
    owner: []const u8,
    body: []const u8,
) !void {
    const gop = try db.map.getOrPut(allocator, name);
    if (gop.found_existing) return error.AlreadyExists;
    gop.key_ptr.* = try allocator.dupe(u8, name);

    const next_index: Tag.Index = @enumFromInt(db.tags.items.len);
    gop.value_ptr.* = next_index;

    try db.tags.append(allocator, .{
        .owner = try allocator.dupe(u8, owner),
        .body = try allocator.dupe(u8, body),
    });
}

pub fn getTag(db: *const TagDb, name: []const u8) !Tag {
    const index = db.map.get(name) orelse return error.NoTag;
    return db.tags.items[@intFromEnum(index)];
}
