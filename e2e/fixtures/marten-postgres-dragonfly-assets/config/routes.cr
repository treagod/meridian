Marten.routes.draw do
  path "/", HomeHandler, name: "home"
  path "/healthz", HealthzHandler, name: "healthz"
  path "/records", RecordsHandler, name: "records"
  path "/dragonfly", DragonflyHandler, name: "dragonfly"
end
