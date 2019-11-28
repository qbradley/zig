const std = @import("../std.zig");

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,
        index: usize,
        amount: usize,
        lock: std.Mutex,
        getters: WaitList,
        putters: WaitList,

        const WaitList = std.TailQueue(anyframe);

        pub fn init(self: *Self, buffer: []T) void {

            //pub fn init(buf : []T) Self {
            self.* = Self{
                .buf = buffer,
                .index = 0,
                .amount = 0,
                .lock = std.Mutex.init(),
                .getters = WaitList.init(),
                .putters = WaitList.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.lock.deinit();
        }

        pub fn put(self: *Self, data: T) void {
            // wakeup after lock is released
            var wakeup: ?*WaitList.Node = null;
            defer if (wakeup) |node| {
                resume node.data;
            };

            var held = self.lock.acquire();
            defer held.release();

            while (self.amount == self.buf.len) {
                var link = WaitList.Node.init(@frame());
                suspend {
                    self.putters.prepend(&link);
                    held.release();
                }
                held = self.lock.acquire();
            }

            var index = (self.index + self.amount) % self.buf.len;
            self.buf[index] = data;
            self.amount += 1;

            wakeup = self.getters.pop();
        }

        pub fn getOrNull(self: *Self) ?T {
            var held = self.lock.acquire();
            defer held.release();

            if (self.amount == 0) {
                return null;
            }

            return self.next_value();
        }

        pub fn get(self: *Self) T {
            // wakeup after lock is released
            var wakeup: ?*WaitList.Node = null;
            defer if (wakeup) |node| {
                resume node.data;
            };

            var held = self.lock.acquire();
            defer held.release();

            while (self.amount == 0) {
                var link = WaitList.Node.init(@frame());
                suspend {
                    self.getters.prepend(&link);
                    held.release();
                }
                held = self.lock.acquire();
            }

            wakeup = self.putters.pop();
            return self.next_value();
        }

        fn next_value(self: *Self) T {
            var index = self.index;
            var new_index = index + 1;
            self.index = if (new_index == self.buf.len) 0 else new_index;
            self.amount -= 1;
            return self.buf[index];
        }
    };
}

test "std.event.Channel" {
    if (!std.io.is_async) return error.SkipZigTest;

    var buf: [1]u64 = undefined;
    var channel: Channel(u64) = undefined;
    channel.init(&buf);

    var getter_ctx = async getter(&channel);
    var putter_ctx = async putter(&channel);

    var result = await getter_ctx;
    await putter_ctx;
    std.debug.assert(result == 10);
}

async fn putter(c: *Channel(u64)) void {
    var index: u64 = 1;
    while (index < 10) : (index += 1) {
        c.put(index);
    }
    c.put(0);
}

async fn getter(c: *Channel(u64)) usize {
    var count: usize = 0;
    while (true) {
        var value = c.get();
        count += 1;
        std.debug.warn("Value: {}\n", value);
        if (value == 0) {
            break;
        }
    }

    return count;
}
