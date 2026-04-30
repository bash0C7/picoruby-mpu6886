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
  # @return [Hash] {accel: Hash, gyro: Hash, temp: Float}
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

  private

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
