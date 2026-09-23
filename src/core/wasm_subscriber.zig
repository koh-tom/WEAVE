//! WasmSubscriber — 1 つの Wasm プラグインへの配送と、その障害からの復帰を受け持つ。
//!
//! 耐障害の設計 (docs/v1_plan_2026-09.md §12):
//! - 配送はノードが所属するセルの executor 上で行う。trap しても他のセルは止まらない (ADR-009)。
//! - 命令数上限 (P0-1) で無限ループを trap に変える。
//! - trap を起こしたメッセージは指紋 (topic+payload のハッシュ) で隔離し、二度と配送しない (R2)。
//!   `core.node.poison` を発行し、PluginManager.dlq_dir があれば JSONL に記録する。
//! - 再起動は exec_env を破棄してからコールバック末尾で行う。予備インスタンスへの差し替えで
//!   済むので速い (R4, PluginManager.restartPlugin)。
//! - 状態 (SDK の exportState で公開した POD 領域) は on_message が成功した時だけコミットし、
//!   再起動時に書き戻す。毒メッセージによる中途半端な変更は捨てられる (R5)。
//! - 短時間に落ち続けたら breaker を開いて隔離 (quarantined) し、manifest の quarantine_secs 後に
//!   half-open で 1 回だけ試す。成功すれば閉じ、失敗すればまた隔離 (R8)。隔離中に届いた
//!   メッセージはメールボックスに溜め、復帰後に配送する (R3)。

const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const event_bus = @import("event_bus.zig");
const manifest_mod = @import("manifest.zig");
const log = @import("../common/log.zig");

const EventMessage = event_bus.EventMessage;

pub fn fingerprint(topic: []const u8, payload: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x57_45_41_56_45); // "WEAVE"
    h.update(topic);
    h.update(&[_]u8{0});
    h.update(payload);
    return h.final();
}

pub const Breaker = enum { closed, open, half_open, stopped };

/// 隔離中に溜めておくメッセージのコピー
const Buffered = struct {
    msg: EventMessage,
    buf: []u8,

    fn fromMsg(a: std.mem.Allocator, m: *const EventMessage) !Buffered {
        const buf = try a.alloc(u8, m.topic.len + m.payload.len);
        @memcpy(buf[0..m.topic.len], m.topic);
        @memcpy(buf[m.topic.len..], m.payload);
        var copy = m.*;
        copy.topic = buf[0..m.topic.len];
        copy.payload = buf[m.topic.len..];
        return .{ .msg = copy, .buf = buf };
    }

    fn free(self: Buffered, a: std.mem.Allocator) void {
        a.free(self.buf);
    }
};

pub const WasmSubscriber = struct {
    instance: wamr.wasm_module_inst_t,
    node_id: u32,
    bus: *event_bus.EventBus,
    manager: *@import("plugin_manager.zig").PluginManager,
    /// このプラグインが所属するセル (配送はこのセルの executor 上で行われる)
    cell: ?*event_bus.Cell = null,
    mutex: std.Thread.Mutex = .{},

    /// 連続失敗回数 (成功でリセット)
    consecutive_failures: u32 = 0,
    faults_total: u64 = 0,
    restarts_total: u64 = 0,
    /// trap 後の再起動要求。exec_env を破棄してから (callback の末尾で) 実行する。
    /// 旧インスタンスの exec_env が生きている間にインスタンスを破棄しないため。
    restart_pending: bool = false,
    /// on_message 1 回あたりの命令数上限 (manifest `limits.max_instructions`)。0 = 無制限
    max_instructions: u32 = 0,
    /// on_init の命令数上限 (manifest `limits.max_init_instructions`)。0 = 無制限
    max_init_instructions: u32 = 0,

    // --- 再起動ポリシーと breaker (R1/R8) ---
    policy: manifest_mod.RestartPolicy = .always,
    window_ms: i64 = 10_000,
    max_faults: u32 = 5,
    quarantine_ms: i64 = 10_000,
    breaker: Breaker = .closed,
    open_until_ms: i64 = 0,
    fault_times: [16]i64 = [_]i64{0} ** 16,
    fault_pos: usize = 0,

    // --- 毒メッセージ (R2) ---
    poison: std.AutoHashMapUnmanaged(u64, void) = .{},
    poison_skipped: u64 = 0,

    // --- メールボックス (R3) ---
    mailbox: std.ArrayListUnmanaged(Buffered) = .{},
    mailbox_cap: u32 = 256,
    mailbox_dropped: u64 = 0,

    // --- 状態 (R5) ---
    state_ptr: u32 = 0,
    state_len: u32 = 0,
    state_limit: u32 = 4096,
    state_commit: []u8 = &.{},
    state_valid: bool = false,

    /// 直近の再起動にかかった時間 (µs)。差し替え + on_init + 状態の書き戻し
    last_restart_us: u64 = 0,

    // 関数ハンドルキャッシュ
    func_os_alloc: ?wamr.wasm_function_inst_t = null,
    func_on_message: ?wamr.wasm_function_inst_t = null,
    func_get_heap_usage: ?wamr.wasm_function_inst_t = null,
    func_os_reset_heap: ?wamr.wasm_function_inst_t = null,

    // WASM exec_env のスタックサイズ (Zig std.json の再帰に対応)
    const EXEC_ENV_STACK_SIZE: u32 = 128 * 1024;

    pub fn init(instance: wamr.wasm_module_inst_t, node_id: u32, bus: *event_bus.EventBus, manager: *@import("plugin_manager.zig").PluginManager) !WasmSubscriber {
        var sub = WasmSubscriber{
            .instance = instance,
            .node_id = node_id,
            .bus = bus,
            .manager = manager,
        };
        sub.updateInstance(instance);
        return sub;
    }

    /// manifest の limits / restart を反映する
    pub fn applyManifest(self: *WasmSubscriber, m: *const manifest_mod.Manifest) void {
        self.max_instructions = m.limits.max_instructions;
        self.max_init_instructions = m.limits.max_init_instructions;
        self.mailbox_cap = m.limits.mailbox;
        self.state_limit = m.limits.state_bytes;
        self.policy = m.restart.policy;
        self.window_ms = @as(i64, m.restart.window_secs) * 1000;
        self.max_faults = @max(1, m.restart.max_faults);
        self.quarantine_ms = @as(i64, m.restart.quarantine_secs) * 1000;
    }

    pub fn updateInstance(self: *WasmSubscriber, new_inst: wamr.wasm_module_inst_t) void {
        self.instance = new_inst;
        self.func_os_alloc = wamr.wasm_runtime_lookup_function(new_inst, "os_alloc");
        self.func_on_message = wamr.wasm_runtime_lookup_function(new_inst, "on_message");
        self.func_get_heap_usage = wamr.wasm_runtime_lookup_function(new_inst, "os_api_get_heap_usage");
        self.func_os_reset_heap = wamr.wasm_runtime_lookup_function(new_inst, "os_reset_heap");
    }

    /// exec_env に命令数上限を設定する (P0-1)。超過すると "instruction limit exceeded" で trap し、
    /// 通常の trap と同じく fault → 再起動の経路に乗る。上限は wasm_runtime_call_wasm 1 回ごとに効く。
    pub fn setInstructionLimit(env: wamr.wasm_exec_env_t, limit: u32) void {
        const n: c_int = if (limit == 0) -1 else @intCast(@min(limit, std.math.maxInt(c_int)));
        wamr.wasm_runtime_set_instruction_count_limit(env, n);
    }

    pub fn deinit(self: *WasmSubscriber) void {
        const a = self.manager.allocator;
        for (self.mailbox.items) |b| b.free(a);
        self.mailbox.deinit(a);
        self.poison.deinit(a);
        if (self.state_commit.len > 0) a.free(self.state_commit);
        self.state_commit = &.{};
    }

    /// 以後一切配送しない (再起動ポリシー never / 再起動に失敗した時)
    pub fn stop(self: *WasmSubscriber) void {
        self.breaker = .stopped;
        self.restart_pending = false;
        if (self.bus.graph) |g| g.updateNodeStatus(self.node_id, .stopped);
    }

    // ------------------------------------------------------------------
    // 状態 (R5)
    // ------------------------------------------------------------------

    /// on_init の後に呼ぶ: SDK が公開した状態領域を見つけ、初期値をコミットする
    pub fn discoverState(self: *WasmSubscriber, env: wamr.wasm_exec_env_t) void {
        const fp = wamr.wasm_runtime_lookup_function(self.instance, "weave_state_ptr") orelse return;
        const fl = wamr.wasm_runtime_lookup_function(self.instance, "weave_state_len") orelse return;
        var a1 = [_]u32{0};
        var a2 = [_]u32{0};
        if (!wamr.wasm_runtime_call_wasm(env, fp, 0, &a1)) return;
        if (!wamr.wasm_runtime_call_wasm(env, fl, 0, &a2)) return;
        const len = a2[0];
        if (len == 0) return;
        if (len > self.state_limit) {
            log.warn("WasmSubscriber: Node {} state ({d} bytes) exceeds limits.state_bytes ({d}); it will not survive restarts", .{ self.node_id, len, self.state_limit });
            return;
        }
        if (!wamr.wasm_runtime_validate_app_addr(self.instance, a1[0], len)) return;
        const a = self.manager.allocator;
        if (self.state_commit.len != len) {
            if (self.state_commit.len > 0) a.free(self.state_commit);
            self.state_commit = a.alloc(u8, len) catch {
                self.state_commit = &.{};
                return;
            };
        }
        self.state_ptr = a1[0];
        self.state_len = len;
        self.commitState();
    }

    fn commitState(self: *WasmSubscriber) void {
        if (self.state_len == 0) return;
        const native = wamr.wasm_runtime_addr_app_to_native(self.instance, self.state_ptr) orelse return;
        @memcpy(self.state_commit, @as([*]const u8, @ptrCast(native))[0..self.state_len]);
        self.state_valid = true;
    }

    /// 再起動後 (新インスタンスの on_init の後) に、直前にコミットした状態を書き戻す
    pub fn restoreState(self: *WasmSubscriber, env: wamr.wasm_exec_env_t) void {
        if (!self.state_valid or self.state_len == 0) return;
        if (!wamr.wasm_runtime_validate_app_addr(self.instance, self.state_ptr, self.state_len)) return;
        const native = wamr.wasm_runtime_addr_app_to_native(self.instance, self.state_ptr) orelse return;
        @memcpy(@as([*]u8, @ptrCast(native))[0..self.state_len], self.state_commit);
        // 任意の on_restore で、プラグインが書き戻された状態に合わせて後始末できる
        if (wamr.wasm_runtime_lookup_function(self.instance, "on_restore")) |f| {
            setInstructionLimit(env, self.max_init_instructions);
            var argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, f, 0, &argv);
        }
    }

    /// スナップショットから復元したコミット済み状態を設定し、動いているインスタンスにも書き戻す (R7)。
    /// 呼び出し側は self.mutex を持っていること。大きさが合わなければ何もしない (プラグインの版が違う)
    pub fn setCommittedState(self: *WasmSubscriber, bytes: []const u8) bool {
        if (self.state_len == 0 or bytes.len != self.state_len) return false;
        @memcpy(self.state_commit, bytes);
        self.state_valid = true;
        const env = wamr.wasm_runtime_create_exec_env(self.instance, EXEC_ENV_STACK_SIZE);
        if (env == null) return false;
        defer wamr.wasm_runtime_destroy_exec_env(env);
        self.restoreState(env);
        return true;
    }

    pub fn committedState(self: *const WasmSubscriber) ?[]const u8 {
        if (!self.state_valid or self.state_len == 0) return null;
        return self.state_commit;
    }

    // ------------------------------------------------------------------
    // 障害処理 (R1/R2/R8)
    // ------------------------------------------------------------------

    fn faultsInWindow(self: *const WasmSubscriber, now: i64) u32 {
        var n: u32 = 0;
        for (self.fault_times) |t| {
            if (t != 0 and now - t <= self.window_ms) n += 1;
        }
        return n;
    }

    fn setStatus(self: *WasmSubscriber, status: @import("../common/types.zig").NodeStatus) void {
        if (self.bus.graph) |g| {
            g.updateNodeStatus(self.node_id, status);
            var buf: [128]u8 = undefined;
            const payload = std.fmt.bufPrint(&buf, "{{\"node_id\":{},\"status\":\"{s}\"}}", .{ self.node_id, @tagName(status) }) catch "";
            _ = self.bus.publish("core.node.status_changed", payload, .Transient, 0) catch {};
        }
    }

    /// trap を起こしたメッセージを隔離する (R2)
    fn quarantineMessage(self: *WasmSubscriber, msg: *const EventMessage, fp: u64, exception_msg: []const u8) void {
        self.poison.put(self.manager.allocator, fp, {}) catch return;
        var buf: [512]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(.{
            .node_id = self.node_id,
            .topic = msg.topic,
            .fingerprint = fp,
            .exception = exception_msg,
            .ts = std.time.milliTimestamp(),
        }, .{})}) catch return;
        const line = w.buffered();
        _ = self.bus.publish("core.node.poison", line, .Transient, 0) catch {};
        self.manager.appendDlq(self.node_id, line, msg.payload);
    }

    fn handleFault(self: *WasmSubscriber, env: wamr.wasm_exec_env_t, msg: ?*const EventMessage, fp: u64, exception_msg: []const u8) void {
        // 障害分離 (Fault Isolation) 時のフェイルセーフ通知
        var fault_buf: [512]u8 = undefined;
        const fault_payload = std.fmt.bufPrint(&fault_buf, "{{\"node_id\":{},\"exception\":{f}}}", .{ self.node_id, std.json.fmt(exception_msg, .{}) }) catch "";
        if (fault_payload.len > 0) {
            _ = self.bus.publish("core.node.fault", fault_payload, .Transient, self.node_id) catch |err| {
                log.err("WasmSubscriber: Failed to publish fault event: {any}", .{err});
            };
        }

        if (msg) |m| self.quarantineMessage(m, fp, exception_msg);

        // trap したインスタンスのヒープは捨てる (次の再起動で差し替わる)
        if (self.func_os_reset_heap) |reset_func| {
            var reset_argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, reset_func, 0, &reset_argv);
        }

        self.consecutive_failures += 1;
        self.faults_total += 1;
        const now = std.time.milliTimestamp();
        self.fault_times[self.fault_pos] = now;
        self.fault_pos = (self.fault_pos + 1) % self.fault_times.len;

        if (self.policy == .never) {
            log.err("WasmSubscriber: Node {} faulted and its restart policy is 'never'; stopped.", .{self.node_id});
            self.stop();
            return;
        }

        // half-open で試した 1 回がまた落ちた / 短時間に落ち続けている → 隔離 (breaker open)
        if (self.breaker == .half_open or self.faultsInWindow(now) >= self.max_faults) {
            self.breaker = .open;
            self.open_until_ms = now + self.quarantine_ms;
            log.err("WasmSubscriber: Node {} faulted {} times within {} ms; quarantined for {} ms (breaker open).", .{ self.node_id, self.faultsInWindow(now), self.window_ms, self.quarantine_ms });
            self.setStatus(.quarantined);
            return;
        }

        self.setStatus(.restarting);
        log.info("WasmSubscriber: Triggering automatic restart for Node {} (fault {}/{} in window)", .{ self.node_id, self.faultsInWindow(now), self.max_faults });
        self.restart_pending = true;
    }

    fn runPendingRestart(self: *WasmSubscriber) void {
        if (!self.restart_pending) return;
        self.restart_pending = false;
        self.restartNow();
    }

    fn restartNow(self: *WasmSubscriber) void {
        const t0 = std.time.nanoTimestamp();
        self.manager.restartPlugin(self.node_id, self.bus) catch |err| {
            log.err("WasmSubscriber: Auto-restart failed for Node {}: {any}", .{ self.node_id, err });
            return;
        };
        self.restarts_total += 1;
        self.last_restart_us = @intCast(@divTrunc(@max(0, std.time.nanoTimestamp() - t0), 1000));
    }

    // ------------------------------------------------------------------
    // 配送 (EventBus のコールバック。セルの executor スレッド上)
    // ------------------------------------------------------------------

    pub fn callback(ctx: ?*anyopaque, msg: *const EventMessage) void {
        const self: *WasmSubscriber = @ptrCast(@alignCast(ctx orelse return));

        self.mutex.lock();
        defer self.mutex.unlock();
        // exec_env の破棄 (deliver 内の defer) の後に実行される
        defer self.runPendingRestart();

        switch (self.breaker) {
            .stopped => return,
            .open => {
                if (std.time.milliTimestamp() < self.open_until_ms) {
                    self.bufferMsg(msg);
                    return;
                }
                // 隔離期間が明けた: half-open で 1 回だけ試す
                log.info("WasmSubscriber: Node {} quarantine elapsed; trying once (half-open)", .{self.node_id});
                self.breaker = .half_open;
                self.restartNow();
                if (self.breaker == .stopped) return;
                self.bufferMsg(msg);
                self.drainMailbox();
                return;
            },
            .closed, .half_open => {},
        }
        self.deliverChecked(msg);
    }

    fn deliverChecked(self: *WasmSubscriber, msg: *const EventMessage) void {
        const fp = fingerprint(msg.topic, msg.payload);
        if (self.poison.contains(fp)) {
            self.poison_skipped += 1;
            return;
        }
        self.deliver(msg, fp);
    }

    fn bufferMsg(self: *WasmSubscriber, msg: *const EventMessage) void {
        const a = self.manager.allocator;
        if (self.mailbox.items.len >= self.mailbox_cap) {
            // 満杯: BestEffort を古い順に捨てる。無ければ新着を捨てる
            var victim: ?usize = null;
            for (self.mailbox.items, 0..) |b, i| {
                if (b.msg.qos == .BestEffort) {
                    victim = i;
                    break;
                }
            }
            self.mailbox_dropped += 1;
            const i = victim orelse return;
            self.mailbox.items[i].free(a);
            _ = self.mailbox.orderedRemove(i);
        }
        const b = Buffered.fromMsg(a, msg) catch {
            self.mailbox_dropped += 1;
            return;
        };
        self.mailbox.append(a, b) catch {
            b.free(a);
            self.mailbox_dropped += 1;
        };
    }

    fn drainMailbox(self: *WasmSubscriber) void {
        const a = self.manager.allocator;
        while (self.mailbox.items.len > 0) {
            if (self.breaker == .open or self.breaker == .stopped) return;
            const b = self.mailbox.orderedRemove(0);
            defer b.free(a);
            self.deliverChecked(&b.msg);
            // 途中で trap して再起動が予約されたら、差し替えてから続ける
            if (self.restart_pending) self.runPendingRestart();
        }
    }

    fn exceptionMessage(self: *WasmSubscriber) []const u8 {
        const exc = wamr.wasm_runtime_get_exception(self.instance) orelse return "unknown execution trap";
        const raw_exc = std.mem.span(exc);
        if (std.mem.indexOf(u8, raw_exc, "out of memory") != null or std.mem.indexOf(u8, raw_exc, "out_of_memory") != null) {
            return "out_of_memory";
        }
        return raw_exc;
    }

    fn deliver(self: *WasmSubscriber, msg: *const EventMessage, fp: u64) void {
        // 呼び出しスレッドごとにexec_envを作成（WAMRスレッドセーフティ）
        const env = wamr.wasm_runtime_create_exec_env(self.instance, EXEC_ENV_STACK_SIZE);
        if (env == null) return;
        defer wamr.wasm_runtime_destroy_exec_env(env);
        setInstructionLimit(env, self.max_instructions);

        const alloc_func = self.func_os_alloc orelse return;

        // Topicコピー
        var argv_t = [_]u32{@intCast(msg.topic.len)};
        if (!wamr.wasm_runtime_call_wasm(env, alloc_func, 1, &argv_t)) return self.handleFault(env, msg, fp, self.exceptionMessage());
        const t_ptr = argv_t[0];
        if (t_ptr == 0) return self.handleFault(env, msg, fp, "out_of_memory");
        @memcpy(@as([*]u8, @ptrCast(wamr.wasm_runtime_addr_app_to_native(self.instance, t_ptr).?))[0..msg.topic.len], msg.topic);

        // Payloadコピー
        var argv_p = [_]u32{@intCast(msg.payload.len)};
        if (!wamr.wasm_runtime_call_wasm(env, alloc_func, 1, &argv_p)) return self.handleFault(env, msg, fp, self.exceptionMessage());
        const p_ptr = argv_p[0];
        if (p_ptr == 0) return self.handleFault(env, msg, fp, "out_of_memory");
        @memcpy(@as([*]u8, @ptrCast(wamr.wasm_runtime_addr_app_to_native(self.instance, p_ptr).?))[0..msg.payload.len], msg.payload);

        const start_time = std.time.nanoTimestamp();

        if (self.func_on_message) |func| {
            @import("../api/host_api.zig").current_message_timestamp = msg.timestamp;
            @import("../api/host_api.zig").current_message_id = msg.id;
            @import("../api/host_api.zig").current_message_hops = msg.hops;
            defer @import("../api/host_api.zig").current_message_id = 0;
            var msg_argv = [_]u32{ t_ptr, @intCast(msg.topic.len), p_ptr, @intCast(msg.payload.len) };
            if (!wamr.wasm_runtime_call_wasm(env, func, 4, &msg_argv)) {
                const exception_msg = self.exceptionMessage();
                log.err("WasmSubscriber: Execution TRAPPED! Exception: {s}", .{exception_msg});
                return self.handleFault(env, msg, fp, exception_msg);
            }

            const exec_time_ns = std.time.nanoTimestamp() - start_time;

            // メモリサイズ取得 (正確な heap usage を Wasm 側から取得)
            var mem_size: u32 = 0;
            if (self.func_get_heap_usage) |usage_func| {
                var usage_argv = [_]u32{0};
                if (wamr.wasm_runtime_call_wasm(env, usage_func, 0, &usage_argv)) {
                    mem_size = usage_argv[0];
                }
            }

            var metric_buf: [256]u8 = undefined;
            const metric_payload = std.fmt.bufPrint(&metric_buf, "{{\"node_id\":{},\"exec_time_ns\":{},\"memory_bytes\":{}}}", .{ self.node_id, exec_time_ns, mem_size }) catch "";
            if (metric_payload.len > 0) {
                _ = self.bus.publish("core.node.metrics", metric_payload, .BestEffort, self.node_id) catch {};
            }
        }

        // 成功: 状態をコミットし、連続失敗と breaker を戻す
        self.commitState();
        self.consecutive_failures = 0;
        if (self.breaker == .half_open) {
            self.breaker = .closed;
            log.info("WasmSubscriber: Node {} recovered; breaker closed", .{self.node_id});
        }

        if (self.func_os_reset_heap) |reset_func| {
            var reset_argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, reset_func, 0, &reset_argv);
        }
    }
};
