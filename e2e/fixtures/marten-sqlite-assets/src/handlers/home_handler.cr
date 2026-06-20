class HomeHandler < Marten::Handler
  def get
    render("home.html")
  end
end
