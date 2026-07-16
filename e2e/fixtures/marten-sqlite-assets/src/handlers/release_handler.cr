class ReleaseHandler < Marten::Handler
  def get
    respond(File.read("/app/release.txt").strip, content_type: "text/plain")
  end
end
