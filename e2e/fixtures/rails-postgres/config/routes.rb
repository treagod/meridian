Rails.application.routes.draw do
  root "home#index"
  get "records" => "records#index"
  get "up" => "rails/health#show", as: :rails_health_check
end
