require './app'
require 'sinatra/activerecord/rake'

# Rakeが起動する際に、Sinatraで設定したデータベース情報を
# 明示的に ActiveRecord に渡す設定です。
namespace :db do
  task :load_config do
    ActiveRecord::Base.establish_connection(ENV['DATABASE_URL'] || Sinatra::Application.settings.database)
  end
end

