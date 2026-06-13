require 'sinatra'
require 'pg'
require 'bcrypt'
require 'pony'
require 'securerandom'
require 'sinatra/cookies'
require 'json' # JSONを扱うために必要
require 'rack/cors' # 読み込みを忘れない

# --- 修正後のセキュリティ設定 ---

# 1. 全体的な保護機能を有効に戻す
enable :protection

# 2. React(ポート5174)からの通信で発生する「怪しい」と判定されやすい項目だけを例外にする
set :protection, :except => [:http_origin, :remote_token, :session_hijacking]

use Rack::Cors do
  allow do
    # Reactが動いているURLを正確に指定
    origins 'http://localhost:5174'
    # 全てのAPIエンドポイント、全てのヘッダー、POSTを含むメソッドを許可
    resource '*', headers: :any, methods: [:get, :post, :options]
  end
end

# --- 1. データベース接続設定 (一箇所に集約) ---
db_url = ENV['DATABASE_URL']
if db_url
  # Render環境（SSLモードを有効にして接続）
  client = PG.connect("#{db_url}?sslmode=require")
else
  # ローカル環境（自分のMac）
  client = PG.connect(host: "localhost", dbname: "campus_db_34pr")
end

# --- 2. Sinatraの基本設定 ---
enable :sessions

# 開発環境のみリローダー（自動更新）を有効にする
if development?
  require 'sinatra/reloader'
end

# Renderなどの外部環境でポート番号を正しく認識させる設定
set :port, ENV['PORT'] || 10000
set :bind, '0.0.0.0'

# --- 3. ログインチェック (beforeフィルタ) ---
before do
  # ログインなしでアクセスできるページ
  pass_list = [
    '/', 
    '/login', 
    '/signup', 
    '/password_reset', 
    '/password_reset/edit', 
    '/password_reset/update',
    '/api/quiz_results' # ← 【ここを追加！】ReactからのPOSTリクエストもログインなしで受け取れるようにする
  ]
  
  if session[:user_id].nil? && !pass_list.include?(request.path_info)
    redirect '/'
  end
end

# ReactからのPOSTリクエストを受け取る窓口
post '/api/quiz_results' do
  # 1. データの受信設定
  content_type :json
  
  begin
    # 2. Reactから届いたJSONをRubyのハッシュに変換
    payload = JSON.parse(request.body.read)
    
    # 【チェック！】ターミナルに中身を表示させる
  puts "受け取ったデータ: #{payload.inspect}"
    
    user_id = payload['user_id']
    results = payload['results'] # クイズ結果の配列

  puts "resultsの中身: #{results.inspect}" # ここが [] だと保存されない

    # 3. データベースに接続
    # Render環境なら ENV['DATABASE_URL'] を使い、ローカルなら自分のDB名を入れる
    db_config = ENV['DATABASE_URL'] || { dbname: 'campus_db_34pr' }
    client = PG.connect(db_config)

    # 4. 各問題の結果を1つずつ保存（INSERT）
    results.each do |res|
      client.exec_params(
        "INSERT INTO quiz_results (user_id, question_text, user_answer, is_correct) VALUES ($1, $2, $3, $4)",
        [
          user_id,
          res['questionText'], # React側のプロパティ名に合わせる
          res['userAnswer'],
          res['isCorrect']
        ]
      )
    end

    # 5. 成功したことをReactに伝える
    status 200
    { message: "保存が完了しました" }.to_json

  rescue => e
    # エラーが起きた場合
    status 500
    { error: e.message }.to_json
  ensure
    # 6. 最後に必ずDB接続を閉じる
    client.close if client
  end
end

# --- ここから下に get '/' do ... などのルーティングを続ける ---

get '/' do
  # views/index.erb を探しに行く
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
    session[:user_name] = user['name']

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

  #学年ごとに生徒の名前を50音順で表示するためのSQLクエリを作成
  users_list = client.exec_params("SELECT id, name, name_kana, grade, campus FROM users ORDER BY grade ASC, name_kana ASC").to_a
  @users_by_campus = users_list.group_by { |user| user['campus'] }

  # SQL実行
  raw_data = client.exec_params("
    SELECT 
      users.*, 
      plans.subject AS p_subject, plans.material AS p_material, plans.status AS p_status, plans.start_date AS p_start_date, plans.end_date AS p_end_date,
      diary_entries.content AS d_content, diary_entries.date AS d_date,
      consults.content AS c_content, consults.date AS c_date,
      instructions.content AS i_content, instructions.created_at AS i_created_at,
      instruction_replies.content AS ir_content, instruction_replies.created_at AS ir_created_at, instruction_replies.user_id AS ir_user_id
    FROM users 
    LEFT JOIN plans ON users.id = plans.user_id 
    LEFT JOIN diary_entries ON users.id = diary_entries.user_id 
    LEFT JOIN consults ON users.id = consults.user_id
    LEFT JOIN instructions ON users.id = instructions.user_id OR instructions.user_id IS NULL
    LEFT JOIN instruction_replies ON instructions.id = instruction_replies.instruction_id
    ORDER BY users.name_kana ASC
  ").to_a

  # データをユーザーごとにグルーピングする
  users_hash = {}
  raw_data.each do |row|
    uid = row['id']
    unless users_hash[uid]
      users_hash[uid] = row.merge({ 'plans' => [], 'diaries' => [], 'consults' => [], 'instructions' => []})
    end

    # 重複を避けつつデータを追加（IDなどで判定するのが理想だが、簡易的に内容で判定）
    users_hash[uid]['plans'] << { 'subject' => row['p_subject'], 'material' => row['p_material'], 'status' => row['p_status'], 'start_date' => row['p_start_date'], 'end_date' => row['p_end_date'] } if row['p_subject']
    users_hash[uid]['diaries'] << { 'content' => row['d_content'], 'date' => row['d_date'] } if row['d_content']
    users_hash[uid]['consults'] << { 'content' => row['c_content'], 'date' => row['c_date'] } if row['c_content']
    users_hash[uid]['instructions'] << { 'content' => row['i_content'], 'created_at' => row['i_created_at'], 'reply_content' => row['ir_content'], 'reply_created_at' => row['ir_created_at'], 'ir_user_id' => row['ir_user_id'] } if row['i_content']
  end

  @users = users_hash.values.map do |u|
    u['plans'].uniq!; u['diaries'].uniq!; u['consults'].uniq!; u['instructions'].uniq!
    # 日記を日付順（新しい順）に並び替える【追加】
    u['diaries'].sort_by! { |d| d['date'] }.reverse! if u['diaries']
    # 相談を日付順（新しい順）に並び替える【追加】
    u['consults'].sort_by! { |c| c['date'] }.reverse! if u['consults']
    # 指示を日付順（新しい順）に並び替える【追加】
    u['instructions'].sort_by! { |i| i['created_at'] }.reverse! if u['instructions']
    u
  end

  erb :users_info
end

# 個別ユーザーの詳細表示
get '/users_info/:id' do
  redirect '/login' unless session[:user_id]
  user = client.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  halt 404 unless user
  redirect '/' unless user["is_admin"].to_s == 't'
    
  target_id = params[:id]

  # 特定のユーザー1人分だけをJOINで取得
  raw_data = client.exec_params("
    SELECT users.*, 
           plans.subject AS p_subject, plans.material AS p_material, plans.status AS p_status, plans.start_date AS p_start_date, plans.end_date AS p_end_date,
           diary_entries.content AS d_content, diary_entries.date AS d_date,
           consults.content AS c_content, consults.date AS c_date,
           instructions.content AS i_content, instructions.created_at AS i_created_at,
           instruction_replies.content AS ir_content, instruction_replies.created_at AS ir_created_at, instruction_replies.user_id AS ir_user_id,
          mock_exams.english_r AS me_english_r, mock_exams.english_l AS me_english_l, mock_exams.math_1a AS me_math_1a, mock_exams.math_2bc AS me_math_2bc, mock_exams.japanese AS me_japanese, mock_exams.physics_basic AS me_physics_basic, mock_exams.chemistry_basic AS me_chemistry_basic, mock_exams.biology_basic AS me_biology_basic, mock_exams.earth_science_basic AS me_earth_science_basic, mock_exams.physics AS me_physics, mock_exams.chemistry AS me_chemistry, mock_exams.biology AS me_biology, mock_exams.earth_science AS me_earth_science, mock_exams.world_history AS me_world_history, mock_exams.japanese_history AS me_japanese_history, mock_exams.geography AS me_geography, mock_exams.civics_ethics AS me_civics_ethics, mock_exams.civics_politics AS me_civics_politics, mock_exams.geography_basic AS me_geography_basic, mock_exams.history_basic AS me_history_basic, mock_exams.civics_basic AS me_civics_basic, mock_exams.informatics AS me_informatics, mock_exams.taken_at AS me_taken_at
    FROM users 
    LEFT JOIN plans ON users.id = plans.user_id 
    LEFT JOIN diary_entries ON users.id = diary_entries.user_id 
    LEFT JOIN consults ON users.id = consults.user_id
    LEFT JOIN instructions ON users.id = instructions.user_id OR instructions.user_id IS NULL
    LEFT JOIN instruction_replies ON instructions.id = instruction_replies.instruction_id
    LEFT JOIN mock_exams ON users.id = mock_exams.user_id
    WHERE users.id = $1
  ", [target_id]).to_a

  halt 404 if raw_data.empty?

  # 1人分のデータを整理（前のロジックを活用）
  user_data = raw_data.first.merge({ 'plans' => [], 'diaries' => [], 'consults' => [], 'instructions' => [], 'mock_exams' => [] })
  
  raw_data.each do |row|
    user_data['plans'] << { 'subject' => row['p_subject'], 'material' => row['p_material'], 'status' => row['p_status'], 'start_date' => row['p_start_date'], 'end_date' => row['p_end_date'] }
    user_data['diaries'] << { 'content' => row['d_content'], 'date' => row['d_date'] } if row['d_content']
    user_data['consults'] << { 'content' => row['c_content'], 'date' => row['c_date'] } if row['c_content']
    user_data['instructions'] << { 'content' => row['i_content'], 'created_at' => row['i_created_at'], 'reply_content' => row['ir_content'], 'reply_created_at' => row['ir_created_at'], 'ir_user_id' => row['ir_user_id'] } if row['i_content']
    user_data['mock_exams'] << { 'english_r' => row['me_english_r'], 'english_l' => row['me_english_l'], 'math_1a' => row['me_math_1a'], 'math_2bc' => row['me_math_2bc'], 'japanese' => row['me_japanese'], 'physics_basic' => row['me_physics_basic'], 'chemistry_basic' => row['me_chemistry_basic'], 'biology_basic' => row['me_biology_basic'], 'earth_science_basic' => row['me_earth_science_basic'], 'physics' => row['me_physics'], 'chemistry' => row['me_chemistry'], 'biology' => row['me_biology'], 'earth_science' => row['me_earth_science'], 'world_history' => row['me_world_history'], 'japanese_history' => row['me_japanese_history'], 'geography' => row['me_geography'], 'civics_ethics' => row['me_civics_ethics'], 'civics_politics' => row['me_civics_politics'], 'geography_basic' => row['me_geography_basic'], 'history_basic' => row['me_history_basic'], 'civics_basic' => row['me_civics_basic'], 'informatics' => row['me_informatics'], 'taken_at' => row['me_taken_at']} if row['me_english_r']
  end


  # 重複削除
  user_data['plans'].uniq!; user_data['diaries'].uniq!; user_data['consults'].uniq!; user_data['instructions'].uniq!; user_data['mock_exams'].uniq!
  user_data['diaries'].sort_by! { |d| d['date'] }.reverse! if user_data['diaries']
  user_data['consults'].sort_by! { |c| c['date'] }.reverse! if user_data['consults']
  user_data['instructions'].sort_by! { |i| i['created_at'] }.reverse! if user_data['instructions']
  user_data['mock_exams'].sort_by! { |m| m['taken_at'] }.reverse! if user_data['mock_exams']
  @user = user_data
  erb :user_detail # 新しいViewファイル
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

# ここで @is_admin に真偽値を振っておくと、erbで使いやすくなる
  @is_admin = (@user['is_admin'] == 't' || @user['is_admin'] == true)

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

  @campus = params[:campus]
  @school = params[:school]
  @grade = params[:grade]
  @desired_school = params[:desired_school]
  @faculty = params[:faculty]
  @department = params[:department]
  @second_desired_school = params[:second_desired_school]
  @second_desired_faculty = params[:second_desired_faculty]
  @second_desired_department = params[:second_desired_department]
  @third_desired_school = params[:third_desired_school]
  @third_desired_faculty = params[:third_desired_faculty]
  @third_desired_department = params[:third_desired_department]

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
    "UPDATE users SET name_kana=$1, name=$2, email=$3, password=$4, campus=$5, school=$6, grade=$7, desired_school=$8, faculty=$9, department=$10, second_desired_school=$11, second_desired_faculty=$12, second_desired_department=$13, third_desired_school=$14, third_desired_faculty=$15, third_desired_department=$16, target_ct_reading=$17, target_ct_listening=$18, last_ct_reading=$19, last_ct_listening=$20, eiken_level=$21, desired_eiken_level=$22, strong_subject=$23, weak_subject=$24, hobby=$25, club=$26, desired_job=$27, dream=$28, resolution=$29, consult=$30, worry=$31, recommend_exam=$32, request_for_class=$33 WHERE id=$34",
    [@name_kana, @name, @email, @password, @campus, @school, @grade, @desired_school, @faculty, @department, @second_desired_school, @second_desired_faculty, @second_desired_department, @third_desired_school, @third_desired_faculty, @third_desired_department, @target_ct_reading, @target_ct_listening, @last_ct_reading, @last_ct_listening, @eiken_level, @desired_eiken_level, @strong_subject, @weak_subject, @hobby, @club, @desired_job, @dream, @resolution, @consult, @worry, @recommend_exam, @request_for_class, user_id]
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

  # 2. パスワードのバリデーション（以前作った正規表現を使うのが良い）
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

# 勉強法の指示関係

get '/instructions' do
  user_id = session[:user_id]

  # テーブル名（instructions, reads）をすべて省略せずに記述したSQL
  raw_data = client.exec_params("
    SELECT instructions.*, reads.read_at, reads.id AS read_record_id, instruction_replies.content AS ir_content, instruction_replies.created_at AS ir_created_at
    FROM instructions
    LEFT JOIN reads ON instructions.id = reads.instruction_id AND reads.user_id = $1
    LEFT JOIN instruction_replies ON instructions.id = instruction_replies.instruction_id
    WHERE instructions.user_id = $1 OR instructions.user_id IS NULL
    ORDER BY instructions.created_at DESC",
    [user_id]
  ).to_a
  
  # データを指示ごとにグルーピングする
  instructions_hash = {}
  raw_data.each do |row|
    i_id = row['id']
    unless instructions_hash[i_id]
      instructions_hash[i_id] = row.merge({ 'replies' => [] })
    end

    # 重複を避けつつデータを追加（IDなどで判定するのが理想だが、簡易的に内容で判定）
    instructions_hash[i_id]['replies'] << { 'content' => row['ir_content'], 'created_at' => row['ir_created_at'] } if row['ir_content']
  end

  @instructions = instructions_hash.values.map do |i|
    i['replies'].uniq! # 重複削除
    i
  end

  erb :instructions
end

post '/instructions/:id/read' do
  @user_id = session[:user_id]
  instruction_id = params[:id]
  
  # データベースを更新
  client.exec_params(
    "INSERT INTO reads (instruction_id, user_id) VALUES ($1, $2)",
    [instruction_id, @user_id]
  )
  
  redirect '/instructions'
end

get '/instructions/new' do
  @users = client.exec_params("SELECT id, name FROM users ORDER BY name ASC").to_a
  erb :make_instructions
end

post '/instructions/new' do
  user_id = params[:user_id]
  # 全員向け（NULL）の場合は、空文字ではなくnilにする処理
  target_user_id = (user_id == "" || user_id.nil?) ? nil : user_id

client.exec_params(
    "INSERT INTO instructions (content, category, user_id, created_at, updated_at) 
     VALUES ($1, $2, $3, NOW(), NOW())",
    [params[:content], params[:category], target_user_id]
  )

  redirect '/instructions'
end

post '/instructions/:id/reply' do
  instruction_id = params[:id]
  user_id = session[:user_id]
  content = params[:content]

  client.exec_params(
    "INSERT INTO instruction_replies (instruction_id, user_id, content, created_at) VALUES ($1, $2, $3, NOW())",
    [instruction_id, user_id, content]
  )

  redirect "/instructions"
end

# 模試結果入力関係

get '/mock_exams' do

  user_id = session[:user_id]
  @mock_exams = client.exec_params(
    "SELECT * FROM mock_exams WHERE user_id = $1 ORDER BY taken_at DESC",
    [user_id]
  ).to_a



  erb :mock_exams
end

post '/mock_exams/new' do
  user_id = session[:user_id]
  english_r = params[:english_r].to_i
  english_l = params[:english_l].to_i
  math_1a = params[:math_1a].to_i
  math_2bc = params[:math_2bc].to_i
  japanese = params[:japanese].to_i
  physics_basic = params[:physics_basic].to_i
  chemistry_basic = params[:chemistry_basic].to_i
  biology_basic = params[:biology_basic].to_i
  earth_science_basic = params[:earth_science_basic].to_i
  physics = params[:physics].to_i
  chemistry = params[:chemistry].to_i
  biology = params[:biology].to_i
  earth_science = params[:earth_science].to_i
  world_history = params[:world_history].to_i
  japanese_history = params[:japanese_history].to_i
  geography = params[:geography].to_i
  civics_ethics = params[:civics_ethics].to_i
  civics_politics = params[:civics_politics].to_i
  geography_basic = params[:geography_basic].to_i
  history_basic = params[:history_basic].to_i
  civics_basic = params[:civics_basic].to_i
  informatics = params[:informatics].to_i
  taken_at = params[:taken_at]

  client.exec_params(
    "INSERT INTO mock_exams (user_id, english_r, english_l, math_1a, math_2bc, japanese, physics_basic, chemistry_basic, biology_basic, earth_science_basic, physics, chemistry, biology, earth_science, world_history, japanese_history, geography, civics_ethics, civics_politics, geography_basic, history_basic, civics_basic, informatics, taken_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24)",
    [user_id, english_r, english_l, math_1a, math_2bc, japanese, physics_basic, chemistry_basic, biology_basic, earth_science_basic, physics, chemistry, biology, earth_science, world_history, japanese_history, geography, civics_ethics, civics_politics, geography_basic, history_basic, civics_basic, informatics, taken_at]
  )

  redirect '/mock_exams'
end


# オンライン試験関係
get '/quiz_select' do
  erb :quiz_select
end

get '/quiz/:category' do
  user_id = session[:user_id]
  @quiz = client.exec_params(
    "SELECT * FROM english_questions WHERE category = $1 ORDER BY id ASC LIMIT 20 OFFSET 46",
    [params[:category]]
  ).to_a

  erb :quiz
end

post '/quiz/submit' do
  user_id = session[:user_id]
  user_answers = params["answers"]
  @correct_count = 0  # 正解数を数えるカウンター

  if user_answers
    user_answers.each do |_index, data|
      question_id = data["id"].to_i
      chosen_option = data["chosen"].to_i

      # 1. データベースから、その問題の正解を取得する
      question = client.exec_params(
        "SELECT correct_option FROM english_questions WHERE id = $1", 
        [question_id]
      ).first

      # 2. ユーザーの回答と正解が一致しているか判定し、true か false を決める
      is_correct = false
      if question && question["correct_option"].to_i == chosen_option
        is_correct = true
        @correct_count += 1  # 正解だったらカウントを増やす
      end

      # 3. 「誰が」「どの問題に」「何と答え」「正解したか」を1回でインサートする
      client.exec_params(
        "INSERT INTO answer_logs (user_id, question_id, selected_option, is_correct, answered_at) 
         VALUES ($1, $2, $3, $4, NOW())",
        [user_id, question_id, chosen_option, is_correct]
      )
    end
  end

  redirect '/quiz_result'
end

get '/quiz_result' do
  user_id = session[:user_id]
  test_id = session[:test_id] # もしテストIDを渡す場合はここで受け取る

  @correct_answers = client.exec_params(
    "SELECT q.id, q.question_text, q.correct_option, al.selected_option, al.answered_at 
     FROM answer_logs al
     JOIN english_questions q ON al.question_id = q.id
     WHERE al.user_id = $1 AND al.is_correct = true AND al.test_id = $2
     ORDER BY al.answered_at DESC",
    [user_id, test_id]
  ).to_a

  @wrong_answers = client.exec_params(
    "SELECT q.id, q.question_text, q.correct_option, al.selected_option, al.answered_at 
     FROM answer_logs al
     JOIN english_questions q ON al.question_id = q.id
     WHERE al.user_id = $1 AND al.is_correct = false AND al.test_id = $2
     ORDER BY al.answered_at DESC",
    [user_id, test_id]
  ).to_a
  
  @total_count = @correct_answers.length + @wrong_answers.length

  @accuracy_rate = @total_count > 0 ? (@correct_answers.length.to_f / @total_count * 100).round(2) : 0

  erb :quiz_result
end

#全生徒のオンラインテストの成績表示
get '/users_quiz_result' do
  # 管理者かどうかのチェック
  user = client.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  halt 404 unless user
  redirect '/' unless user["is_admin"].to_s == 't'

  @results = client.exec_params(
    "SELECT u.name AS user_name, u.id AS user_id, q.category, q.question_text, al.selected_option, al.is_correct, al.answered_at 
     FROM answer_logs al
     JOIN english_questions q ON al.question_id = q.id
     JOIN users u ON al.user_id = u.id
     ORDER BY al.answered_at DESC"
  ).to_a

  # ユーザーごと、単元ごとの点数を集計するための空のハッシュを用意
  # 構造イメージ: { "ユーザー名" => { "単元名" => { correct: 0, total: 0 } } }
  @user_stats = Hash.new { |h, k| h[k] = Hash.new { |sh, sk| sh[sk] = { correct: 0, total: 0 } } }

  @results.each do |row|
    user = row["user_name"]
    user_id = row["user_id"]
    category = row["category"]
    is_correct = row["is_correct"] == "t" # PostgreSQLのboolean型は文字列の"t"か"f"で届くことが多い

    # 全体数を+1
    @user_stats[user][category][:total] += 1
    # 正解だったら正解数を+1
    @user_stats[user][category][:correct] += 1 if is_correct
  end

  erb :users_quiz_result
end

#ユーザーごとのオンラインテストの成績表示
get '/users_quiz_result/:user_name' do
  @user_name = params[:user_name]

  # 管理者かどうかのチェック
  current_user = client.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  @results = client.exec_params(
    "SELECT q.category, q.question_text, q.option_1, q.option_2, q.option_3, q.option_4, q.correct_option, al.selected_option, al.is_correct, al.answered_at 
     FROM answer_logs al
     JOIN english_questions q ON al.question_id = q.id
     JOIN users u ON al.user_id = u.id
     WHERE u.name = $1
     ORDER BY al.answered_at DESC",
    [@user_name]
  ).to_a

  @correct_answers = @results.select { |r| r["is_correct"] == "t" }
  @wrong_answers = @results.select { |r| r["is_correct"] == "f" }
  @total_count = @results.length
  @accuracy_rate = @total_count > 0 ? (@correct_answers.length.to_f / @total_count * 100).round(2) : 0

  erb :users_quiz_result_detail
end

# クイズ作成用コンソール
# 💡 1. 問題選択コンソールを表示する画面
get '/admin/create-test' do
  # 全ての問題をデータベースから取得
  @questions = client.exec_params(
    "SELECT id, category, question_text FROM english_questions ORDER BY category, id ASC"
  ).to_a

  erb :admin_create_test
end

# 💡 2. 選択された問題を受け取って処理する
post '/admin/save-test' do
  # 画面のチェックボックスで選ばれた問題のID配列を受け取る（例: ["4", "12", "15"])
  selected_ids = params[:question_ids]

  if selected_ids.nil? || selected_ids.empty?
    @error = "問題が選択されていません。最低1問以上選択してください。"
    @questions = client.exec_params("SELECT id, category, question_text FROM english_questions ORDER BY category, id ASC").to_a
    return erb :admin_create_test
  end

  test_name = params[:test_name]
  test_id = client.exec_params("INSERT INTO tests (name) VALUES ($1) RETURNING id", [test_name])[0]["id"]
  selected_ids.each do |q_id|
  client.exec_params("INSERT INTO test_questions (test_id, question_id) VALUES ($1, $2)", [test_id, q_id])
  end
  "テストを保存しました！"

  redirect '/admin/create-test'
end

# admin_create_testで作成したテストの問題を受け取って表示する画面
get '/english_test/:id' do
  test_id = params[:id]

  @test = client.exec_params("SELECT * FROM tests WHERE id=$1", [test_id]).first
  halt 404 unless @test

  @questions = client.exec_params(
    "SELECT q.* FROM english_questions q
     JOIN test_questions tq ON q.id = tq.question_id
     WHERE tq.test_id = $1",
     [test_id]
  ).to_a

  erb :english_test
end

# admin_create_testで作成したテストの回答を送信する処理
post '/english_test/:id/submit' do
  test_id = params[:id]
  user_id = session[:user_id]
  user_answers = params["answers"]
  @correct_count = 0

  if user_answers
    user_answers.each do |_index, data|
      question_id = data["id"].to_i
      chosen_option = data["chosen"].to_i

      question = client.exec_params(
        "SELECT correct_option FROM english_questions WHERE id = $1", 
        [question_id]
      ).first

      is_correct = false
      if question && question["correct_option"].to_i == chosen_option
        is_correct = true
        @correct_count += 1
      end

      client.exec_params(
        "INSERT INTO answer_logs (user_id, question_id, selected_option, is_correct, answered_at, test_id) 
         VALUES ($1, $2, $3, $4, NOW(), $5)",
        [user_id, question_id, chosen_option, is_correct, test_id]
      )
    end
  end

  session[:test_id] = test_id # 結果画面でどのテストの結果かを識別するためにセッションに保存
  redirect '/quiz_result'
end


# 問題ごとの正答率を表示する画面（正答率の降順）
get '/question_stats' do
  # 管理者かどうかのチェック
  current_user = client.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  # 【修正】SQL側で正答率（accuracy_rate）を計算し、降順（DESC）で並び替える
  @question_stats = client.exec_params("
    SELECT 
      q.id, 
      q.category, 
      q.question_text, 
      q.option_1, 
      q.option_2, 
      q.option_3, 
      q.option_4,
      q.correct_option,
      COUNT(al.id) AS total_answers, 
      SUM(CASE WHEN al.is_correct THEN 1 ELSE 0 END) AS correct_answers,
      
      -- 💡 ゼロ除算対策：回答数が0なら0、それ以外なら正答率(%)を計算
      CASE 
        WHEN COUNT(al.id) = 0 THEN 0
        ELSE ROUND((SUM(CASE WHEN al.is_correct THEN 1 ELSE 0 END)::numeric / COUNT(al.id)) * 100, 1)
      END AS accuracy_rate

    FROM english_questions q
    LEFT JOIN answer_logs al ON q.id = al.question_id
    GROUP BY q.id
    
    -- 💡 正答率の降順（大きい順）、同じ正答率ならカテゴリ・ID順
    ORDER BY accuracy_rate DESC, q.category ASC, q.id ASC
  ").to_a

  erb :question_stats
end

# 問題の単元（category）ごとの正答率を表示する画面（正答率の降順）
get '/question_stats_by_category' do
  # 管理者かどうかのチェック
  current_user = client.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  # 【修正】SQL側で正答率（accuracy_rate）を計算し、降順（DESC）で並び替える
  @question_stats = client.exec_params("
    SELECT 
      q.id, 
      q.category, 
      q.question_text, 
      q.option_1, 
      q.option_2, 
      q.option_3, 
      q.option_4,
      q.correct_option,
      COUNT(al.id) AS total_answers, 
      SUM(CASE WHEN al.is_correct THEN 1 ELSE 0 END) AS correct_answers,
      
      -- 💡 ゼロ除算対策：回答数が0なら0、それ以外なら正答率(%)を計算
      CASE 
        WHEN COUNT(al.id) = 0 THEN 0
        ELSE ROUND((SUM(CASE WHEN al.is_correct THEN 1 ELSE 0 END)::numeric / COUNT(al.id)) * 100, 1)
      END AS accuracy_rate

    FROM english_questions q
    LEFT JOIN answer_logs al ON q.id = al.question_id
    GROUP BY q.id
    
    -- 💡 正答率の降順（大きい順）、同じ正答率ならカテゴリ・ID順
    ORDER BY q.category ASC, accuracy_rate DESC, q.id ASC
  ").to_a

  erb :question_stats_by_category
end