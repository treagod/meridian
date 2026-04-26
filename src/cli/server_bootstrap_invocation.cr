module Meridian
  module CLI
    record ServerBootstrapInvocation,
      host : String?,
      port : Int32?,
      root_user : String,
      deploy_user : String?,
      accept_new_host_key : Bool,
      enable_auto_updates : Bool,
      passwordless_sudo : Bool,
      rootless_low_ports : Bool,
      rootless_port_start : Int32,
      file : String
  end
end
