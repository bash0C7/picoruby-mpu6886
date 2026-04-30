# mrbgem.rake
MRuby::Gem::Specification.new('picoruby-mpu6886') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'MPU6886 6-axis IMU driver - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-i2c'
  spec.add_test_dependency 'picoruby-picotest'
end
