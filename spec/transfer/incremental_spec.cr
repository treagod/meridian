require "../spec_helper"

describe "Meridian::Transfer::Incremental" do
  describe "#transfer" do
    pending "exports the image to an OCI layout directory using skopeo"
    pending "rsyncs the OCI directory to the remote host"
    pending "uses rsync with archive and compress flags"
    pending "imports the OCI directory into Podman storage on the remote host via skopeo"
    pending "raises DependencyMissing when skopeo is not installed locally"
    pending "raises DependencyMissing when rsync is not installed locally"
    pending "raises TransferFailed when rsync exits with a non-zero code"
    pending "runs the skopeo export before the rsync"
  end
end
