# picoruby-mpu6886 Runtime Gem Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modernize `picoruby-mpu6886` into a clean PicoRuby Runtime Gem with a 14-byte burst snapshot, opt-in background sampler Task, opt-in tick-driven sampler, host-side test suite, and combat-proof on a real ATOM Matrix — without breaking the mrubygirls Atom Matrix guide API.

**Architecture:** Pure Ruby gem (no C). The existing `acceleration` / `gyroscope` / `temperature` / `read_all` API is preserved. Three internally-shared acquisition tiers built on a single `_burst_read`: `snapshot` (one-shot), `tick(now_ms)` (host-loop driven), and `start_sampling` (background `Task` using the `RUBY_ENGINE == "mruby/c"` dual-engine pattern from picoruby-psg). Cached values exposed via `latest_*` accessors.

**Tech Stack:**
- PicoRuby (mruby/c on R2P2-ESP32, microruby on host)
- Pure Ruby implementation in `mrblib/`, RBS in `sig/`
- `picoruby-i2c` (runtime dep), `picoruby-picotest` (declared test dep for on-device runs)
- Host development tests: CRuby 4.0.1 + `test-unit` (matches `~/CLAUDE.md` "rake testでテスト実施" rule, since host has no `picoruby` binary)
- Combat-proof: ATOM Matrix (ESP32-PICO-D4) + R2P2-ESP32 firmware via `picoruby-recipes`

**Spec:** [docs/superpowers/specs/2026-04-30-runtime-gem-modernization-design.md](../specs/2026-04-30-runtime-gem-modernization-design.md)

---

## File Structure (post-merge)

```
picoruby-mpu6886/
├── mrbgem.rake                # Pure-Ruby spec, picoruby-i2c + picotest test dep
├── mrblib/mpu6886.rb          # Single class file: existing API + new methods
├── sig/mpu6886.rbs            # Updated RBS for new API
├── test/mpu6886_test.rb       # test-unit, CRuby-runnable, FakeI2C double
├── Rakefile                   # `rake test` host-side runner
├── Gemfile                    # test-unit gem pin (host-only)
├── README.md                  # Updated with new API examples + compatibility note
├── CLAUDE.md                  # NEW (repo-local rules)
├── docs/superpowers/specs/    # Already committed
├── docs/superpowers/plans/    # This file
├── LICENSE
└── .gitignore                 # Add /vendor/, /.bundle/

DELETED:
├── src/mpu6886.c              # Dummy C entry points
├── include/mpu6886.h          # Empty header
├── src/                       # Empty dir
└── include/                   # Empty dir

Outside this repo (combat-proof additions in ~/dev/src/github.com/bash0C7/picoruby-recipes):
└── components/R2P2-ESP32/storage/home/imu_async.rb   # NEW reference example
```

**Test design philosophy.** Host tests use a hand-rolled `FakeI2C` double (records every read/write call and serves canned response bytes from a queue) instead of stub/mock libraries — assertions on the recording are explicit, robust, and free of mock-library coupling. `sleep_ms` is shadowed in the test file with a no-op so `init_sensor` runs synchronously on CRuby. `Task` and `RUBY_ENGINE == "mruby/c"` paths are NOT host-tested — they are validated on-device in tasks 13–14.

**TDD discipline.** Per `~/CLAUDE.md`, RED / GREEN / REFACTOR are independent commits. Tasks below show the RED commit, GREEN commit, and (where useful) REFACTOR commit explicitly.

---

## Task 1: Bootstrap host test harness

**Files:**
- Create: `Gemfile`
- Create: `Rakefile`
- Create: `test/mpu6886_test.rb`
- Create: `.gitignore` (extend)

- [ ] **Step 1.1: Write `Gemfile` pinning test-unit**

```ruby
# Gemfile
source "https://rubygems.org"

gem "test-unit", "~> 3.6"
```

- [ ] **Step 1.2: Run bundle install with local path**

```bash
bundle config set --local path 'vendor/bundle'
bundle install
```

Expected: `Bundle complete!` with test-unit installed under `vendor/bundle`.

- [ ] **Step 1.3: Extend `.gitignore`**

Append (do not replace):

```
/vendor/
/.bundle/
```

- [ ] **Step 1.4: Write `Rakefile`**

```ruby
# Rakefile
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "mrblib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end

task default: :test
```

- [ ] **Step 1.5: Write a smoke test in `test/mpu6886_test.rb`**

```ruby
# test/mpu6886_test.rb
$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)

# PicoRuby shim: sleep_ms is a Kernel-level method on-device.
# Under CRuby it does not exist; stub it as a no-op for host tests.
module Kernel
  def sleep_ms(_ms); end
end

require "test/unit"

class FakeI2C
  attr_reader :writes, :reads

  def initialize
    @writes = []
    @reads = []
    @read_queue = []
  end

  # Queue a canned response (a String of bytes) for the next read call.
  def queue_read(bytes)
    @read_queue << bytes
  end

  def write(addr, *args, **opts)
    @writes << { addr: addr, args: args, opts: opts }
    args.size
  end

  def read(addr, length, reg = nil, **opts)
    @reads << { addr: addr, length: length, reg: reg, opts: opts }
    @read_queue.shift || ("\x00".b * length)
  end
end

class HarnessTest < Test::Unit::TestCase
  def test_fake_i2c_records_writes
    i2c = FakeI2C.new
    i2c.write(0x68, 0x6B, 0x00)
    assert_equal 1, i2c.writes.size
    assert_equal 0x68, i2c.writes.first[:addr]
  end

  def test_fake_i2c_serves_queued_reads
    i2c = FakeI2C.new
    i2c.queue_read("\x19".b)
    bytes = i2c.read(0x68, 1, 0x75)
    assert_equal "\x19", bytes.b
    assert_equal 1, i2c.reads.size
  end
end
```

- [ ] **Step 1.6: Run the smoke test, expect PASS**

Run: `bundle exec rake test`
Expected: 2 tests, 0 failures.

- [ ] **Step 1.7: Commit (chore — harness scaffolding, not spec-driven yet)**

```bash
git add Gemfile Rakefile .gitignore test/mpu6886_test.rb
git commit -m "chore: bootstrap host test harness (test-unit + FakeI2C + Rakefile)"
```

---

## Task 2: Delete dead C extension files

**Files:**
- Delete: `src/mpu6886.c`
- Delete: `include/mpu6886.h`
- Delete: `src/` (empty after file removal)
- Delete: `include/` (empty after file removal)

- [ ] **Step 2.1: Delete the C source and header**

```bash
git rm src/mpu6886.c include/mpu6886.h
rmdir src include
```

- [ ] **Step 2.2: Verify `mrbgem.rake` does not reference them**

Run: `grep -nE 'src/|include/|mpu6886\.c|mpu6886\.h' mrbgem.rake`
Expected: no matches.

- [ ] **Step 2.3: Commit**

```bash
git add -A
git commit -m "chore: remove dummy C extension files (pure-Ruby gem)"
```

---

## Task 3: Modernize `mrbgem.rake`

**Files:**
- Modify: `mrbgem.rake`

- [ ] **Step 3.1: Replace `mrbgem.rake` contents**

```ruby
# mrbgem.rake
MRuby::Gem::Specification.new('picoruby-mpu6886') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'MPU6886 6-axis IMU driver - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-i2c'
  spec.add_test_dependency 'picoruby-picotest'
end
```

- [ ] **Step 3.2: Verify `bundle exec rake test` still passes**

Run: `bundle exec rake test`
Expected: 2 tests, 0 failures (harness still green).

- [ ] **Step 3.3: Commit**

```bash
git add mrbgem.rake
git commit -m "chore: align mrbgem.rake with picoruby-aht25 conventions"
```

---

## Task 4: RED — failing test for `init_sensor` seeding sampler state

**Files:**
- Modify: `test/mpu6886_test.rb`

- [ ] **Step 4.1: Append a sampler-state initialization test to `test/mpu6886_test.rb`**

Add this class to the bottom of the file (above the final `end` of any module if applicable — in our case append to top level):

```ruby
require "mpu6886"

class MPU6886InitSamplerStateTest < Test::Unit::TestCase
  def setup
    @i2c = FakeI2C.new
    # WHO_AM_I returns CHIP_ID 0x19
    @i2c.queue_read("\x19".b)
    @mpu = MPU6886.new(@i2c)
  end

  def test_latest_is_nil_after_init
    assert_nil @mpu.instance_variable_get(:@latest)
  end

  def test_latest_at_ms_is_zero_after_init
    assert_equal 0, @mpu.instance_variable_get(:@latest_at_ms)
  end

  def test_default_sampler_interval_ms_is_20
    assert_equal 20, @mpu.instance_variable_get(:@sampler_interval_ms)
  end

  def test_sampler_task_is_nil_after_init
    assert_nil @mpu.instance_variable_get(:@sampler_task)
  end

  def test_sampler_running_is_false_after_init
    assert_equal false, @mpu.instance_variable_get(:@sampler_running)
  end
end
```

- [ ] **Step 4.2: Run the test, expect FAIL**

Run: `bundle exec rake test TESTOPTS='--name=/MPU6886InitSamplerState/'`
Expected: 5 failures (instance vars not set).

- [ ] **Step 4.3: Commit RED**

```bash
git add test/mpu6886_test.rb
git commit -m "test: add failing spec for init_sensor seeding sampler state"
```

---

## Task 5: GREEN — seed sampler state in `init_sensor`

**Files:**
- Modify: `mrblib/mpu6886.rb:162-180` (the `init_sensor` private method)

- [ ] **Step 5.1: Add the five sampler-state ivar initializations to `init_sensor`**

Edit `mrblib/mpu6886.rb` `init_sensor` so it reads:

```ruby
  # Initialize sensor
  def init_sensor
    # Sampler state seeds (must precede any read; tick/start_sampling rely on them)
    @latest = nil
    @latest_at_ms = 0
    @sampler_interval_ms = 20
    @sampler_task = nil
    @sampler_running = false

    # Check chip ID
    chip_id = read_reg(REG_WHO_AM_I, 1)[0]
    raise "Invalid MPU6886 chip ID: 0x#{chip_id.to_s(16)} (expected: 0x#{CHIP_ID.to_s(16)})" unless chip_id == CHIP_ID

    # Reset device
    write_reg(REG_PWR_MGMT_1, 0x80)
    sleep_ms 100

    # Exit sleep mode
    write_reg(REG_PWR_MGMT_1, 0x00)
    sleep_ms 10

    # Default settings
    self.accel_range = ACCEL_RANGE_2G
    self.gyro_range = GYRO_RANGE_250DPS

    sleep_ms 10
  end
```

- [ ] **Step 5.2: Run the test, expect PASS**

Run: `bundle exec rake test TESTOPTS='--name=/MPU6886InitSamplerState/'`
Expected: 5 tests, 0 failures.

- [ ] **Step 5.3: Commit GREEN**

```bash
git add mrblib/mpu6886.rb
git commit -m "feat: seed sampler state in init_sensor"
```

---

## Task 6: RED — failing test for `snapshot` (14-byte burst)

**Files:**
- Modify: `test/mpu6886_test.rb`

- [ ] **Step 6.1: Append snapshot test class**

```ruby
class MPU6886SnapshotTest < Test::Unit::TestCase
  def setup
    @i2c = FakeI2C.new
    @i2c.queue_read("\x19".b)            # WHO_AM_I
    @mpu = MPU6886.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_snapshot_issues_one_14_byte_read_at_accel_xout_h
    # 14-byte canned payload: ax=1g, ay=0, az=0, temp=0, gx=0, gy=0, gz=0
    # ACCEL_RANGE_2G scale = 16384 → 1g = 0x4000 = 16384
    payload = [
      0x40, 0x00,   # ax = 16384  -> 1.0g
      0x00, 0x00,   # ay = 0
      0x00, 0x00,   # az = 0
      0x00, 0x00,   # temp_raw = 0 -> 25.0°C
      0x00, 0x00,   # gx = 0
      0x00, 0x00,   # gy = 0
      0x00, 0x00,   # gz = 0
    ].pack("C*")
    @i2c.queue_read(payload)

    snap = @mpu.snapshot

    assert_equal 1, @i2c.reads.size, "expected exactly one I2C read"
    r = @i2c.reads.first
    assert_equal 0x68,  r[:addr]
    assert_equal 14,    r[:length]
    assert_equal 0x3B,  r[:reg], "burst must start at REG_ACCEL_XOUT_H"

    assert_in_delta 1.0, snap[:accel][:x], 1e-6
    assert_in_delta 0.0, snap[:accel][:y], 1e-6
    assert_in_delta 0.0, snap[:accel][:z], 1e-6
    assert_in_delta 25.0, snap[:temp], 1e-6
    assert_in_delta 0.0, snap[:gyro][:x], 1e-6
  end

  def test_snapshot_handles_negative_axis_values
    payload = [
      0xC0, 0x00,   # ax = 0xC000 -> -16384 -> -1.0g at ±2G
      0x00, 0x00, 0x00, 0x00,   # ay, az
      0x00, 0x00,               # temp
      0xFF, 0x80,               # gx = -128 -> -128/131.0 deg/s
      0x00, 0x00, 0x00, 0x00,   # gy, gz
    ].pack("C*")
    @i2c.queue_read(payload)

    snap = @mpu.snapshot

    assert_in_delta(-1.0, snap[:accel][:x], 1e-6)
    assert_in_delta(-128.0 / 131.0, snap[:gyro][:x], 1e-6)
  end
end
```

- [ ] **Step 6.2: Run, expect FAIL**

Run: `bundle exec rake test TESTOPTS='--name=/MPU6886Snapshot/'`
Expected: 2 errors — `NoMethodError: undefined method 'snapshot'`.

- [ ] **Step 6.3: Commit RED**

```bash
git add test/mpu6886_test.rb
git commit -m "test: add failing spec for 14-byte burst snapshot"
```

---

## Task 7: GREEN — implement `snapshot`

**Files:**
- Modify: `mrblib/mpu6886.rb` (add public method `snapshot` between `read_all` and `magnitude`)

- [ ] **Step 7.1: Add `snapshot` to the public API**

Insert before `# Calculate combined acceleration` block:

```ruby
  # Get all sensor data atomically via a single 14-byte I2C burst.
  # Reads REG_ACCEL_XOUT_H..REG_GYRO_ZOUT_L (0x3B..0x48) in one transaction.
  # @return [Hash] { accel: {x:, y:, z:}, gyro: {x:, y:, z:}, temp: Float }
  def snapshot
    data = read_reg(REG_ACCEL_XOUT_H, 14)
    raw_ax = to_signed_16bit((data[0] << 8) | data[1])
    raw_ay = to_signed_16bit((data[2] << 8) | data[3])
    raw_az = to_signed_16bit((data[4] << 8) | data[5])
    raw_t  = to_signed_16bit((data[6] << 8) | data[7])
    raw_gx = to_signed_16bit((data[8] << 8) | data[9])
    raw_gy = to_signed_16bit((data[10] << 8) | data[11])
    raw_gz = to_signed_16bit((data[12] << 8) | data[13])

    {
      accel: {
        x: raw_ax / @accel_scale,
        y: raw_ay / @accel_scale,
        z: raw_az / @accel_scale,
      },
      gyro: {
        x: raw_gx / @gyro_scale,
        y: raw_gy / @gyro_scale,
        z: raw_gz / @gyro_scale,
      },
      temp: raw_t / 326.8 + 25.0,
    }
  end
```

- [ ] **Step 7.2: Run snapshot tests, expect PASS**

Run: `bundle exec rake test TESTOPTS='--name=/MPU6886Snapshot/'`
Expected: 2 tests, 0 failures.

- [ ] **Step 7.3: Run full suite, expect all PASS**

Run: `bundle exec rake test`
Expected: harness + init + snapshot = 9 tests, 0 failures.

- [ ] **Step 7.4: Commit GREEN**

```bash
git add mrblib/mpu6886.rb
git commit -m "feat: implement snapshot via 14-byte I2C burst"
```

---

## Task 8: RED — failing test for `read_all` regression (must use single burst)

**Files:**
- Modify: `test/mpu6886_test.rb`

- [ ] **Step 8.1: Append read_all regression test**

```ruby
class MPU6886ReadAllBurstTest < Test::Unit::TestCase
  def setup
    @i2c = FakeI2C.new
    @i2c.queue_read("\x19".b)
    @mpu = MPU6886.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_read_all_uses_single_14_byte_burst_not_three_reads
    @i2c.queue_read(("\x00".b * 14))

    result = @mpu.read_all

    assert_equal 1, @i2c.reads.size,
      "read_all must do exactly one I2C transaction (was three)"
    assert_equal 14, @i2c.reads.first[:length]
    assert_equal 0x3B, @i2c.reads.first[:reg]

    # Return shape must be backward compatible
    assert_kind_of Hash, result
    assert_kind_of Hash, result[:accel]
    assert result[:accel].key?(:x)
    assert result[:accel].key?(:y)
    assert result[:accel].key?(:z)
    assert_kind_of Hash, result[:gyro]
    assert_kind_of Float, result[:temp]
  end
end
```

- [ ] **Step 8.2: Run, expect FAIL**

Run: `bundle exec rake test TESTOPTS='--name=/MPU6886ReadAllBurst/'`
Expected: 1 failure — `read_all` currently does 3 separate I2C reads (asserted size 1, got 3).

- [ ] **Step 8.3: Commit RED**

```bash
git add test/mpu6886_test.rb
git commit -m "test: add regression spec for read_all single-burst"
```

---

## Task 9: GREEN — `read_all` delegates to `snapshot`

**Files:**
- Modify: `mrblib/mpu6886.rb` (replace `read_all` body)

- [ ] **Step 9.1: Replace `read_all` body**

Find:

```ruby
  # Read all sensor data at once
  # @return [Hash] {accel: Hash, gyro: Hash, temp: Float}
  def read_all
    {
      accel: acceleration,
      gyro: gyroscope,
      temp: temperature
    }
  end
```

Replace with:

```ruby
  # Read all sensor data at once via a single 14-byte I2C burst.
  # @return [Hash] {accel: Hash, gyro: Hash, temp: Float}
  def read_all
    snapshot
  end
```

- [ ] **Step 9.2: Run regression test, expect PASS**

Run: `bundle exec rake test TESTOPTS='--name=/MPU6886ReadAllBurst/'`
Expected: 1 test, 0 failures.

- [ ] **Step 9.3: Run full suite**

Run: `bundle exec rake test`
Expected: 10 tests, 0 failures.

- [ ] **Step 9.4: Commit GREEN**

```bash
git add mrblib/mpu6886.rb
git commit -m "refactor: route read_all through snapshot single burst"
```

---

## Task 10: RED — failing tests for `tick`, `configure_sampling`, `latest_*`, `fresh?`

**Files:**
- Modify: `test/mpu6886_test.rb`

- [ ] **Step 10.1: Append sampler accessor tests**

```ruby
class MPU6886TickSamplerTest < Test::Unit::TestCase
  ZERO14 = ("\x00".b * 14).freeze
  ONEG14 = ([0x40, 0x00] + [0x00] * 12).pack("C*").freeze

  def setup
    @i2c = FakeI2C.new
    @i2c.queue_read("\x19".b)
    @mpu = MPU6886.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_fresh_is_false_before_first_sample
    assert_equal false, @mpu.fresh?
  end

  def test_latest_accessors_are_nil_before_first_sample
    assert_nil @mpu.latest_snapshot
    assert_nil @mpu.latest_acceleration
    assert_nil @mpu.latest_gyroscope
    assert_nil @mpu.latest_temperature
  end

  def test_first_tick_always_samples
    @i2c.queue_read(ONEG14)
    sampled = @mpu.tick(1000)
    assert_equal true, sampled
    assert_equal true, @mpu.fresh?
    assert_in_delta 1.0, @mpu.latest_acceleration[:x], 1e-6
    assert_equal 1, @i2c.reads.size
  end

  def test_tick_within_interval_is_noop
    @i2c.queue_read(ZERO14)
    assert_equal true, @mpu.tick(1000)            # interval=20ms default; first sample
    assert_equal false, @mpu.tick(1010)           # 10ms elapsed -> skip
    assert_equal 1, @i2c.reads.size, "no second I2C read should fire inside the interval"
  end

  def test_tick_after_interval_samples_again
    @i2c.queue_read(ZERO14)
    @i2c.queue_read(ONEG14)
    @mpu.tick(1000)
    sampled = @mpu.tick(1025)                     # 25ms elapsed > 20ms default
    assert_equal true, sampled
    assert_equal 2, @i2c.reads.size
    assert_in_delta 1.0, @mpu.latest_acceleration[:x], 1e-6
  end

  def test_configure_sampling_changes_interval
    @mpu.configure_sampling(interval_ms: 100)
    @i2c.queue_read(ZERO14)
    @i2c.queue_read(ZERO14)
    @mpu.tick(0)
    assert_equal false, @mpu.tick(50),  "still within new 100ms interval"
    assert_equal true,  @mpu.tick(150), "now beyond 100ms interval"
  end

  def test_latest_acceleration_returns_cached_hash
    @i2c.queue_read(ONEG14)
    @mpu.tick(1000)
    a = @mpu.latest_acceleration
    g = @mpu.latest_gyroscope
    t = @mpu.latest_temperature
    assert_in_delta 1.0, a[:x], 1e-6
    assert_in_delta 0.0, g[:x], 1e-6
    assert_in_delta 25.0, t, 1e-6
  end
end
```

- [ ] **Step 10.2: Run, expect FAIL**

Run: `bundle exec rake test TESTOPTS='--name=/MPU6886TickSampler/'`
Expected: NoMethodError on `fresh?`, `latest_*`, `tick`, `configure_sampling`.

- [ ] **Step 10.3: Commit RED**

```bash
git add test/mpu6886_test.rb
git commit -m "test: add failing spec for tick / configure_sampling / latest_* / fresh?"
```

---

## Task 11: GREEN — implement tick-driven sampler and cached accessors

**Files:**
- Modify: `mrblib/mpu6886.rb` (add public methods after `snapshot`)

- [ ] **Step 11.1: Add the methods**

Insert immediately after `snapshot`:

```ruby
  # Configure the sampling interval for both tick() and start_sampling().
  # @param interval_ms [Integer] minimum milliseconds between successive samples
  def configure_sampling(interval_ms: 20)
    @sampler_interval_ms = interval_ms
  end

  # Cooperative single-loop sampler. Call from your main loop.
  # Performs one snapshot if at least @sampler_interval_ms have elapsed since
  # the last sample (or no sample has been taken yet); otherwise no-op.
  # @param now_ms [Integer, nil] current monotonic millisecond count.
  #   Pass nil to use Machine.uptime_us / 1000 if available, else 0.
  # @return [Boolean] true if a fresh sample was taken
  def tick(now_ms = nil)
    now_ms = _now_ms if now_ms.nil?
    if @latest_at_ms > 0 && (now_ms - @latest_at_ms) < @sampler_interval_ms
      return false
    end
    @latest = snapshot
    @latest_at_ms = now_ms
    true
  end

  # @return [Boolean] true once at least one sample has been cached
  def fresh?
    !@latest.nil?
  end

  # @return [Hash, nil] the most recent full snapshot, or nil if never sampled
  def latest_snapshot
    @latest
  end

  # @return [Hash, nil] {x:, y:, z:} from the latest snapshot, or nil
  def latest_acceleration
    @latest && @latest[:accel]
  end

  # @return [Hash, nil] {x:, y:, z:} from the latest snapshot, or nil
  def latest_gyroscope
    @latest && @latest[:gyro]
  end

  # @return [Float, nil] temperature from the latest snapshot, or nil
  def latest_temperature
    @latest && @latest[:temp]
  end
```

And add a private helper at the bottom of the class (before final `end`), grouped with the other private methods:

```ruby
  # Monotonic millisecond clock. Uses Machine.uptime_us when available
  # (R2P2-ESP32 firmware); falls back to 0 on host where the test always
  # passes an explicit now_ms to tick().
  def _now_ms
    if Object.const_defined?(:Machine)
      Machine.uptime_us / 1000
    else
      0
    end
  end
```

- [ ] **Step 11.2: Run sampler tests, expect PASS**

Run: `bundle exec rake test TESTOPTS='--name=/MPU6886TickSampler/'`
Expected: 7 tests, 0 failures.

- [ ] **Step 11.3: Run full suite**

Run: `bundle exec rake test`
Expected: 17 tests, 0 failures.

- [ ] **Step 11.4: Commit GREEN**

```bash
git add mrblib/mpu6886.rb
git commit -m "feat: add tick-driven sampler and latest_* cached accessors"
```

---

## Task 12: Implement background `Task` sampler (no host TDD; spec'd code only)

**Files:**
- Modify: `mrblib/mpu6886.rb` (add three methods after the latest_* block)

**Rationale.** `start_sampling` requires a running mruby/c (or microruby) Task scheduler. CRuby has no `Task` class and no `PicoRubyVM::InstructionSequence`. Host-side tests cannot exercise this path; it is validated on real hardware in Task 18. Code is added directly per spec §3.5.

- [ ] **Step 12.1: Add the three methods**

Insert immediately before the `private` keyword:

```ruby
  # Spawn a background Task that calls snapshot every @sampler_interval_ms
  # and updates the cached latest_* values. Idempotent: a second call with an
  # already-running sampler returns the existing Task handle.
  #
  # Dual-engine: mruby/c does not forward blocks to Task#initialize, so we
  # compile a script string and use Task.create. microruby (mruby) accepts a
  # block on Task.new normally. Pattern lifted from picoruby-psg/mrblib/driver.rb.
  #
  # @param interval_ms [Integer] sampling interval in ms (default 20 = 50Hz)
  # @return [Task] handle to the running sampler
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

  # Halt the background sampler and clear the Task handle.
  # Safe to call when no sampler is running.
  def stop_sampling
    return unless @sampler_task
    @sampler_running = false
    @sampler_task.join
    @sampler_task = nil
  end

  # Body of the background sampler Task. Public-by-necessity because
  # the spawned Task script and the block both invoke it via send.
  def _run_sampler_loop
    while @sampler_running
      @latest = snapshot
      @latest_at_ms = _now_ms
      sleep_ms(@sampler_interval_ms)
    end
  end
```

- [ ] **Step 12.2: Run full suite (must still pass — no host regression)**

Run: `bundle exec rake test`
Expected: 17 tests, 0 failures (the new methods are not exercised on host).

- [ ] **Step 12.3: Commit (single commit; no RED phase since not host-testable)**

```bash
git add mrblib/mpu6886.rb
git commit -m "feat: add background Task sampler (start/stop_sampling, dual-engine)"
```

---

## Task 13: Update RBS (`sig/mpu6886.rbs`)

**Files:**
- Modify: `sig/mpu6886.rbs`

- [ ] **Step 13.1: Replace `sig/mpu6886.rbs` with the updated signature**

```rbs
# @sidebar sensors

# Forward declaration (full type lives in picoruby-mruby/sig/task.rbs).
class Task end

class MPU6886
  ACCEL_RANGE_2G: Integer
  ACCEL_RANGE_4G: Integer
  ACCEL_RANGE_8G: Integer
  ACCEL_RANGE_16G: Integer

  GYRO_RANGE_250DPS: Integer
  GYRO_RANGE_500DPS: Integer
  GYRO_RANGE_1000DPS: Integer
  GYRO_RANGE_2000DPS: Integer

  I2C_ADDRESS: Integer
  REG_PWR_MGMT_1: Integer
  REG_ACCEL_XOUT_H: Integer
  REG_GYRO_XOUT_H: Integer
  REG_TEMP_OUT_H: Integer
  REG_ACCEL_CONFIG: Integer
  REG_GYRO_CONFIG: Integer
  REG_WHO_AM_I: Integer
  CHIP_ID: Integer

  ACCEL_SCALES: Hash[Integer, Float]
  GYRO_SCALES: Hash[Integer, Float]

  type vector_hash = { x: Float, y: Float, z: Float }
  type sensor_data = { accel: vector_hash, gyro: vector_hash, temp: Float }
  type tilt_data = { pitch: Float, roll: Float }

  @i2c: I2C
  @accel_scale: Float
  @gyro_scale: Float
  @latest: sensor_data | nil
  @latest_at_ms: Integer
  @sampler_interval_ms: Integer
  @sampler_task: Task | nil
  @sampler_running: bool

  def initialize: (I2C i2c_instance) -> void

  # Existing API (preserved; mrubygirls compatibility)
  def acceleration: () -> vector_hash
  def gyroscope: () -> vector_hash
  def temperature: () -> Float
  def accel_range=: (Integer range) -> void
  def gyro_range=: (Integer range) -> void
  def read_all: () -> sensor_data
  def magnitude: () -> Float
  def tilt_angles: () -> tilt_data
  def motion_detected?: (?Float threshold) -> bool

  # New: atomic burst snapshot
  def snapshot: () -> sensor_data

  # New: tick-driven sampler
  def configure_sampling: (?interval_ms: Integer) -> void
  def tick: (?Integer | nil now_ms) -> bool

  # New: background Task sampler
  def start_sampling: (?interval_ms: Integer) -> Task
  def stop_sampling: () -> void

  # New: cached accessors (shared by tick and background sampler)
  def fresh?: () -> bool
  def latest_snapshot: () -> (sensor_data | nil)
  def latest_acceleration: () -> (vector_hash | nil)
  def latest_gyroscope: () -> (vector_hash | nil)
  def latest_temperature: () -> (Float | nil)

  # Internals (called by Task body / time helper)
  def _run_sampler_loop: () -> void
  def _now_ms: () -> Integer

  private

  def init_sensor: () -> void
  def write_reg: (Integer reg, Integer data) -> void
  def read_reg: (Integer reg, Integer length) -> Array[Integer]
  def to_signed_16bit: (Integer value) -> Integer
end
```

- [ ] **Step 13.2: Run full suite (RBS is not loaded by tests; sanity)**

Run: `bundle exec rake test`
Expected: 17 tests, 0 failures.

- [ ] **Step 13.3: Commit**

```bash
git add sig/mpu6886.rbs
git commit -m "docs: update RBS for snapshot, tick, sampling, latest_* APIs"
```

---

## Task 14: Rewrite `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 14.1: Replace `README.md` content**

Use the file contents below verbatim:

````markdown
# picoruby-mpu6886

A pure Ruby implementation of MPU6886 6-axis IMU driver for PicoRuby.

> **Compatibility:** the public API used by the
> [mrubygirls Atom Matrix guide](https://mrubygirls.github.io/guides/esp32/atom_matrix/sensor_g_accel)
> (`MPU6886.new(i2c)` + `mpu.acceleration`) is preserved exactly. Existing code
> keeps working without changes.

## Installation

Add this line to your PicoRuby build configuration (`picoruby/build_config/xtensa-esp.rb`):

```ruby
conf.gem github: 'bash0C7/picoruby-mpu6886', branch: 'main'
```

## Dependencies

- `picoruby-i2c`: I2C communication library (included in PicoRuby)

## Quick Start

```ruby
require 'i2c'
require 'mpu6886'

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000, sda_pin: 25, scl_pin: 21)
mpu = MPU6886.new(i2c)

accel = mpu.acceleration  # => {x: 0.1, y: 0.0, z: 1.0} (G)
gyro  = mpu.gyroscope     # => {x: 1.2, y: -0.5, z: 0.0} (deg/s)
temp  = mpu.temperature   # => 25.4 (°C)
```

## Atomic burst read

`snapshot` issues a single 14-byte I2C burst that captures all three sensors
atomically. This is also the new internal implementation of `read_all`.

```ruby
snap = mpu.snapshot
# => { accel: {x:, y:, z:}, gyro: {x:, y:, z:}, temp: Float }
```

Use `snapshot` instead of three separate `acceleration` / `gyroscope` /
`temperature` calls when you need consistent values from a single moment.

## Background sampler Task

Spawn a background Task that keeps the latest reading fresh while your main
loop does other work (LED, UART, display).

```ruby
mpu = MPU6886.new(i2c)
mpu.start_sampling(interval_ms: 20)   # 50 Hz background sampling

loop do
  accel = mpu.latest_acceleration       # cached; no I2C from this thread
  if accel
    puts "X=#{accel[:x]}"
  end
  sleep_ms 100                          # main loop runs slowly; samples keep flowing
end

mpu.stop_sampling
```

Notes:
- Works on both mruby/c and microruby (the gem detects via `RUBY_ENGINE`).
- Mixing the background sampler with synchronous `acceleration` calls is
  undefined — pick one strategy. Both share the same I2C bus.
- Available accessors: `latest_snapshot`, `latest_acceleration`,
  `latest_gyroscope`, `latest_temperature`, `fresh?`.

## Tick-driven sampler

If you prefer to keep your main loop in charge, call `tick` instead of using a
background Task. `tick` does an I2C read at most once per configured interval.

```ruby
mpu = MPU6886.new(i2c)
mpu.configure_sampling(interval_ms: 20)

loop do
  mpu.tick                              # samples if interval elapsed; else no-op
  accel = mpu.latest_acceleration
  if accel
    puts "X=#{accel[:x]}"
  end
  sleep_ms 5
end
```

`tick(now_ms)` accepts an optional explicit timestamp (used in host tests). On
hardware it auto-reads `Machine.uptime_us / 1000` when `Machine` is available.

## API Reference

### Configuration

```ruby
mpu.accel_range = MPU6886::ACCEL_RANGE_2G    # ±2G (default)
mpu.accel_range = MPU6886::ACCEL_RANGE_4G    # ±4G
mpu.accel_range = MPU6886::ACCEL_RANGE_8G    # ±8G
mpu.accel_range = MPU6886::ACCEL_RANGE_16G   # ±16G

mpu.gyro_range = MPU6886::GYRO_RANGE_250DPS  # ±250°/s (default)
mpu.gyro_range = MPU6886::GYRO_RANGE_500DPS
mpu.gyro_range = MPU6886::GYRO_RANGE_1000DPS
mpu.gyro_range = MPU6886::GYRO_RANGE_2000DPS
```

### Synchronous reads (each call performs one I2C transaction)

```ruby
accel = mpu.acceleration   # {x:, y:, z:} (G)
gyro  = mpu.gyroscope      # {x:, y:, z:} (deg/s)
temp  = mpu.temperature    # Float (°C)
data  = mpu.read_all       # {accel:, gyro:, temp:}  (single 14-byte burst)
snap  = mpu.snapshot       # alias of read_all with intent-revealing name
```

### Cached reads (require prior `tick` or `start_sampling`)

```ruby
mpu.fresh?                 # true once at least one sample has been cached
mpu.latest_snapshot        # last full snapshot, or nil
mpu.latest_acceleration    # last accel hash, or nil
mpu.latest_gyroscope       # last gyro hash, or nil
mpu.latest_temperature     # last temp float, or nil
```

### Sampler control

```ruby
mpu.configure_sampling(interval_ms: 20)
mpu.tick                   # cooperative; pull next sample if interval elapsed
mpu.tick(now_ms)           # explicit timestamp (mostly for testing)

mpu.start_sampling(interval_ms: 20)   # spawn background Task
mpu.stop_sampling                     # halt and join the Task
```

### Motion analysis

```ruby
mpu.magnitude               # Float (combined acceleration in G)
mpu.tilt_angles             # {pitch:, roll:} (degrees)
mpu.motion_detected?        # bool, default threshold 0.1G
mpu.motion_detected?(0.2)   # bool, custom threshold
```

## Error handling

Communication errors raise `IOError`. Initialization failure (wrong WHO_AM_I)
raises `RuntimeError`.

```ruby
begin
  mpu = MPU6886.new(i2c)
  data = mpu.read_all
rescue IOError => e
  puts "Sensor communication error: #{e.message}"
rescue => e
  puts "Unexpected error: #{e.message}"
end
```

## Development

Host-side test suite uses CRuby + test-unit with a hand-rolled I2C double:

```bash
bundle install
bundle exec rake test
```

Tests cover initialization, narrow reads, the burst snapshot, `read_all` route,
the tick-driven sampler, range setters, and motion analysis. The background
`start_sampling` Task path is validated on real hardware (see
`docs/superpowers/specs/2026-04-30-runtime-gem-modernization-design.md` §4.6),
not host-side, because it depends on the mruby/c task scheduler.

## License

MIT
````

- [ ] **Step 14.2: Run full suite (sanity)**

Run: `bundle exec rake test`
Expected: 17 tests, 0 failures.

- [ ] **Step 14.3: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README for snapshot, sampling, and compatibility note"
```

---

## Task 15: Add repo-root `CLAUDE.md`

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 15.1: Create `CLAUDE.md`**

```markdown
# picoruby-mpu6886 — Repo-Local Rules for Claude Code

This is a **PicoRuby Runtime Gem** following upstream `picoruby/picoruby`
conventions (closest analog: `picoruby-aht25`). All logic is pure Ruby.
There is no C extension and none should be added.

## Public API contract — DO NOT BREAK

The
[mrubygirls Atom Matrix guide](https://mrubygirls.github.io/guides/esp32/atom_matrix/sensor_g_accel)
publicly references this gem. The following surface is frozen:

- `MPU6886.new(i2c)`
- `mpu.acceleration` → `{x: Float, y: Float, z: Float}` in G
- `mpu.gyroscope`, `mpu.temperature`, `mpu.read_all` (return shapes)
- All `ACCEL_RANGE_*` / `GYRO_RANGE_*` constants

When in doubt, run `bundle exec rake test` — the regression tests guard the
above shapes.

## PicoRuby compatibility

Per `~/CLAUDE.md`, **avoid** these in `mrblib/*.rb`:

- `defined?` (use `Object.const_defined?(:Sym)` instead)
- `Hash#fetch`
- `String#reverse`, `String#rjust`
- inline `rescue`
- `proc`, `lambda`

`sleep_ms` is the cooperative-yield delay (`mrubyc/src/rrt0.c:1507`). Use it
freely — it allows other tasks to run during the wait. Do **not** swap it for
`Machine.delay_ms`; both behave the same with respect to task switching.

## Task-spawn pattern (dual-engine)

For any future async feature, use the picoruby-psg pattern:

```ruby
if RUBY_ENGINE == "mruby/c"
  $__global = self
  mrb = PicoRubyVM::InstructionSequence.compile('$__global._method').to_binary
  task = Task.create(mrb)
  task&.run
else
  obj = self
  task = Task.new { obj._method }
end
```

This works on both R2P2-ESP32 (mruby/c) and microruby host builds.

## Tests

- Host-side: `bundle exec rake test` (CRuby + test-unit, with `FakeI2C` double).
- On-device: declared via `add_test_dependency 'picoruby-picotest'`; not wired
  to a default rake target because no `picoruby` binary is required for
  CRuby development.
- Background `start_sampling` is **not** host-tested — it requires a running
  Task scheduler. Validate it via the combat-proof example in
  `picoruby-recipes/components/R2P2-ESP32/storage/home/imu_async.rb`.

## Combat-proof location

Reference Ruby examples for ATOM Matrix live in
`~/dev/src/github.com/bash0C7/picoruby-recipes/components/R2P2-ESP32/storage/home/`.
After any non-trivial change, smoke-test:

- `imu.rb` — synchronous polling, the existing baseline (must keep working).
- `imu_async.rb` — background sampler with concurrent main-loop work.

`rake build` / `rake flash` / `rake monitor` in `picoruby-recipes` are
human-driven; Claude Code does not run them.

## Git

- Conventional Commits: `feat` / `fix` / `docs` / `test` / `refactor` / `chore`.
- Imperative mood, English only.
- Per `~/CLAUDE.md` TDD discipline, RED / GREEN / REFACTOR are independent
  commits.
```

- [ ] **Step 15.2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add repo-local CLAUDE.md with API contract and conventions"
```

---

## Task 16: Final host-side full suite verification

**Files:** none changed.

- [ ] **Step 16.1: Clean run from a fresh shell**

Run:
```bash
bundle exec rake test
```
Expected: 17 tests, 0 failures, 0 errors.

- [ ] **Step 16.2: Lint the gem manifest by reading it back**

Run:
```bash
ruby -e "puts File.read('mrbgem.rake')"
grep -nE 'src/|include/' mrbgem.rake || echo "OK: no dead refs"
```
Expected: `OK: no dead refs`.

- [ ] **Step 16.3: Verify `src/` and `include/` are gone**

Run: `test -e src && echo BAD || echo OK; test -e include && echo BAD || echo OK`
Expected: `OK\nOK`.

- [ ] **Step 16.4 (no commit — verification only)**

If any check failed, fix before proceeding to combat-proof.

---

## Task 17: Combat-proof — `imu.rb` compatibility (real ATOM Matrix)

**Files:** none changed in this repo. Build/flash is user-driven.

**Out-of-repo dependency.** The `picoruby-recipes` build config must point this
gem at the latest commit on `main`.

- [ ] **Step 17.1: User updates `picoruby-recipes` build config to track this branch**

Open `~/dev/src/github.com/bash0C7/picoruby-recipes/components/R2P2-ESP32/main` (or
the relevant `build_config/xtensa-esp.rb`) and ensure:

```ruby
conf.gem github: 'bash0C7/picoruby-mpu6886', branch: 'main'
```

is present and points at the head of `main` after merge.

- [ ] **Step 17.2: User builds and flashes**

User runs (Claude does NOT run these — `rake build`/`flash` are human-only per
`picoruby-recipes/CLAUDE.md`):

```bash
cd ~/dev/src/github.com/bash0C7/picoruby-recipes
rake cleanbuild
rake flash
rake monitor
```

- [ ] **Step 17.3: User runs existing `imu.rb` on the device**

In the R2P2 shell:

```
> imu.rb
```

Expected output, similar to the existing baseline:

```
MPU6886 IMU Sensor Starting...
MPU6886 initialized (4G accel, 2000DPS gyro)
---
Accel: X=..., Y=..., Z=... [G]
Gyro:  X=..., Y=..., Z=... [deg/s]
Temp:  ... [C]
---
... (repeats every 500ms)
```

- [ ] **Step 17.4: Acceptance criterion**

The output shape and update cadence are unchanged from before this PR. No
exceptions, no `IOError`. mrubygirls API confirmed forward-compatible.

If this fails: do NOT proceed. Roll back to investigate.

---

## Task 18: Combat-proof — new `imu_async.rb` (background sampler on real ATOM Matrix)

**Files:**
- Create: `~/dev/src/github.com/bash0C7/picoruby-recipes/components/R2P2-ESP32/storage/home/imu_async.rb` (in the **picoruby-recipes** repo, not this one).

- [ ] **Step 18.1: Create the example file**

```ruby
# imu_async.rb — background sampler verification
# Verifies start_sampling spawns a Task that keeps latest_acceleration fresh
# while the main loop does unrelated work.
require 'mpu6886'

puts "MPU6886 async sampler test"

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000, sda_pin: 25, scl_pin: 21)
mpu = MPU6886.new(i2c)
mpu.accel_range = MPU6886::ACCEL_RANGE_4G
mpu.gyro_range  = MPU6886::GYRO_RANGE_2000DPS

mpu.start_sampling(interval_ms: 20)   # 50Hz background

ticks = 0
loop do
  ticks += 1
  accel = mpu.latest_acceleration
  if accel
    ax = (accel[:x] * 100).to_i / 100.0
    ay = (accel[:y] * 100).to_i / 100.0
    az = (accel[:z] * 100).to_i / 100.0
    puts "[main #{ticks}] cached accel: X=#{ax} Y=#{ay} Z=#{az}"
  else
    puts "[main #{ticks}] no sample yet"
  end

  # Main loop intentionally slower than sampler interval (20ms).
  # Samples must keep arriving from the background Task.
  sleep_ms 500

  break if ticks >= 10
end

mpu.stop_sampling
puts "stopped"
```

- [ ] **Step 18.2: User commits the new example in the recipes repo**

```bash
cd ~/dev/src/github.com/bash0C7/picoruby-recipes
git add components/R2P2-ESP32/storage/home/imu_async.rb
git commit -m "feat: add imu_async.rb to validate mpu6886 background sampler"
```

- [ ] **Step 18.3: User flashes (storage update may not need full reflash; check picoruby-recipes Rakefile)**

```bash
rake flash    # or the storage-only target if the Rakefile provides one
rake monitor
```

- [ ] **Step 18.4: User runs `imu_async.rb` on device**

```
> imu_async.rb
```

Expected output:

```
MPU6886 async sampler test
[main 1] cached accel: X=... Y=... Z=...
[main 2] cached accel: X=... Y=... Z=...
... (10 lines total, ~500ms apart)
stopped
```

- [ ] **Step 18.5: Acceptance criteria**

1. `[main 1]` shows a real accel value (NOT "no sample yet") — the background
   Task produced its first sample inside 500ms.
2. Each subsequent `[main N]` shows values that change as the device is moved
   between iterations — confirming samples keep flowing while the main loop
   sleeps.
3. `stopped` prints cleanly with no crash — `stop_sampling` joined the Task.

If any of these fail: capture the serial log, do NOT mark the work done.
Diagnose against spec §3.5 (Task spawn) and §7-Q1 (`PicoRubyVM` availability).

---

## Self-Review Notes (already applied inline)

**Spec coverage map:**

- Spec §2 (Compatibility Contract) — covered by tests in Task 8 (read_all
  shape) and Task 17 (imu.rb retest).
- Spec §3.1 (file layout) — covered by Tasks 2, 3, 14, 15.
- Spec §3.2 (mrbgem.rake) — Task 3.
- Spec §3.3 (3-tier acquisition) — Tasks 7 (snapshot), 11 (tick), 12 (Task).
- Spec §3.4 (burst read) — Tasks 6 + 7.
- Spec §3.5 (background sampler with dual-engine) — Task 12.
- Spec §3.6 (tick-driven sampler) — Tasks 10 + 11.
- Spec §3.7 (cached accessors) — Task 11.
- Spec §4.1 (PicoRuby compat) — checked in Task 15 (CLAUDE.md captures rules).
- Spec §4.2 (`Machine` dependency) — Task 11 (`_now_ms` helper).
- Spec §4.4 (RBS) — Task 13.
- Spec §4.5 (tests) — Tasks 1, 4–11.
- Spec §4.6 (combat-proof) — Tasks 17 + 18.
- Spec §5 (README) — Task 14.
- Spec §6 (CLAUDE.md) — Task 15.
- Spec §7 Q1–Q5 — flagged in Task 12 commentary and Task 18 acceptance.

**Placeholder scan:** no TBD/TODO/"fill in" — every step has actual code or
exact commands.

**Type/method consistency check:** all references match.
- `snapshot` (Tasks 6, 7, 9, 14, 18) — same name everywhere.
- `start_sampling` / `stop_sampling` (Tasks 12, 14, 15, 18).
- `tick` / `configure_sampling` (Tasks 10, 11, 14).
- `latest_snapshot` / `latest_acceleration` / `latest_gyroscope` /
  `latest_temperature` / `fresh?` (Tasks 10, 11, 14).
- `_run_sampler_loop` / `_now_ms` (Tasks 11, 12).

No drift detected.
