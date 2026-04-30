# picoruby-mpu6886 Runtime Gem Modernization Design

Date: 2026-04-30
Author: bash0C7 (with Claude Opus 4.7)
Status: Draft for review

## 1. Background and Goals

`picoruby-mpu6886` is a pure-Ruby MPU6886 6-axis IMU driver for PicoRuby. The
current repo carries dead C code, performs three separate I2C transactions for
`read_all`, and offers only a synchronous polling API. The
[mrubygirls Atom Matrix guide](https://mrubygirls.github.io/guides/esp32/atom_matrix/sensor_g_accel)
has a public reference to `MPU6886.new(i2c)` and `mpu.acceleration`, so the
existing surface must remain wire-compatible.

This redesign formalises the gem as a proper **PicoRuby Runtime Gem** following
upstream `picoruby/picoruby` conventions (cross-checked against `picoruby-aht25`,
`picoruby-psg`, `picoruby-iir_filter`, `picoruby-picotest`), eliminates dead
files, adds a burst snapshot read for atomic and efficient acquisition, and
adds two new opt-in non-blocking acquisition strategies that work on both
mruby/c and microruby (mruby) engines.

### Goals

- Drop the dummy C extension files; ship as pure-Ruby gem matching upstream
  convention (`picoruby-aht25` is the closest analog).
- Preserve the existing public API exactly (mrubygirls compatibility).
- Replace the current 3-transaction `read_all` with a single 14-byte burst.
- Add a new `snapshot` method that exposes the burst read directly.
- Add a `Task`-driven background sampler (`start_sampling` / `stop_sampling` /
  `latest_*`) that runs on both mruby/c and microruby.
- Add a tick-driven cooperative sampler (`tick(now_ms = nil)` / `latest_*`) for
  apps that prefer single-loop ownership.
- Wire up `picoruby-picotest` with `stub`/`mock` against `I2C`.
- Add a `Rakefile` exposing a `rake test` entry point (host-side picoruby).
- Document the new API and combat-proof on real ATOM Matrix hardware.

### Non-goals

- Changing the I2C address, register map, or unit conventions (G, deg/s, °C).
- Sensor fusion / Madgwick / complementary filter (out of scope; downstream
  application concern).
- FIFO / DMP firmware mode of MPU6886 (not exposed by current gem; future work).
- Replacing `sleep_ms` with `Machine.delay_ms`. **`sleep_ms` is already the
  cooperative-yield call** in mruby/c (`mrbgems/picoruby-mrubyc/lib/mrubyc/src/rrt0.c:1507`),
  so existing `sleep_ms` calls in `init_sensor` need no change.

## 2. Compatibility Contract

`mrubygirls` references the following surface and must keep working byte-for-byte:

```ruby
i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000, sda_pin: 25, scl_pin: 21)
mpu = MPU6886.new(i2c)
loop do
  break if button.read == 0
  accel = mpu.acceleration   # Hash: {x: Float, y: Float, z: Float} in G
  sleep_ms 300
end
```

The full preserved API:

| Method | Signature | Behaviour |
| --- | --- | --- |
| `MPU6886.new(i2c)` | positional `i2c` | Synchronous init: WHO_AM_I check, soft reset, default ranges. |
| `acceleration` | → `{x:, y:, z:}` Float (G) | One narrow 6-byte I2C read at `REG_ACCEL_XOUT_H`. |
| `gyroscope` | → `{x:, y:, z:}` Float (deg/s) | One narrow 6-byte I2C read at `REG_GYRO_XOUT_H`. |
| `temperature` | → Float (°C) | One narrow 2-byte I2C read at `REG_TEMP_OUT_H`. |
| `read_all` | → `{accel:, gyro:, temp:}` | **Internally upgraded to a single 14-byte burst** but the return shape is unchanged, so mrubygirls-style code remains correct. |
| `magnitude` | → Float | `Math.sqrt(x²+y²+z²)` over `acceleration`. |
| `tilt_angles` | → `{pitch:, roll:}` | unchanged. |
| `motion_detected?(threshold = 0.1)` | → bool | unchanged. |
| `accel_range=(range)` | range constant | unchanged. |
| `gyro_range=(range)` | range constant | unchanged. |

All existing constants (`ACCEL_RANGE_*`, `GYRO_RANGE_*`, `I2C_ADDRESS`, register
addresses, `CHIP_ID`, scale tables) remain unchanged.

## 3. Architecture

### 3.1 File layout (after redesign)

```
picoruby-mpu6886/
├── mrbgem.rake                       # Pure-Ruby spec, picoruby-i2c dep + picotest test dep
├── mrblib/
│   └── mpu6886.rb                    # Single Ruby file; class + sampler logic
├── sig/
│   └── mpu6886.rbs                   # Updated to reflect new API
├── test/
│   └── mpu6886_test.rb               # picotest, I2C stub-based
├── Rakefile                          # `rake test` host-side runner
├── docs/superpowers/specs/2026-04-30-runtime-gem-modernization-design.md
├── README.md                         # Updated with new API + compatibility note
├── CLAUDE.md                         # New: repo-local rules for future agents
├── LICENSE
└── .gitignore
```

Removed: `src/mpu6886.c`, `include/mpu6886.h`, the empty `src/` and `include/`
directories.

### 3.2 mrbgem.rake (target)

Modeled on `picoruby-aht25/mrbgem.rake` (closest analog: pure-Ruby I2C sensor):

```ruby
MRuby::Gem::Specification.new('picoruby-mpu6886') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'MPU6886 6-axis IMU driver - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-i2c'
  spec.add_test_dependency 'picoruby-picotest'
end
```

### 3.3 Three-tier acquisition model

Three coexisting acquisition modes, all over the same internal `_burst_read`:

```
                ┌────────────────────────────────────┐
                │  _burst_read   →  14 bytes I2C     │
                │  (REG_ACCEL_XOUT_H .. REG_GYRO_ZOUT_L)
                └────────────┬───────────────────────┘
                             │
        ┌────────────────────┼─────────────────────┐
        ▼                    ▼                     ▼
   snapshot()           tick(now_ms)         _run_sampler_loop
   (one-shot)           (single-loop          (background Task,
                         driven)               B-2)
                                               │
   acceleration()       latest_acceleration ◀──┴──── @latest cache
   gyroscope()          latest_gyroscope        │
   temperature()        latest_temperature      │
   read_all()           latest_snapshot         │
   (preserved API)      fresh?                  │
                                                ▼
```

- The narrow methods (`acceleration` etc.) keep their own narrow reads to honour
  the documented "fresh I2C read every call" semantics that mrubygirls users
  depend on.
- `read_all` is internally upgraded to the burst path for atomicity and the ~3×
  saved transactions, but its return shape is unchanged.
- B-2 and B-3 share a single `@latest` snapshot cache plus a `@latest_at_ms`
  timestamp; the only difference is who drives sampling (a Task vs. the host
  loop calling `tick`).

### 3.4 Burst read

MPU6886 places `ACCEL_XOUT_H..ACCEL_ZOUT_L` (0x3B–0x40) immediately followed by
`TEMP_OUT_H..TEMP_OUT_L` (0x41–0x42) and `GYRO_XOUT_H..GYRO_ZOUT_L` (0x43–0x48).
A single 14-byte read at 0x3B captures the full IMU state atomically.

```
def snapshot
  data = read_reg(REG_ACCEL_XOUT_H, 14)
  ax = to_signed_16bit((data[0] << 8) | data[1])
  ay = to_signed_16bit((data[2] << 8) | data[3])
  az = to_signed_16bit((data[4] << 8) | data[5])
  rt = to_signed_16bit((data[6] << 8) | data[7])
  gx = to_signed_16bit((data[8] << 8) | data[9])
  gy = to_signed_16bit((data[10] << 8) | data[11])
  gz = to_signed_16bit((data[12] << 8) | data[13])
  {
    accel: { x: ax / @accel_scale, y: ay / @accel_scale, z: az / @accel_scale },
    gyro:  { x: gx / @gyro_scale,  y: gy / @gyro_scale,  z: gz / @gyro_scale  },
    temp:  rt / 326.8 + 25.0
  }
end

def read_all
  snapshot
end
```

### 3.5 Background sampler Task (B-2)

The Task spawn must work on both `RUBY_ENGINE == "mruby/c"` (mruby/c VM, used by
R2P2-ESP32) and the microruby branch (`mruby`, used by host-side picotest runs).
The dual-engine pattern is taken verbatim from
`mrbgems/picoruby-psg/mrblib/driver.rb:188-206`:

```ruby
def start_sampling(interval_ms: 20)
  return @sampler_task if @sampler_task
  @sampler_interval_ms = interval_ms
  @sampler_running = true
  @latest = nil
  @latest_at_ms = 0
  if RUBY_ENGINE == "mruby/c"
    $__mpu6886_sampler_target = self
    mrb = PicoRubyVM::InstructionSequence.compile(
      '$__mpu6886_sampler_target._run_sampler_loop'
    ).to_binary
    @sampler_task = Task.create(mrb)
    raise "MPU6886: failed to create sampler task" if @sampler_task.nil?
    @sampler_task.run
  else
    mpu = self
    @sampler_task = Task.new { mpu._run_sampler_loop }
  end
  @sampler_task
end

def stop_sampling
  return unless @sampler_task
  @sampler_running = false
  @sampler_task.join
  @sampler_task = nil
end

# Public-but-private-by-convention; called by the spawned Task only.
def _run_sampler_loop
  while @sampler_running
    snap = snapshot
    @latest = snap
    @latest_at_ms = _now_ms
    sleep_ms(@sampler_interval_ms)
  end
end
```

Default `interval_ms: 20` (50 Hz) gives a useful default for human-scale motion
work without saturating I2C.

The loop terminates cleanly on `stop_sampling` because:
1. The host sets `@sampler_running = false`.
2. The current `sleep_ms` returns; the `while` exits.
3. `stop_sampling` `join`s and clears the handle.

`_now_ms` uses `Machine.uptime_us / 1000` if `Machine` is loaded, else falls
back to `0` (host-side test paths stub it). Implementation detail in section 4.

### 3.6 Tick-driven sampler (B-3)

For apps that own their own loop and don't want a Task:

```ruby
def tick(now_ms = nil)
  now_ms ||= _now_ms
  return false if @latest_at_ms > 0 && (now_ms - @latest_at_ms) < @sampler_interval_ms
  @latest = snapshot
  @latest_at_ms = now_ms
  true
end

def configure_sampling(interval_ms: 20)
  @sampler_interval_ms = interval_ms
end
```

The `init_sensor` body must seed sampler state so `tick` is callable from a
fresh instance without relying on uninitialised-ivar nil semantics:

```ruby
@latest = nil
@latest_at_ms = 0
@sampler_interval_ms = 20
@sampler_task = nil
@sampler_running = false
```

`@latest_at_ms = 0` flags "never sampled"; the guard `@latest_at_ms > 0`
forces the first `tick` call to always take a sample. Subsequent calls honour
the configured interval.

Returns `true` when a fresh sample was taken, `false` when the call was a
no-op. App pattern:

```ruby
mpu = MPU6886.new(i2c)
mpu.configure_sampling(interval_ms: 20)
loop do
  if mpu.tick
    accel = mpu.latest_acceleration
    # ... LED / UART / display work ...
  end
  sleep_ms 5
end
```

### 3.7 Cached accessors (shared by B-2 and B-3)

```ruby
def latest_snapshot     ; @latest end
def latest_acceleration ; @latest && @latest[:accel] end
def latest_gyroscope    ; @latest && @latest[:gyro]  end
def latest_temperature  ; @latest && @latest[:temp]  end
def fresh?              ; !@latest.nil? end
```

If neither `start_sampling` nor `tick` has been called, `latest_*` returns
`nil` and `fresh?` returns `false`. Callers must check `fresh?` (or the `nil`
return) before consuming. This is documented in the README.

## 4. Implementation Notes

### 4.1 PicoRuby compatibility constraints

Per global `~/CLAUDE.md`, avoid: `defined?`, `Hash#fetch`, `String#reverse`,
`String#rjust`, inline `rescue`, `proc`, `lambda`. The current code already
complies; the redesign keeps the same discipline.

`RUBY_ENGINE` is a constant (not a `defined?` check) and is used the same way
in upstream `picoruby-psg`, so it is safe.

### 4.2 `Machine` dependency

`_now_ms` requires a millisecond clock. Two implementation choices, evaluated
in order at call time:

```ruby
def _now_ms
  if Object.const_defined?(:Machine)
    Machine.uptime_us / 1000
  else
    0  # host-side tests inject ticks manually via `tick(now_ms)`
  end
end
```

This avoids `defined?(Machine)` (which the global rules prohibit). On host-side
picotest runs, the test always passes an explicit `now_ms` to `tick`, so the
fallback `0` is never hit on the read path.

We do **not** add `picoruby-machine` to `mrbgem.rake` dependencies — it would
forbid host-side picotest from running. Instead, `Machine.uptime_us` is treated
as an optional integration: present on R2P2-ESP32, absent in tests.

### 4.3 `Task` dependency in mrbgem.rake

`Task` (mruby/c built-in) and `PicoRubyVM::InstructionSequence` are both core
PicoRuby facilities, not opt-in gems. They do not need to appear in
`add_dependency`. Verified by reading
`mrbgems/picoruby-psg/mrbgem.rake` — it does not declare a Task dependency yet
uses `Task.create` heavily.

### 4.4 RBS updates (`sig/mpu6886.rbs`)

Add types for the new methods:

```rbs
type vector_hash = { x: Float, y: Float, z: Float }
type sensor_data = { accel: vector_hash, gyro: vector_hash, temp: Float }

def snapshot: () -> sensor_data
def start_sampling: (?interval_ms: Integer) -> Task
def stop_sampling: () -> void
def configure_sampling: (?interval_ms: Integer) -> void
def tick: (?Integer | nil now_ms) -> bool
def latest_snapshot: () -> (sensor_data | nil)
def latest_acceleration: () -> (vector_hash | nil)
def latest_gyroscope: () -> (vector_hash | nil)
def latest_temperature: () -> (Float | nil)
def fresh?: () -> bool
def _run_sampler_loop: () -> void
def _now_ms: () -> Integer
```

The `Task` reference in `start_sampling` typing needs `class Task` to exist in
sig. Either declare it locally in `sig/mpu6886.rbs` or rely on the picoruby-mruby
provided sig. We will declare a minimal forward-decl in this file:

```rbs
class Task end  # forward-decl; full type in picoruby-mruby/sig/task.rbs
```

### 4.5 Tests (`test/mpu6886_test.rb`)

Test plan:
1. `MPU6886.new(i2c)` happy path — verifies WHO_AM_I read, soft-reset write,
   default range writes. Uses `stub_any_instance_of(I2C)`.
2. `acceleration` — verifies one 6-byte read at `REG_ACCEL_XOUT_H` and correct
   sign-extension and scaling.
3. `read_all` — verifies it now does a **single** 14-byte read at
   `REG_ACCEL_XOUT_H` (regression guard for the burst upgrade).
4. `snapshot` — same as `read_all` but checks the explicit return shape.
5. `tick(now_ms)` — verifies sample-vs-no-op behaviour across the configured
   interval boundary; verifies `latest_*` populated.
6. `motion_detected?` — verifies threshold logic on stubbed acceleration.
7. `accel_range=` / `gyro_range=` — verifies the right register write and
   internal scale update.

Background sampler (`start_sampling`) is **not** unit-tested (it requires a
running mruby/c task scheduler that picotest does not bring up host-side). It
is verified via the combat-proof step on real hardware (section 6).

`Rakefile`:

```ruby
require "rake/testtask"

PICORUBY_BIN = ENV["PICORUBY"] || `which picoruby`.chomp

desc "Run picotest test suite"
task :test do
  test_dir = File.expand_path("test", __dir__)
  raise "picoruby binary not found; set PICORUBY=/path/to/picoruby" if PICORUBY_BIN.empty?
  sh %(#{PICORUBY_BIN} -e 'require "picotest"; Picotest::Runner.run("#{test_dir}")')
end

task default: :test
```

(Reference: `mrbgems/picoruby-funicular/Rakefile` shows a Rake::TestTask
host-side pattern, though picotest invocation differs.)

### 4.6 Combat-proof plan (real ATOM Matrix)

1. Update R2P2-ESP32 `build_config/xtensa-esp.rb` (in `picoruby-recipes`) to
   point this gem to the post-merge commit on `main`.
2. Build R2P2-ESP32 firmware (user runs `rake build` / `rake flash`; agent does
   not run them).
3. Run `imu.rb` unchanged on the device — verifies mrubygirls compatibility
   (existing `MPU6886.new(i2c)` + `mpu.acceleration`).
4. Run new `imu_async.rb` (added to `picoruby-recipes/components/R2P2-ESP32/storage/home/`) —
   verifies `start_sampling` + `latest_acceleration` flow with concurrent LED
   work on the WS2812 matrix.
5. Capture serial output via `rake monitor` and confirm:
   - `imu.rb` produces identical-shape output to current behaviour.
   - `imu_async.rb` shows the LED loop never starves while sensor samples
     keep flowing in background.

The `imu_async.rb` reference example (added to `picoruby-recipes`):

```ruby
require 'mpu6886'

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000, sda_pin: 25, scl_pin: 21)
mpu = MPU6886.new(i2c)
mpu.accel_range = MPU6886::ACCEL_RANGE_4G
mpu.gyro_range  = MPU6886::GYRO_RANGE_2000DPS
mpu.start_sampling(interval_ms: 20)

loop do
  accel = mpu.latest_acceleration
  if accel
    puts "X=#{(accel[:x] * 100).to_i / 100.0} Y=#{(accel[:y] * 100).to_i / 100.0} Z=#{(accel[:z] * 100).to_i / 100.0}"
  end
  sleep_ms 500   # main loop runs slowly while sampler keeps fresh data ready
end
```

## 5. README.md restructure

The new README sections (in order):

1. Overview + mrubygirls compatibility statement (the existing API is
   guaranteed forward).
2. Quick Start (existing example, unchanged).
3. **New: Efficient batch read** — `snapshot` example.
4. **New: Background sampler** — `start_sampling` / `latest_acceleration`
   example, with the dual-engine note.
5. **New: Tick-driven sampler** — `tick` / `latest_*` example.
6. API Reference (full list, including the new methods).
7. Motion analysis (existing, unchanged).
8. Error handling (existing, unchanged).
9. Development / Testing — describes `rake test`.
10. License.

## 6. CLAUDE.md (new, repo-root)

Adds repo-local rules for future Claude Code sessions on this repo:

- PicoRuby Runtime Gem conventions (pure Ruby, no C, modeled on picoruby-aht25).
- mrubygirls compatibility contract — public API is frozen.
- Test runner: `rake test` (host-side picoruby + picotest).
- Combat-proof location: `picoruby-recipes/components/R2P2-ESP32/storage/home/imu*.rb`.
- Task-spawn pattern for any future async features (the
  `RUBY_ENGINE == "mruby/c"` branch).
- Forbidden methods (inherited from global): `defined?`, `Hash#fetch`,
  `String#reverse`, `String#rjust`, inline `rescue`, `proc`, `lambda`.

## 7. Risks and Open Questions

- **Q1**: `PicoRubyVM::InstructionSequence.compile(...).to_binary` requires the
  `picoruby-picorubyvm` gem to be in the firmware build. Verified present in
  R2P2-ESP32 default build via `picoruby/picoruby/mrbgems/picoruby-picorubyvm/`.
  Does the `picoruby-recipes` build include it? *Action:* check in implementation
  phase before claiming combat-proof success.

- **Q2**: `picotest` host-side may not load `I2C` at all (it's a hardware-side
  class). Tests must declare a stub class `class I2C; end` at the top of
  `mpu6886_test.rb` and use `stub_any_instance_of(I2C)` against it. Verified
  pattern in `mrbgems/picoruby-i2c/test/` (if present) — *Action:* check during
  implementation; fall back to a manual fake double if `stub_any_instance_of`
  needs the real I2C class.

- **Q3**: When `start_sampling` is called and then a synchronous `acceleration`
  is also called from the host loop, two tasks contend for the same I2C bus.
  PicoRuby `picoruby-i2c` does not document mutex protection. *Mitigation:*
  README explicitly warns to choose one acquisition strategy at a time
  (snapshot/sync OR background sampler). Cross-strategy use is undefined.

- **Q4**: Host-side `Task.new { ... }` requires the microruby Task scheduler to
  be running (`Task.run` or `mruby` driving it). Picotest tests will **not**
  exercise `start_sampling`. This is captured in the combat-proof split (sec 4.6)
  and is a deliberate non-goal for unit tests.

- **Q5**: Without `Machine` available, `_now_ms` returns `0`, so `_run_sampler_loop`
  writes `@latest_at_ms = 0` on every iteration. This is harmless because B-2
  consumers use `latest_*` accessors which ignore the timestamp; only B-3's
  `tick` reads the timestamp, and mixing B-2 and B-3 simultaneously is already
  ruled out under Q3. README notes this constraint in the background-sampler
  section.

## 8. Summary of file changes

| Path | Change |
| --- | --- |
| `src/mpu6886.c` | DELETE |
| `include/mpu6886.h` | DELETE |
| `src/`, `include/` | DELETE empty dirs |
| `mrbgem.rake` | Replace contents (per §3.2) |
| `mrblib/mpu6886.rb` | Edit: add `snapshot`, `read_all` rewrite, `tick`, `start/stop_sampling`, `latest_*`, `_run_sampler_loop`, `_now_ms`. Existing public methods unchanged. |
| `sig/mpu6886.rbs` | Edit: add new method signatures. |
| `test/mpu6886_test.rb` | NEW |
| `Rakefile` | NEW |
| `README.md` | Edit: add new sections, keep existing examples. |
| `CLAUDE.md` | NEW (repo-local rules) |
| `docs/superpowers/specs/2026-04-30-runtime-gem-modernization-design.md` | NEW (this file) |
| `picoruby-recipes/components/R2P2-ESP32/storage/home/imu_async.rb` | NEW (combat-proof example) |
