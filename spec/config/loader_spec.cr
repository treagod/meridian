require "../spec_helper"

describe "Meridian::Config::Loader" do
  describe ".load" do
    pending "parses the service name"
    pending "parses the image name"
    pending "parses web server hosts"
    pending "parses the workers role hosts"
    pending "parses a custom CMD for the workers role"
    pending "parses the proxy image"
    pending "parses the proxy host"
    pending "parses the registry server"
    pending "parses clear environment variables"
    pending "parses secret environment variable names"
    pending "applies the default SSH user of 'deploy'"
    pending "applies the default SSH port of 22"
    pending "applies the default boot limit of 1"
    pending "applies the default healthcheck path of /health"
    pending "parses the accessory image"
    pending "parses the accessory host"
    pending "raises a descriptive error when the service key is missing"
    pending "raises a descriptive error when the image key is missing"
    pending "raises a descriptive error when no servers are defined"
    pending "raises an error when the config file does not exist"
    pending "raises an error when the YAML is malformed"
  end
end
