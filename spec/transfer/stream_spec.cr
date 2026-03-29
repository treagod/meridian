require "../spec_helper"

describe "Meridian::Transfer::Stream" do
  describe "#transfer" do
    pending "invokes podman save on the source image"
    pending "pipes through zstd compression"
    pending "targets the correct remote host"
    pending "raises TransferFailed when the pipeline exits with a non-zero code"
    pending "raises DependencyMissing when zstd is not installed locally"
    pending "does not require registry configuration"
  end
end
