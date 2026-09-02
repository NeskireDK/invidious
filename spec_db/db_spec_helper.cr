# The globals ArikSettings reads. src/invidious.cr defines them for the real
# program; a spec that reaches the database has to define them itself.
#
# That definition is also why this tree is not under spec/: `crystal spec`
# compiles every file it finds into one program, so a live PG_DB there would
# make the whole fast suite need a PostgreSQL. Run this one with
#
#   INVIDIOUS_TEST_DATABASE_URL=postgres://... crystal spec spec_db/
require "kemal"
require "pg"
require "spectator"
require "../src/invidious/helpers/logger"

PG_DB  = DB.open(ENV["INVIDIOUS_TEST_DATABASE_URL"])
LOGGER = Invidious::LogHandler.new(IO::Memory.new, LogLevel::Error, false)

Spectator.configure do |config|
  config.fail_blank
  config.randomize
end
