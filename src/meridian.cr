require "./errors"
require "./commands/**"
require "./config/loader"
require "./deploy/orchestrator"
require "./health/checker"
require "./proxy/manager"
require "./quadlet/generator"
require "./ssh/executor"
require "./transfer/incremental"
require "./transfer/stream"

module Meridian
  VERSION = "0.1.0"

  module CLI
  end
end
