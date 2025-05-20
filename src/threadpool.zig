const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Condition = std.Thread.Condition;
const Mutex = std.Thread.Mutex;
const AtomicBool = std.atomic.Value(bool);
const testing = std.testing;

/// Represents a single unit of work to be executed by the thread pool.
/// A task consists of a function pointer and an opaque context pointer.
pub const Task = struct {
    execute_fn: *const fn (context: *anyopaque) void, // Function to execute the task
    context: *anyopaque, // Opaque pointer to task-specific data
};

/// A thread pool that manages a fixed number of worker threads to execute tasks
/// from a queue concurrently. Supports task submission, synchronization, and
/// graceful shutdown.
pub const ThreadPool = struct {
    const Self = @This();

    // Allocator for managing memory for the thread pool and its resources.
    allocator: Allocator,
    // Array of worker threads that process tasks.
    threads: []Thread,
    // Dynamic FIFO queue for storing pending tasks.
    task_queue: std.fifo.LinearFifo(Task, .Dynamic),
    // Mutex to protect access to the task queue.
    queue_mutex: Mutex,
    // Condition variable to signal when tasks are added to the queue.
    queue_condition: Condition,
    // Atomic flag to signal threads to stop processing tasks.
    stop_flag: AtomicBool,
    // Atomic flag to prevent task submission after deinitialization.
    is_deinitialized: AtomicBool,
    // Enables debug printing for task execution if true.
    verbose: bool,
    // Atomic counter for tasks in the queue or being executed.
    pending_tasks: std.atomic.Value(usize),
    // Mutex to protect the task completion condition.
    completion_mutex: Mutex,
    // Condition variable to signal when tasks are completed.
    completion_condition: Condition,

    /// Initializes a new thread pool with the specified number of worker threads.
    /// Allocates resources and spawns threads to process tasks.
    ///
    /// Arguments:
    ///   - allocator: The allocator for memory management.
    ///   - thread_count: Number of worker threads to create.
    ///   - verbose: If true, enables debug printing of task execution.
    ///
    /// Returns: A pointer to the initialized thread pool, or an error if allocation fails.
    pub fn init(allocator: Allocator, thread_count: usize, verbose: bool) !*Self {
        // Allocate memory for the thread pool struct.
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Initialize the thread pool with provided settings and default values.
        self.* = Self{
            .allocator = allocator,
            .threads = try allocator.alloc(Thread, thread_count),
            .task_queue = std.fifo.LinearFifo(Task, .Dynamic).init(allocator),
            .queue_mutex = .{},
            .queue_condition = .{},
            .stop_flag = AtomicBool.init(false),
            .is_deinitialized = AtomicBool.init(false),
            .verbose = verbose,
            .pending_tasks = std.atomic.Value(usize).init(0),
            .completion_mutex = .{},
            .completion_condition = .{},
        };
        errdefer self.allocator.free(self.threads);
        errdefer self.task_queue.deinit();

        // Spawn worker threads, each running the workerLoop function.
        for (self.threads, 0..) |*thread, i| {
            thread.* = try Thread.spawn(.{}, workerLoop, .{ self, i });
        }

        return self;
    }

    /// Worker thread loop that continuously processes tasks from the queue.
    /// Each thread runs this function until the pool is stopped.
    ///
    /// Arguments:
    ///   - self: The thread pool instance.
    ///   - worker_id: Unique identifier for the worker thread (for debugging).
    fn workerLoop(self: *Self, worker_id: usize) void {
        while (true) {
            // Attempt to retrieve the next task from the queue.
            const task_opt = self.getNextTask();
            if (task_opt) |task| {
                // Log task execution if verbose mode is enabled.
                if (self.verbose) {
                    std.debug.print("Worker {} executing task\n", .{worker_id});
                }
                // Execute the task's function with its context.
                task.execute_fn(task.context);
                // Decrement the count of pending tasks atomically.
                _ = self.pending_tasks.fetchSub(1, .seq_cst);
                // Signal that a task has completed.
                self.completion_mutex.lock();
                self.completion_condition.signal();
                self.completion_mutex.unlock();
            } else {
                // No tasks remain and stop flag is set; exit the loop.
                return;
            }
        }
    }

    /// Retrieves the next task from the queue, or null if the pool is stopped.
    /// Blocks until a task is available or the pool is shutting down.
    ///
    /// Returns: The next task, or null if the thread should exit.
    fn getNextTask(self: *Self) ?Task {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        // Wait for tasks or a stop signal if the queue is empty.
        while (self.task_queue.readableLength() == 0 and !self.stop_flag.load(.seq_cst)) {
            self.queue_condition.wait(&self.queue_mutex);
        }

        // If the queue is empty and the stop flag is set, return null to exit.
        if (self.task_queue.readableLength() == 0 and self.stop_flag.load(.seq_cst)) {
            return null;
        }

        // Dequeue and return the next task.
        return self.task_queue.readItem() orelse unreachable;
    }

    /// Submits a task to the thread pool for execution.
    ///
    /// Arguments:
    ///   - self: The thread pool instance.
    ///   - task: The task to be executed.
    ///
    /// Returns: An error if the pool is stopped or deinitialized.
    pub fn submit(self: *Self, task: Task) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        // Prevent task submission if the pool is stopped or deinitialized.
        if (self.is_deinitialized.load(.seq_cst) or self.stop_flag.load(.seq_cst)) {
            return error.ThreadPoolStopped;
        }

        // Add the task to the queue and increment the pending task counter.
        try self.task_queue.writeItem(task);
        _ = self.pending_tasks.fetchAdd(1, .seq_cst);
        // Signal a worker thread to process the new task.
        self.queue_condition.signal();
    }

    /// Blocks until all submitted tasks have completed execution.
    /// Uses a condition variable to wait for the pending task count to reach zero.
    pub fn wait(self: *Self) void {
        self.completion_mutex.lock();
        defer self.completion_mutex.unlock();

        // Wait until there are no pending tasks.
        while (self.pending_tasks.load(.seq_cst) > 0) {
            self.completion_condition.wait(&self.completion_mutex);
        }
    }

    /// Shuts down the thread pool, stopping all threads and freeing resources.
    /// Ensures all tasks are completed or discarded before cleanup.
    pub fn deinit(self: *Self) void {
        {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            // Set the stop flag to prevent new tasks and signal threads to exit.
            self.stop_flag.store(true, .seq_cst);
            // Wake all worker threads to check the stop flag.
            self.queue_condition.broadcast();
        }

        // Wait for all worker threads to complete.
        for (self.threads) |thread| {
            thread.join();
        }

        // Free allocated resources.
        self.allocator.free(self.threads);
        self.task_queue.deinit();
        // Mark the pool as deinitialized to prevent further use.
        self.is_deinitialized.store(true, .seq_cst);
        // Destroy the thread pool struct.
        self.allocator.destroy(self);
    }
};
