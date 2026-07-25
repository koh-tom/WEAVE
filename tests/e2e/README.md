# WEAVE End-to-End (E2E) Testing

This directory contains E2E tests for the WEAVE streaming event OS.

## Tests

### 1. Kusa Pipeline E2E Test (`kusa_pipeline.sh`)

This script validates the "Kusa" trigger pipeline, including comments monitoring, triggering the OBS overlay effect, auto-hide timer, and the 15-second cooldown safety constraint.

#### What it tests:
1. **Trigger Condition**: When 10 comments matching the "Kusa" pattern ("草", "w", etc.) arrive within a 3-second window, WEAVE triggers the OBS scene item visible state to `true` (`"sceneItemEnabled":true`).
2. **Auto-hide**: After exactly 10 seconds, the effect is automatically disabled (`"sceneItemEnabled":false`).
3. **15-second Cooldown**: Any comments arriving within a 15-second window from the initial trigger do not cause a re-trigger, even if the threshold of 10 comments is reached.
4. **Cooldown Reset**: Once the 15-second cooldown period has expired, a subsequent burst of 10 comments triggers the effect again.

#### How to run:
First, ensure that the project is built (both the native binary and the WebAssembly plugins):
```bash
# Build the project
zig build
zig build wasm

# Run the E2E script
./tests/e2e/kusa_pipeline.sh
```
