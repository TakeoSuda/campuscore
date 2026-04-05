require './app'
require 'sinatra/activerecord/rake'

# ActiveRecordにファイルの場所を教え込む
ActiveRecord::Tasks::DatabaseTasks.migrations_paths = [File.join(__dir__, 'db/migrate')]

namespace :db do
  task :load_config do
    ActiveRecord::Base.establish_connection(ENV['DATABASE_URL'] || Sinatra::Application.settings.database)
  end
end