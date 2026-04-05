require './app'
require 'sinatra/activerecord/rake'

# 1. マイグレーションファイルの場所を「絶対パス」で教え込む
ActiveRecord::Tasks::DatabaseTasks.migrations_paths = [File.expand_path('../db/migrate', __FILE__)]

# 2. 接続設定を直接 ActiveRecord の内部にセットする
namespace :db do
  task :load_config do
    # app.rb で設定した :database を直接参照
    db_config = Sinatra::Application.settings.database
    ActiveRecord::Base.establish_connection(db_config)
  end
end

# 3. 念のため、全タスクの前に load_config を走らせる
Rake::Task['db:migrate'].enhance(['db:load_config'])
Rake::Task['db:migrate:status'].enhance(['db:load_config'])
