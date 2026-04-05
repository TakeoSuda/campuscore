require './app' # app.rb を読み込んで設定（set :database）を取り込む
require 'sinatra/activerecord/rake'

# Rakeタスクが実行される前に、強制的に接続を確立させる設定
namespace :db do
  task :load_config do
    # app.rb で設定した :database の内容を ActiveRecord に直接教え込む
    ActiveRecord::Base.establish_connection(ENV['DATABASE_URL'] || Sinatra::Application.settings.database)
  end
end

