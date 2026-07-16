Marten.routes.draw do
  path "/", HomeHandler, name: "home"
  path "/health", HealthHandler, name: "health"
  path "/records", RecordsHandler, name: "records"
  path "/release", ReleaseHandler, name: "release"
end
