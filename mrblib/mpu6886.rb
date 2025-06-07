# MPU6886 6軸慣性センサー - Pure Ruby Implementation
# ATOM Matrix用に最適化
# picoruby-i2cを使用したポータブル実装

require 'i2c'

class MPU6886
  # MPU6886のI2Cアドレス
  I2C_ADDRESS = 0x68
  
  # レジスタアドレス
  REG_WHO_AM_I      = 0x75
  REG_PWR_MGMT_1    = 0x6B
  REG_ACCEL_XOUT_H  = 0x3B
  REG_GYRO_XOUT_H   = 0x43
  REG_TEMP_OUT_H    = 0x41
  REG_ACCEL_CONFIG  = 0x1C
  REG_GYRO_CONFIG   = 0x1B
  
  # チップID
  CHIP_ID = 0x19
  
  # 加速度レンジ設定
  ACCEL_RANGE_2G    = 0x00
  ACCEL_RANGE_4G    = 0x08
  ACCEL_RANGE_8G    = 0x10
  ACCEL_RANGE_16G   = 0x18
  
  # ジャイロレンジ設定
  GYRO_RANGE_250DPS  = 0x00
  GYRO_RANGE_500DPS  = 0x08
  GYRO_RANGE_1000DPS = 0x10
  GYRO_RANGE_2000DPS = 0x18
  
  # スケール値（レンジによって変更される）
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

  # 初期化
  # @param i2c_instance [I2C] 既存のI2Cインスタンス
  def initialize(i2c_instance)
    @i2c = i2c_instance
    
    @accel_scale = ACCEL_SCALES[ACCEL_RANGE_2G]
    @gyro_scale = GYRO_SCALES[GYRO_RANGE_250DPS]
    
    init_sensor
  end

  # 加速度データを取得（G単位）
  # @return [Hash] {x: Float, y: Float, z: Float}
  def acceleration
    data = read_reg(REG_ACCEL_XOUT_H, 6)
    
    # 16ビットのsigned integerに変換
    raw_x = to_signed_16bit((data[0] << 8) | data[1])
    raw_y = to_signed_16bit((data[2] << 8) | data[3])
    raw_z = to_signed_16bit((data[4] << 8) | data[5])
    
    # G単位に変換
    {
      x: raw_x / @accel_scale,
      y: raw_y / @accel_scale,
      z: raw_z / @accel_scale
    }
  end

  # ジャイロスコープデータを取得（度/秒単位）
  # @return [Hash] {x: Float, y: Float, z: Float}
  def gyroscope
    data = read_reg(REG_GYRO_XOUT_H, 6)
    
    # 16ビットのsigned integerに変換
    raw_x = to_signed_16bit((data[0] << 8) | data[1])
    raw_y = to_signed_16bit((data[2] << 8) | data[3])
    raw_z = to_signed_16bit((data[4] << 8) | data[5])
    
    # 度/秒単位に変換
    {
      x: raw_x / @gyro_scale,
      y: raw_y / @gyro_scale,
      z: raw_z / @gyro_scale
    }
  end

  # 温度データを取得（摂氏）
  # @return [Float] 温度（℃）
  def temperature
    data = read_reg(REG_TEMP_OUT_H, 2)
    
    # 16ビットのsigned integerに変換
    raw_temp = to_signed_16bit((data[0] << 8) | data[1])
    
    # 摂氏温度に変換（データシート式）
    raw_temp / 326.8 + 25.0
  end

  # 加速度レンジを設定
  # @param range [Integer] 加速度レンジ
  def accel_range=(range)
    write_reg(REG_ACCEL_CONFIG, range)
    @accel_scale = ACCEL_SCALES[range] || ACCEL_SCALES[ACCEL_RANGE_2G]
  end

  # ジャイロスコープレンジを設定
  # @param range [Integer] ジャイロレンジ
  def gyro_range=(range)
    write_reg(REG_GYRO_CONFIG, range)
    @gyro_scale = GYRO_SCALES[range] || GYRO_SCALES[GYRO_RANGE_250DPS]
  end

  # センサーデータをまとめて取得
  # @return [Hash] {accel: Hash, gyro: Hash, temp: Float}
  def read_all
    {
      accel: acceleration,
      gyro: gyroscope,
      temp: temperature
    }
  end

  # 合成加速度を計算
  # @return [Float] 合成加速度（G単位）
  def magnitude
    accel = acceleration
    Math.sqrt(accel[:x] ** 2 + accel[:y] ** 2 + accel[:z] ** 2)
  end

  # 傾斜角度を計算（度単位）
  # @return [Hash] {pitch: Float, roll: Float}
  def tilt_angles
    accel = acceleration
    
    # ピッチ角（X軸周り）
    pitch = Math.atan2(accel[:y], Math.sqrt(accel[:x] ** 2 + accel[:z] ** 2)) * 180.0 / Math::PI
    
    # ロール角（Y軸周り）  
    roll = Math.atan2(-accel[:x], Math.sqrt(accel[:y] ** 2 + accel[:z] ** 2)) * 180.0 / Math::PI
    
    { pitch: pitch, roll: roll }
  end

  # 動きを検出（加速度の変化）
  # @param threshold [Float] 検出閾値（G単位、デフォルト0.1G）
  # @return [Boolean] 動きを検出した場合true
  def motion_detected?(threshold = 0.1)
    magnitude > (1.0 + threshold) || magnitude < (1.0 - threshold)
  end

  private

  # センサー初期化
  def init_sensor
    # チップID確認
    chip_id = read_reg(REG_WHO_AM_I, 1)[0]
    raise "Invalid MPU6886 chip ID: 0x#{chip_id.to_s(16)} (expected: 0x#{CHIP_ID.to_s(16)})" unless chip_id == CHIP_ID
    
    # デバイスをリセット
    write_reg(REG_PWR_MGMT_1, 0x80)
    sleep_ms 100
    
    # スリープモード解除
    write_reg(REG_PWR_MGMT_1, 0x00)
    sleep_ms 10
    
    # デフォルト設定
    self.accel_range = ACCEL_RANGE_2G
    self.gyro_range = GYRO_RANGE_250DPS
    
    sleep_ms 10
  end

  # レジスタに書き込み
  # @param reg [Integer] レジスタアドレス
  # @param data [Integer] 書き込みデータ
  def write_reg(reg, data)
    result = @i2c.write(I2C_ADDRESS, reg, data, timeout: 2000)
    unless result > 0
      raise IOError, "MPU6886 write failed (reg: 0x#{reg.to_s(16)}, data: 0x#{data.to_s(16)})"
    end
  end

  # レジスタから読み取り
  # @param reg [Integer] レジスタアドレス
  # @param length [Integer] 読み取りバイト数
  # @return [Array<Integer>] 読み取ったデータの配列
  def read_reg(reg, length)
    data = @i2c.read(I2C_ADDRESS, length, reg, timeout: 1000)
    
    if data.nil? || data.empty?
      raise IOError, "MPU6886 read failed (reg: 0x#{reg.to_s(16)}, length: #{length})"
    end
    
    # String から byte array に変換
    data.bytes
  end

  # 16ビット値をsigned integerに変換
  # @param value [Integer] unsigned 16ビット値
  # @return [Integer] signed 16ビット値
  def to_signed_16bit(value)
    value > 32767 ? value - 65536 : value
  end
end
