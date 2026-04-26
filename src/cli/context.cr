module Meridian
  module CLI
    struct Context
      getter input : IO
      getter output : IO
      getter error : IO
      getter ssh_executor : SSH::Executor
      getter orchestrator_factory : OrchestratorFactory
      getter proxy_manager_factory : ProxyManagerFactory

      def initialize(
        @input : IO,
        @output : IO,
        @error : IO,
        @ssh_executor : SSH::Executor,
        @orchestrator_factory : OrchestratorFactory,
        @proxy_manager_factory : ProxyManagerFactory,
      )
      end
    end
  end
end
