# picoruby-mpu6886 — Repo-Local Rules for Claude Code

This is a **PicoRuby Runtime Gem** following upstream `picoruby/picoruby`
conventions (closest analog: `picoruby-aht25`). All logic is pure Ruby.
There is no C extension and none should be added.

## Public API contract — DO NOT BREAK

The
[mrubygirls Atom Matrix guide](https://mrubygirls.github.io/guides/esp32/atom_matrix/sensor_g_accel)
publicly references this gem. The following surface is frozen:

- `MPU6886.new(i2c)`
- `mpu.acceleration` → `{x: Float, y: Float, z: Float}` in G
- `mpu.gyroscope`, `mpu.temperature`, `mpu.read_all` (return shapes)
- All `ACCEL_RANGE_*` / `GYRO_RANGE_*` constants

When in doubt, run `bundle exec rake test` — the regression tests guard the
above shapes.

## PicoRuby compatibility

Per `~/CLAUDE.md`, **avoid** these in `mrblib/*.rb`:

- `defined?` (use `Object.const_defined?(:Sym)` instead)
- `Hash#fetch`
- `String#reverse`, `String#rjust`
- inline `rescue`
- `proc`, `lambda`

`sleep_ms` is the cooperative-yield delay (`mrubyc/src/rrt0.c:1507`). Use it
freely — it allows other tasks to run during the wait. Do **not** swap it for
`Machine.delay_ms`; both behave the same with respect to task switching.

## Task-spawn pattern (dual-engine)

For any future async feature, use the picoruby-psg pattern:

```ruby
if RUBY_ENGINE == "mruby/c"
  $__global = self
  mrb = PicoRubyVM::InstructionSequence.compile('$__global._method').to_binary
  task = Task.create(mrb)
  task&.run
else
  obj = self
  task = Task.new { obj._method }
end
```

This works on both R2P2-ESP32 (mruby/c) and microruby host builds.

## Tests

- Host-side: `bundle exec rake test` (CRuby + test-unit, with `FakeI2C` double).
- On-device: declared via `add_test_dependency 'picoruby-picotest'`; not wired
  to a default rake target because no `picoruby` binary is required for
  CRuby development.
- Background `start_sampling` is **not** host-tested — it requires a running
  Task scheduler. Validate it via the combat-proof example in
  `picoruby-recipes/components/R2P2-ESP32/storage/home/imu_async.rb`.

## Combat-proof location

Reference Ruby examples for ATOM Matrix live in
`~/dev/src/github.com/bash0C7/picoruby-recipes/components/R2P2-ESP32/storage/home/`.
After any non-trivial change, smoke-test:

- `imu.rb` — synchronous polling, the existing baseline (must keep working).
- `imu_async.rb` — background sampler with concurrent main-loop work.

`rake build` / `rake flash` / `rake monitor` in `picoruby-recipes` are
human-driven; Claude Code does not run them.

## Git

- Conventional Commits: `feat` / `fix` / `docs` / `test` / `refactor` / `chore`.
- Imperative mood, English only.
- Per `~/CLAUDE.md` TDD discipline, RED / GREEN / REFACTOR are independent
  commits.
