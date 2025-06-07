# picoruby-mpu6886

A pure Ruby implementation of MPU6886 6-axis inertial sensor driver for PicoRuby.

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

# Initialize I2C (for ATOM Matrix)
i2c = I2C.new(
  unit: :ESP32_I2C0,
  frequency: 100_000,
  sda_pin: 25,
  scl_pin: 21
)

# Initialize MPU6886 sensor
mpu = MPU6886.new(i2c)

# Read sensor data
accel = mpu.acceleration  # => {x: 0.1, y: 0.0, z: 1.0} (G units)
gyro = mpu.gyroscope     # => {x: 1.2, y: -0.5, z: 0.0} (degrees/second)
temp = mpu.temperature   # => 25.4 (Celsius)
```

## API Reference

### Configuration

```ruby
# Set accelerometer range
mpu.accel_range = MPU6886::ACCEL_RANGE_2G   # ±2G (default)
mpu.accel_range = MPU6886::ACCEL_RANGE_4G   # ±4G
mpu.accel_range = MPU6886::ACCEL_RANGE_8G   # ±8G
mpu.accel_range = MPU6886::ACCEL_RANGE_16G  # ±16G

# Set gyroscope range
mpu.gyro_range = MPU6886::GYRO_RANGE_250DPS  # ±250°/s (default)
mpu.gyro_range = MPU6886::GYRO_RANGE_500DPS  # ±500°/s
mpu.gyro_range = MPU6886::GYRO_RANGE_1000DPS # ±1000°/s
mpu.gyro_range = MPU6886::GYRO_RANGE_2000DPS # ±2000°/s
```

### Data Reading

```ruby
# Individual sensor readings
accel = mpu.acceleration    # {x: Float, y: Float, z: Float} in G units
gyro = mpu.gyroscope       # {x: Float, y: Float, z: Float} in degrees/second
temp = mpu.temperature     # Float in Celsius

# Combined reading (more efficient)
data = mpu.read_all        # {accel: Hash, gyro: Hash, temp: Float}
```

### Motion Analysis

```ruby
# Calculate acceleration magnitude
magnitude = mpu.magnitude   # Float (combined acceleration in G units)

# Calculate tilt angles
tilt = mpu.tilt_angles     # {pitch: Float, roll: Float} in degrees

# Motion detection
motion = mpu.motion_detected?         # Boolean (default threshold: 0.1G)
motion = mpu.motion_detected?(0.2)    # Boolean (custom threshold: 0.2G)
```

## Complete Example

This example demonstrates real-time sensor monitoring with motion detection. The sample code was tested and runs on ATOM Matrix with AE-AQM0802 display module:

```ruby
# MPU6886 sensor test - ATOM Matrix configuration
require 'i2c'
require 'mpu6886'

# PicoRuby round method implementation
class Float
  def round(digits = 0)
    if digits == 0
      if self >= 0
        (self + 0.5).to_i
      else
        (self - 0.5).to_i
      end
    else
      factor = 10.0 ** digits
      ((self * factor) + (self >= 0 ? 0.5 : -0.5)).to_i / factor.to_f
    end
  end
end

puts "MPU6886 sensor test started (ATOM Matrix built-in)"

# Use correct configuration from successful diagnosis
i2c = I2C.new(
  unit: :ESP32_I2C0,      # Fixed: ESP32 instead of RP2040
  frequency: 100_000,
  sda_pin: 25,            # Fixed: Use successful diagnosis settings
  scl_pin: 21,            # Fixed: Use successful diagnosis settings
  timeout: 2000           # Set longer timeout
)
sleep_ms 200

puts "I2C config: ESP32_I2C0, SDA:25, SCL:21"

# Initialize MPU6886
mpu = MPU6886.new(i2c)

# Configuration for motion sensing
mpu.accel_range = MPU6886::ACCEL_RANGE_8G
mpu.gyro_range = MPU6886::GYRO_RANGE_500DPS

puts "Settings: Accel ±8G, Gyro ±500°/s"
puts "---"

sleep_ms 100
puts "initial1"
[0x38, 0x39, 0x14, 0x70, 0x54, 0x6c].each { |i| i2c.write(0x3e, 0, i); sleep_ms 1 }

# Data reading loop
loop do
  # Get basic data
  accel = mpu.acceleration
  gyro = mpu.gyroscope
  temp = mpu.temperature
  
  # Calculate combined acceleration
  magnitude = mpu.magnitude
  
  # Net acceleration (gravity removed, m/s² units)
  net_accel_raw = magnitude - 1.0
  net_accel = net_accel_raw > 0 ? net_accel_raw * 9.81 : 0.0
  
  # Motion detection status
  motion_status = if net_accel >= 1.5
    "[Motion Detected!]"
  elsif mpu.motion_detected?(0.1)
    "[Light Motion]"
  else
    "[Static]"
  end
  
  # Single line display
  tilt = mpu.tilt_angles
  puts "A:#{accel[:x].round(2)},#{accel[:y].round(2)},#{accel[:z].round(2)}G | Accel:#{net_accel.round(1)}m/s² | G:#{gyro[:x].round(0)},#{gyro[:y].round(0)},#{gyro[:z].round(0)}°/s | #{temp.round(0)}°C | #{motion_status}"
  sleep_ms 200
  [0x38, 0x0c, 0x01].each { |i| i2c.write(0x3e, 0, i); sleep_ms 1 }
  "#{net_accel.round(1)}m/s²".bytes.each { |c| i2c.write(0x3e, 0x40, c); sleep_ms 1 }
  sleep_ms 100
end
```

## Error Handling

The library throws exceptions for communication errors. Handle them in your application code:

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

## License

MIT
