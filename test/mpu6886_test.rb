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
