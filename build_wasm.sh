zig build-exe -target wasm32-freestanding -fno-entry -rdynamic -O ReleaseSmall -femit-bin=wasm-apps/chat_node.wasm wasm-apps/chat_node.zig -I src
