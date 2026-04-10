module Meridian
  module Config
    class ValidationError < Exception
    end

    class UnknownRole < Exception
    end

    class UnknownAccessory < Exception
    end
  end

  module SSH
    class ConnectionError < Exception
    end

    class CommandFailed < Exception
    end
  end

  module Health
    class CheckFailed < Exception
    end
  end

  module Deploy
    class DeployFailed < Exception
    end

    class RollbackFailed < Exception
    end
  end

  module Proxy
    class SetupFailed < Exception
    end

    class RemoveFailed < Exception
    end
  end

  module Transfer
    class TransferFailed < Exception
    end

    class DependencyMissing < Exception
    end
  end

  module Init
    class Error < Exception
    end

    class PromptAborted < Error
    end

    class OverwriteRefused < Error
    end

    class GenerationError < Error
    end
  end

  module Server
    class BootstrapError < Exception
    end
  end
end
