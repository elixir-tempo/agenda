import Config

# Without a real IANA database Elixir resolves every zone as UTC, and
# zone-aware arithmetic is silently wrong rather than failing. Tests and
# development use `tz`; a consuming application configures its own.
if config_env() in [:dev, :test] do
  config :elixir, :time_zone_database, Tz.TimeZoneDatabase
end
