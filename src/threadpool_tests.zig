const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Condition = std.Thread.Condition;
const Mutex = std.Thread.Mutex;
const AtomicBool = std.atomic.Value(bool);
const testing = std.testing;

const ThreadPool = @import("threadpool.zig").ThreadPool;
const Task = @import("threadpool.zig").Task;

/// A test context for tracking task execution in thread pool tests.
/// Holds an atomic counter to record how many times a task is executed.
const TestTaskContext = struct {
    counter: *std.atomic.Value(usize), // Atomic counter for task executions
    expected_value: usize, // Expected final counter value (for reference in tests)

    /// Executes the test task by atomically incrementing the counter.
    fn execute(self: *TestTaskContext) void {
        _ = self.counter.fetchAdd(1, .seq_cst);
    }

    /// Creates a new test context with an initialized atomic counter.
    ///
    /// Arguments:
    ///   - allocator: The allocator for memory management.
    ///   - expected_value: The expected final counter value (for test reference).
    ///
    /// Returns: A pointer to the created context, or an error if allocation fails.
    fn create(allocator: Allocator, expected_value: usize) !*TestTaskContext {
        // Allocate and initialize the atomic counter.
        const counter = try allocator.create(std.atomic.Value(usize));
        counter.* = std.atomic.Value(usize).init(0);
        // Allocate and initialize the test context.
        const ctx = try allocator.create(TestTaskContext);
        ctx.* = .{ .counter = counter, .expected_value = expected_value };
        return ctx;
    }

    /// Frees the memory allocated for the test context and its counter.
    ///
    /// Arguments:
    ///   - self: The test context to destroy.
    ///   - allocator: The allocator used to free memory.
    fn destroy(self: *TestTaskContext, allocator: Allocator) void {
        allocator.destroy(self.counter);
        allocator.destroy(self);
    }
};

/// Wrapper function to execute a TestTaskContext as a Task.
/// Converts the opaque context pointer and calls the context's execute method.
fn testTaskExecute(context: *anyopaque) void {
    const ctx = @as(*TestTaskContext, @ptrCast(@alignCast(context)));
    ctx.execute();
}

// Tests that the thread pool initializes correctly with the specified number of threads.
// Verifies initial state, including thread count, stop flag, and empty queue.
test "ThreadPool initializes correctly" {
    const allocator = testing.allocator;
    const thread_count = 4;

    // Initialize the thread pool with verbose logging enabled.
    const pool = try ThreadPool.init(allocator, thread_count, true);
    defer pool.deinit();

    // Verify the thread pool is set up correctly.
    try testing.expectEqual(thread_count, pool.threads.len);
    try testing.expectEqual(false, pool.stop_flag.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), pool.task_queue.readableLength());
}

// Tests that the thread pool can submit and execute a single task.
// Ensures the task is executed exactly once by checking the task's counter.
test "ThreadPool submits and executes single task" {
    const allocator = testing.allocator;
    const thread_count = 2;

    // Initialize the thread pool with two worker threads.
    const pool = try ThreadPool.init(allocator, thread_count, true);
    defer pool.deinit();

    // Create a test context with an expected counter value of 1.
    const ctx = try TestTaskContext.create(allocator, 1);
    defer ctx.destroy(allocator);

    // Create a task that uses the test context.
    const task = Task{
        .execute_fn = testTaskExecute,
        .context = ctx,
    };

    // Submit the task to the thread pool.
    try pool.submit(task);
    // Wait for the task to complete.
    pool.wait();

    // Verify the task was executed exactly once.
    try testing.expectEqual(@as(usize, 1), ctx.counter.load(.seq_cst));
}

// Tests that the thread pool can handle multiple tasks concurrently.
// Submits multiple tasks and verifies each is executed exactly once.
test "ThreadPool executes multiple tasks concurrently" {
    const allocator = testing.allocator;
    const thread_count = 4;
    const task_count = 10;

    // Initialize the thread pool with four worker threads.
    const pool = try ThreadPool.init(allocator, thread_count, true);
    defer pool.deinit();

    // Create an array to hold test contexts for each task.
    var contexts: [task_count]*TestTaskContext = undefined;
    for (&contexts) |*ctx| {
        // Create a test context for each task.
        ctx.* = try TestTaskContext.create(allocator, task_count);
        // Create and submit a task for the context.
        const task = Task{
            .execute_fn = testTaskExecute,
            .context = ctx.*,
        };
        try pool.submit(task);
    }
    // Ensure all test contexts are destroyed after the test.
    defer for (contexts) |ctx| ctx.destroy(allocator);

    // Wait for all tasks to complete.
    pool.wait();

    // Verify each task was executed exactly once.
    for (contexts) |ctx| {
        try testing.expectEqual(@as(usize, 1), ctx.counter.load(.seq_cst));
    }
}

// Tests that the thread pool handles an empty queue gracefully and remains functional.
// Verifies the pool's state with no tasks and ensures a subsequent task executes correctly.
test "ThreadPool handles empty queue gracefully" {
    const allocator = testing.allocator;
    const thread_count = 2;

    // Initialize the thread pool with two worker threads.
    const pool = try ThreadPool.init(allocator, thread_count, true);
    defer pool.deinit();

    // Verify the pool is idle with an empty queue and not stopped.
    try testing.expectEqual(@as(usize, 0), pool.task_queue.readableLength());
    try testing.expectEqual(false, pool.stop_flag.load(.seq_cst));

    // Create a test context to verify pool functionality.
    const ctx = try TestTaskContext.create(allocator, 1);
    defer ctx.destroy(allocator);

    // Submit a single task to ensure the pool is still operational.
    const task = Task{
        .execute_fn = testTaskExecute,
        .context = ctx,
    };
    try pool.submit(task);

    // Wait for the task to complete.
    pool.wait();
    // Verify the task was executed exactly once.
    try testing.expectEqual(@as(usize, 1), ctx.counter.load(.seq_cst));
}
