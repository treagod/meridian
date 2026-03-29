require "../spec_helper"

describe "Meridian::SSH::Executor" do
  describe "#run" do
    pending "returns exit code 0 for a successful command"
    pending "returns the stdout output of the command"
    pending "returns a non-zero exit code for a failing command"
    pending "captures stderr separately from stdout"
    pending "raises SSHConnectionError when the host is unreachable"
    pending "respects a custom SSH port"
    pending "passes environment variables to the remote command"
  end

  describe "#run!" do
    pending "raises CommandFailed when the exit code is non-zero"
    pending "does not raise when the command succeeds"
  end

  describe "#upload" do
    pending "writes content to a file on the remote host"
    pending "raises an error when the remote path is not writable"
  end
end
