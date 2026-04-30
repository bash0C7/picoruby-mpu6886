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
