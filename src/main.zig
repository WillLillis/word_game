const std = @import("std");
const rl = @import("raylib");
const rlm = @import("raylib-math");
const String = @import("string").String;

const Vector2 = rl.Vector2;

// We'll just start with an assumption that there will be no more than
// 10 target words. This limitation is purely to simplify the rendering code...
const PADDING: i32 = 10;
const MAX_TARGETS: usize = 10;
const MAX_WORD_LEN: usize = 128;

const Theme = struct {
    target_cover: rl.Color,
    target_text: rl.Color,
    letter_circle: rl.Color,
    letter_text: rl.Color,
    letter_select: rl.Color,
    letter_circle_radius: f32,
    letters_radius: f32,
    letter_center: Vector2,
    target_font_size: f32,
    target_spacing: f32,
    curr_letter_font_size: f32,
};

const theme = Theme{
    .target_cover = rl.Color.dark_blue,
    .target_text = rl.Color.dark_green,
    .letter_circle = rl.Color.black,
    .letter_text = rl.Color.white,
    .letter_select = rl.Color.yellow,
    .letter_center = Vector2.init(300, 300),
    .letter_circle_radius = 20,
    .letters_radius = 100,
    .target_font_size = 50,
    .target_spacing = 1,
    .curr_letter_font_size = 100,
};

const LetterBlock = struct {
    const Self = @This();

    pos: Vector2,
    radius: f32,
    text: [1:0]u8,
    selected: bool = false,

    fn containsPoint(self: *const Self, point: Vector2) bool {
        return rlm.vector2Distance(self.pos, point) < self.radius;
    }

    fn init(pos: Vector2, radius: f32, letter: u8) LetterBlock {
        var text: [1:0]u8 = undefined;
        text[0] = letter;
        text[text.len] = 0;
        return LetterBlock{
            .pos = pos,
            .radius = radius,
            .text = text,
        };
    }

    fn draw(self: *const Self) void {
        if (self.selected) {
            rl.drawCircleV(self.pos, self.radius * 1.25, theme.letter_select);
        }
        rl.drawCircleV(self.pos, self.radius, theme.letter_circle);
        const radius = @as(i32, @intFromFloat(self.radius));
        rl.drawText(&self.text, @as(i32, @intFromFloat(self.pos.x)) - @divTrunc(radius, 4), @as(i32, @intFromFloat(self.pos.y)) - @divTrunc(radius, 2), radius, theme.letter_text);
    }
};

const TargetBlock = struct {
    const Self = @This();

    pos: Vector2,
    text: String,
    color: rl.Color,
    visible: bool = false,

    fn init(allocator: std.mem.Allocator, pos: Vector2, text: []const u8) !Self {
        var inner_text = try String.init_with_contents(allocator, text);
        try inner_text.concat(&[_]u8{0});

        return Self{
            .pos = pos,
            .text = inner_text,
            .color = theme.letter_circle,
        };
    }

    fn deinit(self: *Self) void {
        self.text.deinit();
    }

    fn draw(self: *const Self) void {
        const text_size = rl.measureTextEx(rl.getFontDefault(), "A", theme.target_font_size, theme.target_spacing);
        if (self.visible) {
            rl.drawText(self.text.str()[0 .. self.text.len() - 1 :0], @as(i32, @intFromFloat(self.pos.x)), @as(i32, @intFromFloat(self.pos.y)), theme.target_font_size, self.color);
        } else {
            var curr_x = self.pos.x;
            for (0..self.text.len() - 1) |_| {
                rl.drawRectangle(@as(i32, @intFromFloat(curr_x)), @as(i32, @intFromFloat(self.pos.y)), @as(i32, @intFromFloat(text_size.x)), @as(i32, @intFromFloat(text_size.y)), rl.Color.green);
                curr_x += text_size.x + theme.target_spacing;
            }
        }
    }
};

const WordBuilder = struct {
    const Self = @This();

    curr_letters: String,
    curr_idxs: std.ArrayList(bool),

    fn init(allocator: std.mem.Allocator, len: usize) !Self {
        var curr_idxs = try std.ArrayList(bool).initCapacity(allocator, len);
        try curr_idxs.appendNTimes(false, len);
        return WordBuilder{
            .curr_letters = String.init(allocator),
            .curr_idxs = curr_idxs,
        };
    }

    fn deinit(self: *Self) void {
        self.curr_letters.deinit();
        self.curr_idxs.deinit();
    }

    fn clear(self: *Self) void {
        self.curr_letters.clear();
        @memset(self.curr_idxs.items, false);
    }

    fn add_idx_checked(self: *Self, letter: []u8, idx: usize) void {
        if (idx < self.curr_idxs.items.len and !self.curr_idxs.items[idx]) {
            self.curr_letters.concat(letter);
        }
    }
};

const GameState = struct {
    const Self = @This();

    letter_blocks: std.ArrayList(LetterBlock),
    target_words: std.ArrayList(TargetBlock), // swap out raw string for some target block
    curr_letters: WordBuilder,
    is_building: bool = false,
    letters_center: Vector2 = theme.letter_center,

    fn init(allocator: std.mem.Allocator, letters: []const u8, targets: *const std.ArrayList([]const u8)) !Self {
        var state = Self{
            .letter_blocks = std.ArrayList(LetterBlock).init(allocator),
            .target_words = std.ArrayList(TargetBlock).init(allocator),
            .curr_letters = try WordBuilder.init(allocator, letters.len),
        };
        try state.add_letters(letters);
        try state.add_targets(allocator, targets);
        return state;
    }

    fn deinit(self: *Self) void {
        self.letter_blocks.deinit();
        for (self.target_words.items) |*word| {
            word.deinit();
        }
        self.target_words.deinit();
        self.curr_letters.deinit();
    }

    fn render(self: *const Self) void {
        for (self.target_words.items) |block| {
            block.draw();
        }

        for (self.letter_blocks.items) |block| {
            block.draw();
        }
    }

    fn add_letters(self: *Self, letters: []const u8) !void {
        if (letters.len == 0) {
            return;
        }
        const delta = 2.0 * std.math.pi / @as(f32, @floatFromInt(letters.len));
        const radius = theme.letters_radius; // NOTE: Determine programmatically later?

        for (letters, 0..) |letter, i| {
            const x = self.letters_center.x + radius * std.math.cos(delta * @as(f32, @floatFromInt(i)));
            const y = self.letters_center.y + radius * std.math.sin(delta * @as(f32, @floatFromInt(i)));
            const block = LetterBlock.init(Vector2.init(x, y), theme.letter_circle_radius, letter);
            try self.letter_blocks.append(block);
        }
    }

    fn add_targets(self: *Self, allocator: std.mem.Allocator, targets: *const std.ArrayList([]const u8)) !void {
        const word_height = rl.measureTextEx(rl.getFontDefault(), "A", theme.target_font_size, theme.target_spacing).y; // NOTE: string to pass in besides " "? or just grab at comptime?
        var max_word_len: u64 = 0;
        var curr_pos = Vector2.init(PADDING, PADDING);

        for (targets.items, 0..) |word, i| {
            try self.add_target_word(word, curr_pos, allocator);
            max_word_len = @max(max_word_len, word.len);
            curr_pos.y += word_height + PADDING;

            if (i > targets.items.len / 2) {
                curr_pos.x += @as(f32, @floatFromInt(max_word_len));
                curr_pos.y = PADDING;
            }
        }
    }

    fn add_target_word(self: *Self, word: []const u8, pos: Vector2, allocator: std.mem.Allocator) !void {
        const my_target = try TargetBlock.init(allocator, pos, word);
        try self.target_words.append(my_target);
    }

    fn targets_less_than(_: @TypeOf(.{}), lhs: []const u8, rhs: []const u8) bool {
        if (lhs.len == rhs.len) {
            for (0..lhs.len) |i| {
                if (lhs[i] == rhs[i]) {
                    continue;
                }
                return lhs[i] < rhs[i];
            }
            return false;
        } else {
            return lhs.len < rhs.len;
        }
    }


    fn submit_word(self: *Self) void {
        const submission = self.curr_letters.curr_letters.str();
        for (self.target_words.items) |*word| {
            if (std.mem.eql(u8, submission, word.text.str()[0 .. word.text.str().len - 1])) { // Don't compare against the sentinel 0 value
                word.visible = true;
                break;
            }
        }
    }

    fn check_overlap(self: *const Self, pos: Vector2) ?usize {
        for (self.letter_blocks.items, 0..) |*letter, i| {
            if (letter.containsPoint(pos)) {
                return i;
            }
        }
        return null;
    }
};

pub fn main() !void {
    // Initialization
    //--------------------------------------------------------------------------------------
    const screenWidth = 800;
    const screenHeight = 450;
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    rl.initWindow(screenWidth, screenHeight, "Word Game");
    defer rl.closeWindow(); // Close window and OpenGL context

    rl.setTargetFPS(60); // Set our game to run at 60 frames-per-second
    //--------------------------------------------------------------------------------------

    var targets = std.ArrayList([]const u8).init(allocator);
    defer targets.deinit();
    try targets.append("HEY");
    try targets.append("IT");
    try targets.append("WORKS");
    std.sort.insertion([]const u8, targets.items, .{}, GameState.targets_less_than);
    
    const letters = [_]u8{
        'H',
        'E',
        'Y',
        'I',
        'T',
        'W',
        'O',
        'R',
        'K',
        'S',
    };
    var state = try GameState.init(allocator, &letters, &targets);
    defer state.deinit();

    try state.add_letters(letters[0..]);

    var last_letter: ?usize = null;
    var curr_letters: [MAX_WORD_LEN:0]u8 = undefined;

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // State update
        //----------------------------------------------------------------------------------
        // Enumerate cases here...
        const mouse_pos = rl.getMousePosition();
        const selected_letter = state.check_overlap(mouse_pos);
        if (state.is_building) {
            if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_left)) {
                if (selected_letter) |idx| {
                    if (!state.curr_letters.curr_idxs.items[idx]) {
                        state.curr_letters.curr_idxs.items[idx] = true;
                        state.letter_blocks.items[idx].selected = true;
                        const new_letter = state.letter_blocks.items[idx].text;
                        try state.curr_letters.curr_letters.concat(&new_letter);
                    }
                }
            } else {
                state.is_building = false;
                state.submit_word();
                state.curr_letters.clear();
                last_letter = null;
                for (state.letter_blocks.items) |*letter| {
                    letter.selected = false;
                }
            }
        } else {
            if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_left)) {
                state.is_building = true;
                if (selected_letter) |idx| {
                    state.curr_letters.curr_idxs.items[idx] = true;
                    state.letter_blocks.items[idx].selected = true;
                    const new_letter = state.letter_blocks.items[idx].text;
                    try state.curr_letters.curr_letters.concat(&new_letter);
                }
            }
        }

        //----------------------------------------------------------------------------------

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        state.render();

        if (state.curr_letters.curr_letters.len() > 0) {
            _ = try std.fmt.bufPrintZ(&curr_letters, "{s}", .{state.curr_letters.curr_letters.str()});
            rl.drawText(&curr_letters, 300, 20, theme.curr_letter_font_size, rl.Color.light_gray);
        }
        //----------------------------------------------------------------------------------
    }
}
