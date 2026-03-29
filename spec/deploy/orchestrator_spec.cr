require "../spec_helper"

describe "Meridian::Deploy::Orchestrator" do
  describe "#deploy_to_host" do
    pending "issues a podman pull command"
    pending "calls systemctl daemon-reload after writing the Quadlet file"
    pending "starts the new service"
    pending "stops the old service before starting the new one"
    pending "writes the Quadlet file to the correct systemd path"
    pending "raises DeployFailed when the pull command fails"
    pending "raises DeployFailed when systemctl start fails"
  end

  describe "#zero_downtime_deploy_to_host" do
    pending "starts the new colour before stopping the old one"
    pending "invokes kamal-proxy deploy before stopping the old container"
    pending "passes the correct target to kamal-proxy deploy"
    pending "runs the health check before switching proxy traffic"
    pending "does not stop the old container if the health check fails"
    pending "writes the active colour to .meridian-color after a successful deploy"
    pending "prunes old images after a successful deploy"
  end

  describe "#deploy" do
    pending "deploys to all hosts in the web role"
    pending "deploys to all hosts in the workers role"
    pending "respects boot.limit by deploying at most that many hosts at once"
    pending "does not deploy workers until at least one web host has passed its health check"
    pending "aborts the entire deploy if all web hosts fail"
    pending "prefixes log output with the host address"
  end
end
