const std = @import("std");

const wamr = @cImport({
    @cInclude("wasm_export.h");
});

pub fn main() !void {
    std.debug.print("========================================\n", .{});
    std.debug.print("   WEAVE: Streaming Event OS Core Daemon\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("Status: Initializing WAMR...\n", .{});

    // 1. Runtime初期化
    var init_args = std.mem.zeroInit(wamr.RuntimeInitArgs, .{
        .mem_alloc_type = wamr.Alloc_With_System_Allocator,
    });

    // WAMRの初期化に失敗した場合
    if (!wamr.wasm_runtime_full_init(&init_args)) {
        std.debug.print("Failed to initialize WASM runtime\n", .{});
        return;
    }
    // WAMRの終了処理
    defer wamr.wasm_runtime_destroy(); // defer: 終了時に自動的に実行される

    // 2. WASMファイルの読み込み
    const wasm_file_path = "wasm-apps/add.wasm";
    const file = try std.fs.cwd().openFile(wasm_file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const allocator = std.heap.page_allocator;
    const wasm_buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(wasm_buffer); // defer: メモリ開放

    const bytes_read = try file.readAll(wasm_buffer);
    if (bytes_read != file_size) {
        std.debug.print("Failed to read complete WASM file\n", .{}); // file_sizeと読み込んだバイト数が一致しない場合
        return;
    }

    // 3. モジュールのロード
    var error_buf: [128]u8 = undefined; // エラーメッセージを格納するバッファ
    const module = wamr.wasm_runtime_load(wasm_buffer.ptr, @intCast(file_size), &error_buf, @intCast(error_buf.len));
    if (module == null) {
        std.debug.print("Failed to load WASM module: {s}\n", .{error_buf}); // エラーメッセージを表示
        return;
    }
    defer wamr.wasm_runtime_unload(module); // defer: モジュールのアンロード

    // 4. モジュールのインスタンス化
    const stack_size: u32 = 8092; // スタックサイズ
    const heap_size: u32 = 8092; // ヒープサイズ
    const module_inst = wamr.wasm_runtime_instantiate(module, stack_size, heap_size, &error_buf, @intCast(error_buf.len));
    if (module_inst == null) {
        std.debug.print("Failed to instantiate WASM module: {s}\n", .{error_buf}); // エラーメッセージを表示
        return;
    }
    defer wamr.wasm_runtime_deinstantiate(module_inst); // defer: モジュールのアンインスタンス化

    // 5. 実行環境の作成
    const exec_env = wamr.wasm_runtime_create_exec_env(module_inst, stack_size);
    if (exec_env == null) {
        std.debug.print("Failed to create execution environment\n", .{});
        return;
    }
    defer wamr.wasm_runtime_destroy_exec_env(exec_env); // defer: 実行環境の破棄

    // 6. 関数検索
    const func = wamr.wasm_runtime_lookup_function(module_inst, "add"); // 関数名から関数を取得
    if (func == null) {
        std.debug.print("Failed to lookup function 'add'\n", .{}); // エラーメッセージを表示
        return;
    }

    // 7. 関数呼び出し
    var argv = [_]u32{ 10, 20 }; // 引数の配列
    if (!wamr.wasm_runtime_call_wasm(exec_env, func, 2, &argv)) {
        std.debug.print("Failed to call WASM function: {s}\n", .{wamr.wasm_runtime_get_exception(module_inst)}); // エラーメッセージを表示
        return;
    }

    const result = argv[0]; // 結果はargv[0]に格納される
    std.debug.print("WASM Call Result: add(10, 20) = {}\n", .{result}); // 結果を表示
    std.debug.print("Status: Success\n", .{}); // 成功メッセージを表示
}

// deferの実行順(記述とは逆順)
// 実行環境の破棄 -> モジュールのアンインスタンス化 -> モジュールのアンロード -> メモリの解放 -> WAMRの終了処理
