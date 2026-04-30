# test/mpu6886_test.rb
$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)

# PicoRuby shim: sleep_ms is a Kernel-level method on-device.
# Under CRuby it does not exist; stub it as a no-op for host tests.
module Kernel
  def sleep_ms(_ms); end
end

# PicoRuby shim: 'i2c' is provided by the picoruby runtime as a built-in.
# Under CRuby that file does not exist; mark it as already loaded so that
# `require 'i2c'` in mrblib/mpu6886.rb is a no-op for host tests.
$LOADED_FEATURES << "i2c" unless $LOADED_FEATURES.include?("i2c")

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
    # ACCEL_RANGE_2G scale = 16384 -> 1g = 0x4000 = 16384
    payload = [
      0x40, 0x00,   # ax = 16384  -> 1.0g
      0x00, 0x00,   # ay = 0
      0x00, 0x00,   # az = 0
      0x00, 0x00,   # temp_raw = 0 -> 25.0 C
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
      0xC0, 0x00,   # ax = 0xC000 -> -16384 -> -1.0g at +/-2G
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
