require './app'
require 'sinatra/activerecord/rake'

# ActiveRecordに「Railsはいないよ、環境はこれだよ」と教える設定
namespace :db do
  task :load_config do
    # Rails.env の代わりに Sinatra の環境（developmentなど）を使うように上書き
    module ::Rails
      def self.env
        ActiveSupport::StringInquirer.new(ENV['RACK_ENV'] || 'development')
      end
    end
  end
end

