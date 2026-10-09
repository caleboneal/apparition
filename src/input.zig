const c = @import("c_graphics");

const Self = @This();

input: *c.apparition_input,

pub const Event = union(enum) {
    text: []const u8,
    backspace,
    quit,
};

pub fn init() !Self {
    const input = c.apparition_input_create_export() orelse return error.FailedToInitializeInput;
    return .{ .input = input };
}

pub fn deinit(self: *Self) void {
    c.apparition_input_destroy_export(self.input);
}

pub fn wait(self: *Self) !void {
    if (c.apparition_input_wait_export(self.input) != 0) return error.FailedToReadInput;
}

/// Returns the next queued libinput event, if any. Text is UTF-8 and remains
/// valid until the next call to `next`.
pub fn next(self: *Self, buffer: []u8) !?Event {
    const result = c.apparition_input_next_text_export(self.input, buffer.ptr, buffer.len);
    return switch (result) {
        0 => null,
        c.APPARITION_INPUT_BACKSPACE => .backspace,
        c.APPARITION_INPUT_QUIT => .quit,
        -1 => error.FailedToReadInput,
        else => |length| blk: {
            if (length < 0) return error.FailedToReadInput;
            break :blk .{ .text = buffer[0..@intCast(length)] };
        },
    };
}
