# MPU6886 6-axis inertial sensor - Pure Ruby Implementation

require 'i2c'

class MPU6886
  # MPU6886 I2C address
  I2C_ADDRESS = 0x68
  
  # Register addresses
  REG_WHO_AM_I      = 0x75
  REG_PWR_MGMT_1    = 0x6B
  REG_ACCEL_XOUT_H  = 0x3B
  REG_GYRO_XOUT_H   = 0x43
  REG_TEMP_OUT_H    = 0x41
  REG_ACCEL_CONFIG  = 0x1C
  REG_GYRO_CONFIG   = 0x1B
  
  # Chip ID
  CHIP_ID = 0x19
  
  # Accelerometer range settings
  ACCEL_RANGE_2G    = 0x00
  ACCEL_RANGE_4G    = 0x08
  ACCEL_RANGE_8G    = 0x10
  ACCEL_RANGE_16G   = 0x18
  
  # Gyroscope range settings
  GYRO_RANGE_250DPS  = 0x00
  GYRO_RANGE_500DPS  = 0x08
  GYRO_RANGE_1000DPS = 0x10
  GYRO_RANGE_2000DPS = 0x18
  
  # Scale values (changed by range)
  ACCEL_SCALES = {
    ACCEL_RANGE_2G  => 16384.0,
    ACCEL_RANGE_4G  => 8192.0,
    ACCEL_RANGE_8G  => 4096.0,
    ACCEL_RANGE_16G => 2048.0
  }
  
  GYRO_SCALES = {
    GYRO_RANGE_250DPS  => 131.0,
    GYRO_RANGE_500DPS  => 65.5,
    GYRO_RANGE_1000DPS => 32.8,
    GYRO_RANGE_2000DPS => 16.4
  }

  # Default tick / start_sampling interval, used by init_sensor seed and as
  # the configure_sampling kwarg default. Single source of truth.
  DEFAULT_SAMPLER_INTERVAL_MS = 20

  # Initialize
  # @param i2c_instance [I2C] Existing I2C instance
  def initialize(i2c_instance)
    @i2c = i2c_instance
    
    @accel_scale = ACCEL_SCALES[ACCEL_RANGE_2G]
    @gyro_scale = GYRO_SCALES[GYRO_RANGE_250DPS]
    
    init_sensor
  end

  # Get acceleration data (G units)
  # @return [Hash] {x: Float, y: Float, z: Float}
  def acceleration
    data = read_reg(REG_ACCEL_XOUT_H, 6)
    
    # Convert to 16-bit signed integer
    raw_x = to_signed_16bit((data[0] << 8) | data[1])
    raw_y = to_signed_16bit((data[2] << 8) | data[3])
    raw_z = to_signed_16bit((data[4] << 8) | data[5])
    
    # Convert to G units
    {
      x: raw_x / @accel_scale,
      y: raw_y / @accel_scale,
      z: raw_z / @accel_scale
    }
  end

  # Get gyroscope data (degrees/second)
  # @return [Hash] {x: Float, y: Float, z: Float}
  def gyroscope
    data = read_reg(REG_GYRO_XOUT_H, 6)
    
    # Convert to 16-bit signed integer
    raw_x = to_signed_16bit((data[0] << 8) | data[1])
    raw_y = to_signed_16bit((data[2] << 8) | data[3])
    raw_z = to_signed_16bit((data[4] << 8) | data[5])
    
    # Convert to degrees/second
    {
      x: raw_x / @gyro_scale,
      y: raw_y / @gyro_scale,
      z: raw_z / @gyro_scale
    }
  end

  # Get temperature data (Celsius)
  # @return [Float] Temperature (°C)
  def temperature
    data = read_reg(REG_TEMP_OUT_H, 2)
    
    # Convert to 16-bit signed integer
    raw_temp = to_signed_16bit((data[0] << 8) | data[1])
    
    # Convert to Celsius (datasheet formula)
    raw_temp / 326.8 + 25.0
  end

  # Set accelerometer range
  # @param range [Integer] Accelerometer range
  def accel_range=(range)
    write_reg(REG_ACCEL_CONFIG, range)
    @accel_scale = ACCEL_SCALES[range] || ACCEL_SCALES[ACCEL_RANGE_2G]
  end

  # Set gyroscope range
  # @param range [Integer] Gyroscope range
  def gyro_range=(range)
    write_reg(REG_GYRO_CONFIG, range)
    @gyro_scale = GYRO_SCALES[range] || GYRO_SCALES[GYRO_RANGE_250DPS]
  end

  # Read all sensor data at once via a single 14-byte I2C burst.
  # Kept as a public-API alias of {#snapshot} for backward compatibility
  # (referenced by the mrubygirls Atom Matrix guide and existing user code).
  # @return [Hash] {accel: Hash, gyro: Hash, temp: Float}
  # @see #snapshot
  def read_all
    snapshot
  end

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

  # Configure the sampling interval for both tick() and start_sampling().
  # @param interval_ms [Integer] minimum milliseconds between successive samples
  def configure_sampling(interval_ms: DEFAULT_SAMPLER_INTERVAL_MS)
    @sampler_interval_ms = interval_ms
  end

  # Cooperative single-loop sampler. Call from your main loop.
  # Performs one snapshot if at least @sampler_interval_ms have elapsed since
  # the last sample (or no sample has been taken yet); otherwise no-op.
  # @param now_ms [Integer, nil] current monotonic millisecond count.
  #   Pass nil to use Machine.uptime_us / 1000 if available, else 0.
  #   The caller is responsible for monotonicity: passing a value smaller
  #   than the previous now_ms produces no-op behaviour rather than
  #   re-sampling. Production callers on R2P2-ESP32 should rely on the nil
  #   default (which uses the monotonic Machine.uptime_us).
  # @return [Boolean] true if a fresh sample was taken
  def tick(now_ms = nil)
    now_ms = _now_ms if now_ms.nil?
    if !@latest.nil? && (now_ms - @latest_at_ms) < @sampler_interval_ms
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

  # Calculate combined acceleration
  # @return [Float] Combined acceleration (G units)
  def magnitude
    accel = acceleration
    Math.sqrt(accel[:x] ** 2 + accel[:y] ** 2 + accel[:z] ** 2)
  end

  # Calculate tilt angles (degrees)
  # @return [Hash] {pitch: Float, roll: Float}
  def tilt_angles
    accel = acceleration
    
    # Pitch angle (around X axis)
    pitch = Math.atan2(accel[:y], Math.sqrt(accel[:x] ** 2 + accel[:z] ** 2)) * 180.0 / Math::PI
    
    # Roll angle (around Y axis)  
    roll = Math.atan2(-accel[:x], Math.sqrt(accel[:y] ** 2 + accel[:z] ** 2)) * 180.0 / Math::PI
    
    { pitch: pitch, roll: roll }
  end

  # Detect motion (acceleration change)
  # @param threshold [Float] Detection threshold (G units, default 0.1G)
  # @return [Boolean] true if motion detected
  def motion_detected?(threshold = 0.1)
    magnitude > (1.0 + threshold) || magnitude < (1.0 - threshold)
  end

  # Spawn a background Task that calls snapshot every @sampler_interval_ms
  # and updates the cached latest_* values. Idempotent: a second call with an
  # already-running sampler returns the existing Task handle.
  #
  # Dual-engine: mruby/c does not forward blocks to Task#initialize, so we
  # compile a script string and use Task.create. microruby (mruby) accepts a
  # block on Task.new normally. Pattern lifted from picoruby-psg/mrblib/driver.rb.
  #
  # Cached latest_* values are reset to nil on start; the first sample arrives
  # after one full interval_ms. Use #fresh? to gate access.
  #
  # If a sampler is already running, this call is a no-op AND the interval_ms:
  # kwarg is ignored. To change interval at runtime: stop_sampling, then
  # configure_sampling(interval_ms: ...), then start_sampling again.
  #
  # Concurrency note: the global $__mpu6886_sampler_target is overwritten on
  # each call. Concurrent start_sampling from multiple MPU6886 instances is
  # not supported (the spawned Task captures self before the next call could
  # clobber it under cooperative scheduling, but assume single-IMU apps).
  #
  # @param interval_ms [Integer] sampling interval in ms (default DEFAULT_SAMPLER_INTERVAL_MS = 50Hz)
  # @return [Task] handle to the running sampler
  def start_sampling(interval_ms: DEFAULT_SAMPLER_INTERVAL_MS)
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
  # Safe to call when no sampler is running. `join` may block up to
  # @sampler_interval_ms while the Task completes its current sleep_ms;
  # with the default 20ms this is negligible, but a 1000ms interval will
  # take up to that long to shut down.
  def stop_sampling
    return unless @sampler_task
    @sampler_running = false
    @sampler_task.join
    @sampler_task = nil
  end

  # Body of the background sampler Task. Public-by-necessity because
  # the spawned Task script and the block both invoke it via send.
  # DO NOT call directly: this loops until @sampler_running is set false
  # externally. Use start_sampling / stop_sampling.
  #
  # Intentionally does not update @latest_at_ms: calling Machine.uptime_us
  # from within an mruby/c Task causes silent Task death after one iteration.
  # The synchronous tick() path keeps maintaining @latest_at_ms when callers
  # use it; in pure async mode @latest_at_ms stays at the start_sampling
  # reset value (0).
  #
  # @sampler_interval_ms is cached to a local var before the loop to avoid
  # any per-iteration ivar lookup cost.
  #
  # Task.pass is the load-bearing line. Without an explicit yield, the
  # mruby/c scheduler does not give the main task room to run between
  # iterations, and refcount-only memory pressure builds until either the
  # Task hangs or the VM OOMs. sleep_ms alone is not sufficient on the
  # picoruby-mrubyc version this gem currently targets.
  def _run_sampler_loop
    interval_ms = @sampler_interval_ms
    while @sampler_running
      @latest = snapshot
      Task.pass
      sleep_ms(interval_ms)
    end
  end

  # Monotonic millisecond clock. Calls Machine.uptime_us directly; on host
  # the test harness stubs Machine. Only callable from the main task context
  # (synchronous tick() fallback) — invoking it from a background Task
  # silently kills the Task on mruby/c.
  def _now_ms
    Machine.uptime_us / 1000
  end

  private

  # Initialize sensor
  def init_sensor
    # Sampler state seeds (must precede any read; tick/start_sampling rely on them)
    @latest = nil
    @latest_at_ms = 0
    @sampler_interval_ms = DEFAULT_SAMPLER_INTERVAL_MS
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

  # Write to register
  # @param reg [Integer] Register address
  # @param data [Integer] Data to write
  def write_reg(reg, data)
    result = @i2c.write(I2C_ADDRESS, reg, data, timeout: 2000)
    unless result > 0
      raise IOError, "MPU6886 write failed (reg: 0x#{reg.to_s(16)}, data: 0x#{data.to_s(16)})"
    end
  end

  # Read from register
  # @param reg [Integer] Register address
  # @param length [Integer] Number of bytes to read
  # @return [Array<Integer>] Array of read data
  def read_reg(reg, length)
    data = @i2c.read(I2C_ADDRESS, length, reg, timeout: 1000)
    
    if data.nil? || data.empty?
      raise IOError, "MPU6886 read failed (reg: 0x#{reg.to_s(16)}, length: #{length})"
    end
    
    # Convert from String to byte array
    data.bytes
  end

  # Convert 16-bit value to signed integer
  # @param value [Integer] Unsigned 16-bit value
  # @return [Integer] Signed 16-bit value
  def to_signed_16bit(value)
    value > 32767 ? value - 65536 : value
  end
end
