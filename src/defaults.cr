module Meridian
  module Defaults
    # Default kamal-proxy image. Pinned and docker.io-prefixed so `meridian init`
    # and the generator fallback can never install two different proxy versions
    # (ticket 068). Bump deliberately in its own change.
    PROXY_IMAGE = "docker.io/basecamp/kamal-proxy:v0.9.2"
  end
end
