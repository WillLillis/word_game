const std = @import("std");
const rl = @import("raylib");
const rlm = @import("raylib-math");
const String = @import("string").String;
const set = @import("ziglangSet");

const Vector2 = rl.Vector2;

// We'll just start with an assumption that there will be no more than
// 10 target words. This limitation is purely to simplify the rendering
// code for now...
const PADDING: i32 = 10;
const MAX_TARGETS: usize = 10;
const MAX_WORD_LEN: usize = 128;
const MAX_MSG_LEN: usize = 128;

// TODO: Clean up naming here...
// Maybe split up config into sub structs?
const Config = struct {
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
    hover_msg_font_size: f32,
    hover_msg_dur: f32,
    target_letter_val: u32,
    bonus_letter_val: u32,
    score_font_size: f32,
};

const config = Config{
    .target_cover = rl.Color.dark_blue,
    .target_text = rl.Color.dark_green,
    .letter_circle = rl.Color.black,
    .letter_text = rl.Color.white,
    .letter_select = rl.Color.yellow,
    .letter_center = Vector2.init(300, 300),
    .letter_circle_radius = 20,
    .letters_radius = 100,
    .target_font_size = 50,
    .hover_msg_font_size = 40,
    .target_spacing = 1,
    .curr_letter_font_size = 100,
    .hover_msg_dur = 1.0,
    .target_letter_val = 200,
    .bonus_letter_val = 100,
    .score_font_size = 50,
};

const DisplayMessageTag = enum {
    target_word,
    bonus_word,
    not_a_word,
    prev_found_word,
};

const DisplayMessage = union(DisplayMessageTag) {
    target_word: u32,
    bonus_word: u32,
    not_a_word: void,
    prev_found_word: void,
};

const HoverMessage = struct {
    const Self = @This();

    message: ?DisplayMessage,
    time: f32,

    fn init() Self {
        return Self{
            .message = null,
            .time = 0,
        };
    }

    /// Returns true if the current message remained active after the step, false otherwise
    fn step_counter(self: *Self, delta: f32) void {
        if (self.time <= delta) {
            self.time = 0;
        } else {
            self.time -= delta;
        }
    }

    fn target_word(word: []const u8) Self {
        return Self{ .message = DisplayMessage{ .target_word = @as(u32, @intCast(word.len)) * config.target_letter_val }, .time = config.hover_msg_dur };
    }

    fn bonus_word(word: []const u8) Self {
        return Self{ .message = DisplayMessage{ .bonus_word = @as(u32, @intCast(word.len)) * config.bonus_letter_val }, .time = config.hover_msg_dur };
    }

    fn bad_word() Self {
        return Self{ .message = DisplayMessage{ .not_a_word = {} }, .time = config.hover_msg_dur };
    }

    fn prev_found_word() Self {
        return Self{ .message = DisplayMessage{ .prev_found_word = {} }, .time = config.hover_msg_dur };
    }

    fn buf_print(self: *const Self, buf: *[MAX_MSG_LEN:0]u8) !void {
        if (self.message) |msg| {
            switch (msg) {
                .target_word => |points| {
                    _ = try std.fmt.bufPrintZ(buf, "+{d}", .{points});
                },
                .bonus_word => |points| {
                    _ = try std.fmt.bufPrintZ(buf, "Bonus Word: +{d}", .{points});
                },
                .not_a_word => {
                    _ = try std.fmt.bufPrintZ(buf, "Not A Word!", .{});
                },
                .prev_found_word => {
                    _ = try std.fmt.bufPrintZ(buf, "Already found", .{});
                },
            }
        }
    }
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
            rl.drawCircleV(self.pos, self.radius * 1.25, config.letter_select);
        }
        rl.drawCircleV(self.pos, self.radius, config.letter_circle);
        const radius = @as(i32, @intFromFloat(self.radius));
        rl.drawText(&self.text, @as(i32, @intFromFloat(self.pos.x)) - @divTrunc(radius, 4), @as(i32, @intFromFloat(self.pos.y)) - @divTrunc(radius, 2), radius, config.letter_text);
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
            .color = config.letter_circle,
        };
    }

    fn deinit(self: *Self) void {
        self.text.deinit();
    }

    fn draw(self: *const Self) void {
        const text_size = rl.measureTextEx(rl.getFontDefault(), "A", config.target_font_size, config.target_spacing);
        if (self.visible) {
            rl.drawText(self.text.str()[0 .. self.text.len() - 1 :0], @as(i32, @intFromFloat(self.pos.x)), @as(i32, @intFromFloat(self.pos.y)), config.target_font_size, self.color);
        } else {
            var curr_x = self.pos.x;
            for (0..self.text.len() - 1) |_| { // don't draw rectangle for sentinel zero value
                rl.drawRectangle(@as(i32, @intFromFloat(curr_x)), @as(i32, @intFromFloat(self.pos.y)), @as(i32, @intFromFloat(text_size.x)), @as(i32, @intFromFloat(text_size.y)), rl.Color.green);
                curr_x += text_size.x + config.target_spacing;
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
    letters_center: Vector2 = config.letter_center,
    word_store: set.HashSetManaged([]const u8), // this is using the pointer isn't it...
    bonus_words: set.Set([]const u8),
    curr_hover_msg: HoverMessage = HoverMessage.init(), // need to bundle the countdown with the message...
    hover_msg_buf: [@max(MAX_WORD_LEN, MAX_MSG_LEN):0]u8 = undefined,
    new_hover_msg: bool = false,
    score: u32 = 0,
    score_buf: [18:0]u8 = undefined,

    fn init(allocator: std.mem.Allocator) !Self {
        var state = Self{
            .letter_blocks = std.ArrayList(LetterBlock).init(allocator),
            .target_words = std.ArrayList(TargetBlock).init(allocator),
            .curr_letters = undefined, //try WordBuilder.init(allocator, letters.len),
            //.word_store = set.Set([]const u8).init(allocator), // this leads to a crash with an allocation failure
            .word_store = try set.HashSetManaged([]const u8).initCapacity(allocator, 3000), // this doesn't
            .bonus_words = set.Set([]const u8).init(allocator),
        };
        state.score_buf[state.score_buf.len] = 0; // still needed?
        try state.load_word_store(allocator, null);

        var targets = std.ArrayList([]const u8).init(allocator);
        defer targets.deinit();
        var gen = std.Random.Xoshiro256.init(42069);
        const random = gen.random();
        for (0..3) |_| {
            const target_idx = std.rand.uintLessThan(random, usize, state.word_store.cardinality() - 1);

            var idx: usize = 0;
            var iter = state.word_store.iterator();
            while (iter.next()) |elem| {
                defer idx += 1;
                if (idx == target_idx) {
                    try targets.append(elem.*);
                    break;
                }
            }
        }
        std.sort.insertion([]const u8, targets.items, .{}, GameState.targets_less_than);
        try state.add_targets(allocator, &targets);
        // var letters: set.Set(u8) = set.Set(u8).init(allocator);
        // TODO: Need to do some de-duping here... (need to maintain multiple copies, but only 
        // the most in any given word
        // Also shuffle
        var letters = std.ArrayList(u8).init(allocator);
        defer letters.deinit();
        for (targets.items) |word| {
            for (0..word.len) |i| {
                _ = try letters.append(word[i]);
            }
        }
        // state.curr_letters = try WordBuilder.init(allocator, letters.cardinality());
        state.curr_letters = try WordBuilder.init(allocator, letters.items.len);
        try state.add_letters(letters.items);

        return state;
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.letter_blocks.deinit();
        for (self.target_words.items) |*word| {
            word.deinit();
        }
        self.target_words.deinit();
        self.curr_letters.deinit();
        var store_iter = self.word_store.iterator();
        while (store_iter.next()) |elem| {
            allocator.free(elem.*);
        }
        self.word_store.deinit();
        self.bonus_words.deinit();
    }

    fn render(self: *Self) !void {
        for (self.target_words.items) |block| {
            block.draw();
        }

        for (self.letter_blocks.items) |block| {
            block.draw();
        }

        if (self.curr_letters.curr_letters.len() > 0) {
            _ = try std.fmt.bufPrintZ(&self.hover_msg_buf, "{s}", .{self.curr_letters.curr_letters.str()});
            rl.drawText(&self.hover_msg_buf, 300, 20, config.curr_letter_font_size, rl.Color.light_gray);
        }

        if (self.curr_hover_msg.time > 0) {
            if (self.new_hover_msg) {
                try self.curr_hover_msg.buf_print(&self.hover_msg_buf);
            }
            rl.drawText(&self.hover_msg_buf, 250, 250, config.hover_msg_font_size, rl.Color.gold);
        }

        // TODO: See if we can do this lazily...
        // _ = try std.fmt.bufPrintIntToSlice(&self.score_buf, self.score, 10, .lower, .{}); // compiler bug?
        _ = try std.fmt.bufPrintZ(&self.score_buf, "Score: {d}", .{self.score});
        rl.drawText(&self.score_buf, 450, 300, config.score_font_size, rl.Color.dark_blue);
    }

    fn add_letters(self: *Self, letters: []const u8) !void {
        if (letters.len == 0) {
            return;
        }
        const delta = 2.0 * std.math.pi / @as(f32, @floatFromInt(letters.len));
        const radius = config.letters_radius;
        // TODO: determine radius of circle needed for all letter block
        // circles with given radius to fit with some amount of padding

        for (letters, 0..) |letter, i| {
            const x = self.letters_center.x + radius * std.math.cos(delta * @as(f32, @floatFromInt(i)));
            const y = self.letters_center.y + radius * std.math.sin(delta * @as(f32, @floatFromInt(i)));
            const block = LetterBlock.init(Vector2.init(x, y), config.letter_circle_radius, letter);
            try self.letter_blocks.append(block);
        }
    }

    fn add_letters_map(self: *Self, letters: set.Set(u8)) !void {
        if (letters.cardinality() == 0) {
            return;
        }
        const delta = 2.0 * std.math.pi / @as(f32, @floatFromInt(letters.cardinality()));
        const radius = config.letters_radius;
        // TODO: determine radius of circle needed for all letter block
        // circles with given radius to fit with some amount of padding
        var idx: usize = 0;
        var iter = letters.iterator();
        while (iter.next()) |letter| {
            defer idx += 1;

            const x = self.letters_center.x + radius * std.math.cos(delta * @as(f32, @floatFromInt(idx)));
            const y = self.letters_center.y + radius * std.math.sin(delta * @as(f32, @floatFromInt(idx)));
            const block = LetterBlock.init(Vector2.init(x, y), config.letter_circle_radius, letter.*);
            try self.letter_blocks.append(block);
        }
    }

    fn add_targets(self: *Self, allocator: std.mem.Allocator, targets: *const std.ArrayList([]const u8)) !void {
        const word_height = rl.measureTextEx(rl.getFontDefault(), "A", config.target_font_size, config.target_spacing).y; // NOTE: string to pass in besides " "? or just grab at comptime?fn
        var max_word_len: u64 = 0;
        var curr_pos = Vector2.init(PADDING, PADDING);

        for (targets.items, 0..) |word, i| {
            try self.add_target_word(word, curr_pos, allocator);
            std.debug.print("Target: {s}\n", .{word});
            max_word_len = @max(max_word_len, word.len);
            curr_pos.y += word_height + PADDING;

            if (i > targets.items.len / 2) {
                curr_pos.x += @as(f32, @floatFromInt(max_word_len));
                curr_pos.y = PADDING;
            }
        }
    }

    fn load_word_store(self: *Self, allocator: std.mem.Allocator, path: ?[]const u8) !void {
        var file: std.fs.File = undefined;
        if (path) |custom_path| {
            if (std.fs.path.isAbsolute(custom_path)) {
                file = try std.fs.cwd().openFile(custom_path, .{});
            }
        } else {
            file = try std.fs.cwd().openFile("words.txt", .{});
        }

        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();

        var buf: [32]u8 = undefined;
        while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            const copy = try allocator.dupe(u8, line);
            _ = try self.word_store.add(copy);
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

    // TODO: Have this return a hover message?
    fn submit_word(self: *Self) !void {
        const submission = self.curr_letters.curr_letters.str();

        for (self.target_words.items) |*word| {
            if (!word.visible and std.mem.eql(u8, submission, word.text.str()[0 .. word.text.str().len - 1])) { // Don't compare against the sentinel 0 value
                self.new_hover_msg = true;
                self.curr_hover_msg = HoverMessage.target_word(submission);
                word.visible = true;
                self.score += @as(u32, @intCast(submission.len)) * config.target_letter_val;
                return;
            }
        }

        self.new_hover_msg = true;
        if (self.word_store.contains(submission)) {
            if (!self.bonus_words.contains(submission)) {
                _ = try self.bonus_words.add(submission);
                self.score += @as(u32, @intCast(submission.len)) * config.bonus_letter_val;
                self.curr_hover_msg = HoverMessage.bonus_word(submission);
            } else {
                self.curr_hover_msg = HoverMessage.prev_found_word();
            }
        } else {
            self.curr_hover_msg = HoverMessage.bad_word();
        }
    }

    fn check_letter_overlap(self: *const Self, pos: Vector2) ?usize {
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
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = false }){};
    const backing_allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    // all of the allocations are tied into the game state...makes sense to use an arena
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    rl.initWindow(screenWidth, screenHeight, "Word Game");
    defer rl.closeWindow(); // Close window and OpenGL context

    rl.setTargetFPS(60); // Set our game to run at 60 frames-per-second
    //--------------------------------------------------------------------------------------

    // var targets = std.ArrayList([]const u8).init(allocator);
    // defer targets.deinit();
    // pick 3 random words from the list
    // get a random number...
    // try targets.append("HEY");
    // try targets.append("IT");
    // try targets.append("WORKS");

    // const letters = [_]u8{
    //     'H',
    //     'E',
    //     'Y',
    //     'I',
    //     'T',
    //     'W',
    //     'O',
    //     'R',
    //     'K',
    //     'S',
    // };
    var state = try GameState.init(allocator);
    defer state.deinit(allocator);

    var last_letter: ?usize = null;

    // TODO: Keep track of LetterBlock's we're accumulating,
    // see if we can allow "unselecting"

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // State update
        //----------------------------------------------------------------------------------
        defer state.new_hover_msg = false;
        const mouse_pos = rl.getMousePosition();
        const selected_letter = state.check_letter_overlap(mouse_pos);
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
                try state.submit_word();
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

        state.curr_hover_msg.step_counter(rl.getFrameTime());

        //----------------------------------------------------------------------------------

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        try state.render();

        //----------------------------------------------------------------------------------
    }
}
