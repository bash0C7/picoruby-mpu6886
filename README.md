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

## Experimental APIs (v0.1.0)

> The APIs in this section are experimental in v0.1.0 and may change before
> v1.0.0. Only the Quick Start above is the stable mrubygirls Atom Matrix
> guide contract.

### Atomic burst read

`snapshot` issues a single 14-byte I2C burst that captures all three sensors
atomically. `read_all` is an alias kept for backward compatibility.

```ruby
snap = mpu.snapshot
# => { accel: {x:, y:, z:}, gyro: {x:, y:, z:}, temp: Float }

data = mpu.read_all  # alias of snapshot
```

Use `snapshot` instead of three separate `acceleration` / `gyroscope` /
`temperature` calls when you need consistent values from a single moment.

### Background sampler Task

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

Cached accessors (require prior `start_sampling` or `tick`):

```ruby
mpu.fresh?                 # true once at least one sample has been cached
mpu.latest_snapshot        # last full snapshot, or nil
mpu.latest_acceleration    # last accel hash, or nil
mpu.latest_gyroscope       # last gyro hash, or nil
mpu.latest_temperature     # last temp float, or nil
```

Notes:
- Works on both mruby/c and microruby (the gem detects via `RUBY_ENGINE`).
- Mixing the background sampler with synchronous `acceleration` calls is
  undefined — pick one strategy. Both share the same I2C bus.

### Tick-driven sampler

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

### Range configuration

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
  accel = mpu.acceleration
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
