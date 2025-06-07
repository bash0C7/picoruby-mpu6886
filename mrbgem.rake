MRuby::Gem::Specification.new('picoruby-mpu6886') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Your Name'
  spec.summary = 'MPU6886 6-axis motion sensor driver - Pure Ruby implementation'
  spec.version = '0.1.0'

  # picoruby-i2cに依存（Pure Ruby実装）
  spec.add_dependency 'picoruby-i2c'
  
  # C拡張なし - 全てRuby実装
end
