require 'sinatra'

enable :sessions

# ❌ 修正前: 常に読み込もうとしてエラーになる
# require 'sinatra/reloader'

# ✅ 修正後: 開発環境（development）の時だけ読み込む
if development?
  require 'sinatra/reloader'
end
require 'sinatra/cookies'

# Renderの環境変数 PORT を受け取り、なければ 10000 を使う
set :port, ENV['PORT'] || 10000

# 重要: '0.0.0.0' にしないと外部（Renderのルーター）からアクセスできません
set :bind, '0.0.0.0'

require 'pg'

# 1. 接続情報を取得
db_url = ENV['DATABASE_URL']

if db_url
  # --- Render（本番環境）の場合 ---
  # DATABASE_URLの末尾に sslmode=require を強制的に付与して接続します
  # これをしないと、データの書き込み（Signup）時に拒否されることがあります
  client = PG.connect("#{db_url}?sslmode=require")
else
  # --- ローカル環境の場合 ---
  client = PG.connect(host: "localhost", dbname: "campuscore")
end

require 'bcrypt'

# 全てのルーティングの前に実行される処理

before do
  # ログインしていなくてもアクセスを許可する「公開ページ」のリスト
  pass_list = [
    '/', 
    '/login', 
    '/signup', 
    '/password_reset', 
    '/password_reset/edit', 
    '/password_reset/update'
  ]
  
  # 「セッションが空」かつ「アクセス先が許可リストにない」場合だけスタート画面へ飛ばす
  if session[:user_id].nil? && !pass_list.include?(request.path_info)
    redirect '/'
  end
end

get '/' do
  # views/index.erb を探しに行きます
  erb :index
end

# ユーザー登録・ログイン関係
get '/signup' do
  erb :signup
end

post "/signup" do
  @name_kana = params[:name_kana]
  @name = params[:name]
  @school = params[:school]
  @grade = params[:grade]

  result = client.exec_params("SELECT email FROM users WHERE email = $1", [params[:email]])
  if result.first
    @error = "そのメールアドレスは既に使用されています"
    result.clear # 使い終わったらクリア
    return erb :signup
  end

  @email = params[:email]
  
  password = params[:password]
  password_confirm = params[:password_confirm]

  # ① パスワード形式チェック
  unless password =~ /\A(?=.*[A-Za-z])(?=.*\d)(?=.*[!@#$%^&*-])[A-Za-z\d!@#$%^&*-]{8,}\z/
    @error = "パスワードは8文字以上で、英字と数字、記号を含めてください"
    return erb :signup
  end

  # ② 確認用パスワードチェック
  if password != password_confirm
    @error = "パスワードが一致しません。"
    return erb :signup
  end

  # ③ OKなら保存
  @password = BCrypt::Password.create(password)




  client.exec_params(
    "INSERT INTO users (name_kana, name, email, password, school, grade) VALUES ($1, $2, $3, $4, $5, $6)",
    [@name_kana, @name, @email, @password, @school, @grade]
  )

  redirect "/login"
end

get '/login' do
  erb :login
end

post "/login" do
  email = params[:email]
  password = params[:password]

  result = client.exec_params("SELECT * FROM users WHERE email = $1", [email])
  user = result.first

  if user && BCrypt::Password.new(user['password']) == password
    session[:user_id] = user['id']

    if user['is_admin'] == 't'
      redirect "/users_info"
    else
      redirect "/mypage"
    end

  else
    @error = "メールアドレスまたはパスワードが間違っています"
    erb :login
  end
end

get '/users_info' do
  redirect '/login' unless session[:user_id]

  user = client.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  halt 404 unless user

  redirect '/' unless user["is_admin"].to_s == 't'

  # 管理者用に必要なカラムだけ取得
  @users = client.exec_params("SELECT id, name, email, school, grade, is_admin FROM users ORDER BY id ASC").to_a

  erb :users_info
end


get '/logout' do
  session.clear
  redirect '/login'
end


# マイページ関係
get '/mypage' do
  user_id = session[:user_id]

  result = client.exec_params(
  "SELECT * FROM users WHERE id=$1",
  [user_id]
  )

  @user = result[0]
  erb :mypage
end

get "/mypage_edit" do
  user_id = session[:user_id]

  result = client.exec_params(
    "SELECT * FROM users WHERE id=$1",
    [user_id]
  )

  @user = result[0]

  erb :mypage_edit
end

post '/mypage_edit' do
  user_id = session[:user_id]
  @name_kana = params[:name_kana]
  @name = params[:name]
  @email = params[:email]
  
current_user = client.exec_params(
  "SELECT * FROM users WHERE id=$1",
  [user_id]
).first
halt 404 unless current_user


# パスワードが入力された時だけ更新するロジック 
if params[:password] && params[:password] != ""
  unless params[:password] =~ /\A(?=.*[A-Za-z])(?=.*\d)(?=.*[!@#$%^&*-])[A-Za-z\d!@#$%^&*-]{8,}\z/
    @error = "パスワードは8文字以上で、英字と数字、記号を含めててください"
    # ここで @user を再取得することで erb :mypage_edit で nil エラーになるのを防いでいる。
    @user = current_user 
    return erb :mypage_edit
  end
  if params[:password] != params[:password_confirm]
    @error = "パスワードが一致しません"
    return erb :mypage_edit
  end

  @password = BCrypt::Password.create(params[:password])
else
  @password = current_user["password"]
end


  @school = params[:school]
  @grade = params[:grade]
  @desired_school = params[:desired_school]
  @faculty = params[:faculty]
  @department = params[:department]
  @second_desired_school = params[:second_desired_school]
  @second_desired_faculty = params[:second_desired_faculty]
  @second_desired_department = params[:second_desired_department]
  @target_ct_reading = params[:target_ct_reading].empty? ? nil : params[:target_ct_reading].to_i
  
  @target_ct_listening = params[:target_ct_listening].empty? ? nil : params[:target_ct_listening].to_i
  
  @last_ct_reading = params[:last_ct_reading].empty? ? nil : params[:last_ct_reading].to_i
  
  @last_ct_listening = params[:last_ct_listening].empty? ? nil : params[:last_ct_listening].to_i

  @eiken_level = params[:eiken_level]
  @desired_eiken_level = params[:desired_eiken_level]
  @strong_subject = params[:strong_subject]
  @weak_subject = params[:weak_subject]
  @hobby = params[:hobby]
  @club = params[:club]
  @desired_job = params[:desired_job]
  @dream = params[:dream]
  @resolution = params[:resolution]
  @consult = params[:consult]
  @worry = params[:worry]
  #追加項目
  @request_for_class = params[:request_for_class]

  # 文字列として受け取る
  recommend_exam_param = params[:recommend_exam]

  # Booleanに変換
  @recommend_exam = recommend_exam_param == "true"

  client.exec_params(
    "UPDATE users SET name_kana=$1, name=$2, email=$3, password=$4, school=$5, grade=$6, desired_school=$7, faculty=$8, department=$9, second_desired_school=$10, second_desired_faculty=$11, second_desired_department=$12, target_ct_reading=$13, target_ct_listening=$14, last_ct_reading=$15, last_ct_listening=$16, eiken_level=$17, desired_eiken_level=$18, strong_subject=$19, weak_subject=$20, hobby=$21, club=$22, desired_job=$23, dream=$24, resolution=$25, consult=$26, worry=$27, recommend_exam=$28, request_for_class=$29 WHERE id=$30",
    [@name_kana, @name, @email, @password, @school, @grade, @desired_school, @faculty, @department, @second_desired_school, @second_desired_faculty, @second_desired_department, @target_ct_reading, @target_ct_listening, @last_ct_reading, @last_ct_listening, @eiken_level, @desired_eiken_level, @strong_subject, @weak_subject, @hobby, @club, @desired_job, @dream, @resolution, @consult, @worry, @recommend_exam, @request_for_class, user_id]
  )

  redirect '/mypage'
end


# チャットルーム関係
get '/chat_rooms/new' do
  # 他のユーザー一覧を取得（自分以外）
  #current_user_id = session[:user_id]
  @users = client.exec_params(
    "SELECT id, name FROM users WHERE name = $1",
    ["須田丈夫"]
  ).to_a

  erb :new_chat_room
end

post '/chat_rooms' do
  current_user_id = session[:user_id]
  other_user_id = params[:user_id].to_i  # フォームから送られてくる相手ID

  # 新しいチャットルームを作成（個別チャットは名前なし）
  result = client.exec_params(
    "INSERT INTO chat_rooms (name) VALUES ($1) RETURNING id",
    [nil]
  )
  chat_room_id = result[0]["id"]

  # 参加者を登録（自分と相手）
  [current_user_id, other_user_id].each do |uid|
    client.exec_params(
      "INSERT INTO chat_room_users (chat_room_id, user_id) VALUES ($1, $2)",
      [chat_room_id, uid]
    )
  end

  redirect "/chat_rooms/#{chat_room_id}"
end



get '/chat_rooms' do
  user_id = session[:user_id]
  
  # 自分が参加しているルームを取得
  @chat_rooms = client.exec_params(
    "SELECT cr.* FROM chat_rooms cr
     JOIN chat_room_users cru ON cr.id = cru.chat_room_id
     WHERE cru.user_id=$1",
     [user_id]
  ).to_a

  erb :chat_rooms
end


get '/chat_rooms/:id' do
  chat_room_id = params[:id]
  
  # ルーム情報
  @chat_room = client.exec_params("SELECT * FROM chat_rooms WHERE id=$1", [chat_room_id])[0]
  
  # メッセージ一覧
  @messages = client.exec_params(
    "SELECT m.*, u.name FROM messages m
     JOIN users u ON m.sender_id = u.id
     WHERE chat_room_id=$1
     ORDER BY created_at ASC",
     [chat_room_id]
  ).to_a

  erb :chat_room
end


post '/chat_rooms/:id/messages' do
  chat_room_id = params[:id]
  sender_id = session[:user_id]
  content = params[:content]

  client.exec_params(
    "INSERT INTO messages (chat_room_id, sender_id, content) VALUES ($1, $2, $3)",
    [chat_room_id, sender_id, content]
  )

  redirect "/chat_rooms/#{chat_room_id}"
end


#合格計画関係

get '/plan_new' do
  erb :plan_new
end

post '/plan_new' do
  @user_id = session[:user_id]
  @subject = params[:subject]
  @material = params[:material]
  @start_date = params[:start_date]
  @end_date = params[:end_date]
  @laps = params[:laps].to_i
  @completed_laps = params[:completed_laps].to_i
  @purpose = params[:purpose]
  @status = params[:status]
  
  client.exec_params(
    "INSERT INTO plans (user_id, subject, material, start_date, end_date, laps, completed_laps, purpose, status) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
    [@user_id, @subject, @material, @start_date, @end_date, @laps, @completed_laps, @purpose, @status]
  )

  redirect '/plans'
end

get '/plans' do
  @user_id = session[:user_id]
  @plans = client.exec_params(
    "SELECT * FROM plans
      WHERE user_id = $1
      ORDER BY created_at ASC",
    [@user_id]
  ).to_a

  erb :plans
end

get '/plans/:id/edit' do
  @plan_id = params[:id].to_i
  @plan = client.exec_params(
    "SELECT * FROM plans WHERE id=$1",
    [@plan_id]
  ).first

  erb :plan_edit
end

post '/plans/:id/edit' do
  @plan_id = params[:id].to_i
  @subject = params[:subject]
  @material = params[:material]
  @start_date = params[:start_date]
  @end_date = params[:end_date]
  @laps = params[:laps].to_i
  @completed_laps = params[:completed_laps].to_i
  @purpose = params[:purpose]
  @status = params[:status]

  client.exec_params(
    "UPDATE plans SET subject=$1, material=$2, start_date=$3, end_date=$4, laps=$5, completed_laps=$6, purpose=$7, status=$8 WHERE id=$9",
    [@subject, @material, @start_date, @end_date, @laps, @completed_laps, @purpose, @status, @plan_id]
  )

  redirect '/plans'
end

#面談記録関係

get '/consults' do
  @user_id = session[:user_id]
  @consults = client.exec_params(
    "SELECT * FROM consults
      WHERE user_id = $1
      ORDER BY date DESC",
    [@user_id]
  ).to_a
  erb :consults
end

post '/consults/new' do
  @user_id = session[:user_id]
  @content = params[:content]
  @date = params[:date]
  
  client.exec_params(
    "INSERT INTO consults (user_id, content, date) VALUES ($1, $2, $3)",
    [@user_id, @content, @date]
  )

  redirect '/consults'
end

#勉強日記関係
get '/diary' do
  @user_id = session[:user_id]
  @diary_entries = client.exec_params(
    "SELECT * FROM diary_entries
      WHERE user_id = $1
      ORDER BY date DESC",
    [@user_id]
  ).to_a
  erb :diary
end

post '/diary/new' do
  @user_id = session[:user_id]
  @content = params[:content]
  @date = params[:date]

  client.exec_params(
    "INSERT INTO diary_entries (user_id, content, date) VALUES ($1, $2, $3)",
    [@user_id, @content, @date]
  )

  redirect '/diary'
end

get '/recommends' do
	@user_id = session[:user_id]
	erb :recommends
end

# 英語レベルに基づく教材推薦
post '/recommends' do 
# 1. フォームデータの受け取り 
@user_id = session[:user_id]
@w_lv = params[:word_level].to_i 
@g_lv = params[:grammar_level].to_i 
@r_lv = params[:reading_level].to_i

 client.exec_params(
   "INSERT INTO english_levels (user_id, word_level, grammar_level, reading_level) VALUES ($1, $2, $3, $4)",
   [@user_id, @w_lv, @g_lv, @r_lv]
 )

@current_user = client.exec_params(
  "SELECT * FROM users WHERE id=$1",
  [@user_id]
).first
halt 404 unless @current_user

@recommended_books = client.exec_params( "SELECT * FROM english_books 
WHERE (category = 'word' AND level = $1) 
OR (category = 'grammar' AND level = $2) 
OR (category = 'reading' AND level = $3) 
ORDER BY category ASC, level DESC", 
[@w_lv, @g_lv, @r_lv] ).to_a

erb :recommends_results 
end

# 英語参考書の良書一覧
get '/recommends_list' do
  @user_id = session[:user_id]
  @recommendations = client.exec_params(
    "SELECT * FROM english_books eb"
  ).to_a

  erb :recommends_list
end

# パスワードの再設定
get '/password_reset' do
  erb :password_reset
end

require 'pony'

post '/password_reset' do
  email = params[:email]
  user = client.exec_params("SELECT * FROM users WHERE email = $1", [email]).first

  p params
  p user

  if user
    # 1. 使い捨てのランダムな「鍵（トークン）」を作る
    reset_token = SecureRandom.hex(32)
    # 2. データベースにトークンと有効期限（例: 1時間後）を保存する
    client.exec_params(
      "UPDATE users SET reset_token = $1, reset_token_expires_at = NOW() + INTERVAL '1 hour' WHERE id = $2",
      [reset_token, user['id']]
    )

    # 3. ここでメールを送信する
    # パスワードリセット用リンクを含むメール
    # 環境変数 APP_URL があればそれを使い、なければローカル用を使う
    base_url = ENV['APP_URL'] || "http://localhost:10000"
    url = "#{base_url}/password_reset/edit?token=#{reset_token}"
    Pony.mail(
    to: user['email'],
    from: ENV['SMTP_USER'],     # 送信元（自分のアドレス）
    subject: "【CampusCore】パスワード再設定",
    body: "以下のURLをクリックして、1時間以内に再設定を完了してください。\n\n#{url}",
    via: :smtp,
    via_options: {
      address:              'smtp.gmail.com',
      port:                 '587',
      enable_starttls_auto: true,
      user_name:            ENV['SMTP_USER'],     # 環境変数から読み込む
      password:             ENV['SMTP_PASSWORD'], # 環境変数から読み込む
      authentication:       :plain,
      domain:               "localhost.localdomain"
    })
    @message = "ご登録のメールアドレスに再設定用のリンクを送信しました。"
  else
    # セキュリティ上、アドレスが存在するかどうかを教えない場合もあります
    @message = "入力された内容を確認してください"
  end
  erb :password_reset
end

get '/password_reset/edit' do
  @token = params[:token]
  
  # DBからトークンが一致し、かつ期限（1時間）が切れていないユーザーを探す
  user = client.exec_params(
    "SELECT * FROM users WHERE reset_token = $1 AND reset_token_expires_at > NOW()",
    [@token]
  ).first

  if user
    erb :password_reset_edit # パスワード入力フォームを表示
  else
    @message = "このリンクは無効か、有効期限が切れています。"
    erb :password_reset
  end
end

post '/password_reset/update' do
  token = params[:token]
  password = params[:password]
  password_confirm = params[:password_confirm]

  # 1. パスワードの一致チェック
  if password != password_confirm
    @error = "パスワードが一致しません。"
    @token = token
    return erb :password_reset_edit
  end

  # 2. パスワードのバリデーション（以前作った正規表現を使うのがベスト！）
  # ...（ここに正規表現のチェックを入れる）...
  unless password =~ /\A(?=.*[A-Za-z])(?=.*\d)(?=.*[!@#$%^&*-])[A-Za-z\d!@#$%^&*-]{8,}\z/
    @error = "パスワードは8文字以上で、英字と数字、記号を含めてください"
    @token = token
    return erb :password_reset_edit
  end

  # 3. パスワードをハッシュ化して更新し、トークンを無効化する
  hashed_password = BCrypt::Password.create(password)
  
  result = client.exec_params(
    "UPDATE users SET password = $1, reset_token = NULL, reset_token_expires_at = NULL 
     WHERE reset_token = $2 AND reset_token_expires_at > NOW() RETURNING id",
    [hashed_password, token]
  )

  if result.first
    @message = "パスワードを更新しました。新しいパスワードでログインしてください。"
    erb :login
  else
    "エラーが発生しました。もう一度やり直してください。"
  end
end

