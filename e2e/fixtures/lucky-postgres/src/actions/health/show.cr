# Unauthenticated probe target for Meridian's health check.
class Health::Show < Lucky::Action
  default_format :plain_text

  get "/health" do
    plain_text "ok"
  end
end
