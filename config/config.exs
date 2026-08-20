import Config

# Without a real IANA database Elixir resolves every zone as UTC, and
# zone-aware arithmetic is silently wrong rather than failing. Tests and
# development use `tz`; a consuming application configures its own.
if config_env() in [:dev, :test] do
  config :elixir, :time_zone_database, Tz.TimeZoneDatabase
end

# `fixpoint` logs "Solution found" at debug for every solution it finds,
# which is some 1,800 lines across the suite — enough to bury a real
# failure. Agenda emits no log messages of its own, so lifting the floor
# to `:info` drops the noise and nothing else. Warnings and errors, from
# the solver or anywhere else, still come through.
#
# A library's config is not read by applications that depend on it, so
# this governs Agenda's own test runs only.
if config_env() == :test do
  config :logger, level: :info
end
