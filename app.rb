  require 'dotenv'
Dotenv.load
require 'sinatra'
require 'pg'
require 'bcrypt'
require 'pony'
require 'securerandom'
require 'sinatra/cookies'
require 'json' # JSONを扱うために必要
require 'rack/cors' # 読み込みを忘れない
require 'open-uri'
require 'nokogiri'
require 'cgi'
require 'selenium-webdriver'
require 'fileutils'
require 'cloudinary'
require 'rtesseract'
require 'google-cloud-vision'
require 'openai'
require 'connection_pool'


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

# --- 1. データベース接続設定 (コネクションプール化) ---
DB_POOL = ConnectionPool.new(size: 5, timeout: 5) do
  db_url = ENV['DATABASE_URL']
  if db_url
    # Render環境（SSLモードを有効にして接続）
    PG.connect("#{db_url}?sslmode=require")
  else
    # ローカル環境（自分のMac）
    PG.connect(host: "localhost", dbname: "campus_db_34pr")
  end
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

before do
  if session[:user_id]
    result = DB_POOL.with do | conn |
    conn.exec_params(
      "SELECT avatar FROM users WHERE id = $1 LIMIT 1",
      [session[:user_id]]
    )
    end
    @current_user = result.first
  end
end

# ヘルパー一覧
helpers do
  # 安全にHTMLをエスケープするためのヘルパー
  def html_escape(text)
    Rack::Utils.escape_html(text)
  end

  # アプリ内で使い回せるメール送信ヘルパー
  def send_app_email(to_email, subject, body_text)
    smtp_user     = ENV['SMTP_USER']    
    smtp_password = ENV['SMTP_PASSWORD'] 
    Pony.mail({
      to:      to_email,
      from:    ENV['SMTP_USER'],     # パスワードリセットと同じ環境変数
      subject: subject,
      body:    body_text,
      via: :smtp,
      via_options: {
        address:              'smtp.gmail.com',
        port:                 '587',
        enable_starttls_auto: true,
        user_name:            smtp_user,
        password:             smtp_password,
        authentication:       :plain,
        domain:               "localhost.localdomain"
      }
    })
  rescue => e
    # エラーハンドリングも共通化して、ログに残るようにする
    puts "=== [警告] メール送信エラーが発生しました ==="
    puts "宛先: #{to_email}"
    puts "エラー内容: #{e.message}"
    puts "==========================================="
    # 呼び出し元（ルーティング側）でエラーを検知したい場合のために、あえてエラーを再発生させる
    raise e 
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

    # 4. 各問題の結果を1つずつ保存（INSERT）
    DB_POOL.with do | conn |

      results.each do |res|
        conn.exec_params(
        "INSERT INTO quiz_results (user_id, question_text, user_answer, is_correct) VALUES ($1, $2, $3, $4)",
        [
          user_id,
          res['questionText'], # React側のプロパティ名に合わせる
          res['userAnswer'],
          res['isCorrect']
        ]
        )
      end
    end

    # 5. 成功したことをReactに伝える
    status 200
    { message: "保存が完了しました" }.to_json

  rescue => e
    # エラーが起きた場合
    status 500
    { error: e.message }.to_json
  end
end

# 分割したルーティングファイルの読み込み
require_relative 'routes/essays'

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

  @result = DB_POOL.with do |conn|
    conn.exec_params("SELECT email FROM users WHERE email = $1", [params[:email]])
  end
  if @result.first
    @error = "そのメールアドレスは既に使用されています"
    @result.clear # 使い終わったらクリア
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



  @result = DB_POOL.with do |conn|
    conn.exec_params(
    "INSERT INTO users (name_kana, name, email, password, school, grade) VALUES ($1, $2, $3, $4, $5, $6)",
    [@name_kana, @name, @email, @password, @school, @grade]
    )
  end
  

  redirect "/login"
end

get '/login' do
  erb :login
end

post "/login" do
  email = params[:email]
  password = params[:password]

  result = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE email = $1", [email])
  end
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

  user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless user
  redirect '/' unless user["is_admin"].to_s == 't'

  #学年ごとに生徒の名前を50音順で表示するためのSQLクエリを作成
  users_list = DB_POOL.with do | conn |
    conn.exec_params("SELECT id, name, name_kana, grade, campus, avatar FROM users ORDER BY grade ASC, name_kana ASC").to_a
  end
  @users_by_campus = users_list.group_by { |user| user['campus'] }

  erb :users_info
end

get '/member_search' do
    redirect '/login' unless session[:user_id]

  user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless user
  redirect '/' unless user["is_admin"].to_s == 't'

  query = params[:query]
  @members = []

  if query && !query.strip.empty?
    # 検索ワードがある場合：プレースホルダ（$1）を使ってSQLインジェクションを防ぐ
    # カタカナや漢字、メールアドレスの部分一致に対応するため LIKE を使用
    @members = DB_POOL.with do | conn |
      conn.exec_params(
      "SELECT * FROM users WHERE name LIKE $1 OR name_kana LIKE $1 OR school LIKE $1 OR email LIKE $1 ORDER BY id DESC", 
      ["%#{query}%"]
    )
    end
  end

  #学年ごとに生徒の名前を50音順で表示するためのSQLクエリを作成
  users_list = DB_POOL.with do | conn |
    conn.exec_params("SELECT id, name, name_kana, grade, campus, avatar FROM users ORDER BY grade ASC, name_kana ASC").to_a
  end
  @users_by_campus = users_list.group_by { |user| user['campus'] }

  erb :users_info
  
end

# 個別ユーザーの詳細表示
get '/users_info/:id' do
  redirect '/login' unless session[:user_id]
  user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless user
  redirect '/' unless user["is_admin"].to_s == 't'
    
  target_id = params[:id]

  # 特定のユーザー1人分だけをJOINで取得
  raw_data = DB_POOL.with do | conn |
    conn.exec_params("
    SELECT users.*, 
           plans.subject AS p_subject, plans.material AS p_material, plans.status AS p_status, plans.start_date AS p_start_date, plans.end_date AS p_end_date,
           diary_entries.content AS d_content, diary_entries.date AS d_date,
           consults.content AS c_content, consults.date AS c_date,
           instructions.content AS i_content, instructions.created_at AS i_created_at, instructions.category AS i_category,
           instruction_replies.content AS ir_content, instruction_replies.created_at AS ir_created_at, instruction_replies.user_id AS ir_user_id,
          mock_exams.title AS me_title, mock_exams.exam_type AS me_exam_type, mock_exams.english_r AS me_english_r, mock_exams.english_l AS me_english_l, 
          mock_exams.math_1a AS me_math_1a, mock_exams.math_2bc AS me_math_2bc, mock_exams.japanese AS me_japanese, mock_exams.physics_basic AS me_physics_basic, 
          mock_exams.chemistry_basic AS me_chemistry_basic, mock_exams.biology_basic AS me_biology_basic, mock_exams.earth_science_basic AS me_earth_science_basic, 
          mock_exams.physics AS me_physics, mock_exams.chemistry AS me_chemistry, mock_exams.biology AS me_biology, mock_exams.earth_science AS me_earth_science, 
          mock_exams.world_history AS me_world_history, mock_exams.japanese_history AS me_japanese_history, mock_exams.geography AS me_geography, mock_exams.civics_ethics AS me_civics_ethics, 
          mock_exams.civics_politics AS me_civics_politics, mock_exams.geography_basic AS me_geography_basic, mock_exams.history_basic AS me_history_basic, 
          mock_exams.civics_basic AS me_civics_basic, mock_exams.informatics AS me_informatics, mock_exams.taken_at AS me_taken_at, mock_exams.mock_exam_result_image_url AS me_mock_exam_result_image_url
    FROM users 
    LEFT JOIN plans ON users.id = plans.user_id 
    LEFT JOIN diary_entries ON users.id = diary_entries.user_id 
    LEFT JOIN consults ON users.id = consults.user_id
    LEFT JOIN instructions ON users.id = instructions.user_id OR instructions.user_id IS NULL
    LEFT JOIN instruction_replies ON instructions.id = instruction_replies.instruction_id
    LEFT JOIN mock_exams ON users.id = mock_exams.user_id
    WHERE users.id = $1
  ", [target_id]).to_a
  end

  halt 404 if raw_data.empty?

  # 1人分のデータを整理（前のロジックを活用）
  user_data = raw_data.first.merge({ 'plans' => [], 'diaries' => [], 'consults' => [], 'instructions' => [], 'mock_exams' => [] })
  
  raw_data.each do |row|
    user_data['plans'] << { 'subject' => row['p_subject'], 'material' => row['p_material'], 'status' => row['p_status'], 'start_date' => row['p_start_date'], 'end_date' => row['p_end_date'] }
    user_data['diaries'] << { 'content' => row['d_content'], 'date' => row['d_date'] } if row['d_content']
    user_data['consults'] << { 'content' => row['c_content'], 'date' => row['c_date'] } if row['c_content']
    user_data['instructions'] << { 'content' => row['i_content'], 'category' => row['i_category'], 'created_at' => row['i_created_at'], 'reply_content' => row['ir_content'], 'reply_created_at' => row['ir_created_at'], 'ir_user_id' => row['ir_user_id'] } if row['i_content']
    user_data['mock_exams'] << { 'title' => row['me_title'], 'exam_type' => row['me_exam_type'], 'english_r' => row['me_english_r'], 'english_l' => row['me_english_l'], 'math_1a' => row['me_math_1a'], 'math_2bc' => row['me_math_2bc'], 
    'japanese' => row['me_japanese'], 'physics_basic' => row['me_physics_basic'], 'chemistry_basic' => row['me_chemistry_basic'], 'biology_basic' => row['me_biology_basic'], 'earth_science_basic' => row['me_earth_science_basic'], 'physics' => row['me_physics'], 
    'chemistry' => row['me_chemistry'], 'biology' => row['me_biology'], 'earth_science' => row['me_earth_science'], 'world_history' => row['me_world_history'], 'japanese_history' => row['me_japanese_history'], 'geography' => row['me_geography'], 'civics_ethics' => row['me_civics_ethics'], 
    'civics_politics' => row['me_civics_politics'], 'geography_basic' => row['me_geography_basic'], 'history_basic' => row['me_history_basic'], 'civics_basic' => row['me_civics_basic'], 'informatics' => row['me_informatics'], 'taken_at' => row['me_taken_at'], 'mock_exam_result_image_url' => row['me_mock_exam_result_image_url']}
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

  result = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT * FROM users WHERE id=$1",
    [user_id]
    )  
  end
  

  @user = result[0]

# ここで @is_admin に真偽値を振っておくと、erbで使いやすくなる
  @is_admin = (@user['is_admin'] == 't' || @user['is_admin'] == true)
  session[:is_admin] = @is_admin

  # 講師からのお知らせを新着順に取得
  @teacher_announcements = DB_POOL.with do | conn |
    conn.exec_params(
      "SELECT * FROM teacher_announcements ORDER BY created_at DESC LIMIT 5"
    ).to_a
  end

  # 万が一 nil が入っても大丈夫なように安全策をとる場合は以下のように書くこともできる
  @teacher_announcements ||= []

  erb :mypage
end

post "/mypage/teacher_announcement/:id/delete" do
  # 💡 ログインチェック & 管理者権限チェック（権限がない場合は拒否）
  unless session[:user_id] && session[:is_admin] # ※管理者フラグのセッション名に合わせて変更してください
    halt 403, "権限がありません"
  end

  teacher_announcement_id = params[:id]
  DB_POOL.with do | conn |
    conn.exec_params(
      "DELETE FROM teacher_announcements WHERE id = $1", [teacher_announcement_id]
    )
  end

  redirect '/mypage'
end

get "/mypage_edit" do
  user_id = session[:user_id]

  result = DB_POOL.with do | conn |
    conn.exec_params(
      "SELECT * FROM users WHERE id=$1",
      [user_id]
    )
  end

  @user = result[0]

  erb :mypage_edit
end


post '/mypage_edit' do
  user_id = session[:user_id]
  @name_kana = params[:name_kana]
  @name = params[:name]
  @email = params[:email]
  
current_user = DB_POOL.with do | conn |
  conn.exec_params(
    "SELECT * FROM users WHERE id=$1",
    [user_id]
  ).first
end
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

  # 💡 サーバー側での厳重チェック（空っぽ、または選択肢にない不正な文字列の場合）
  # ※許可するキャンパス名は、DBの制約に合わせて書き換える
  allowed_campuses = ["おもろまち", "泉崎", "首里", "沖縄"]

  if @campus.nil? || !allowed_campuses.include?(@campus.strip)
    # ❌ 不正なデータなので、エラーメッセージを持って登録画面に戻す
    session[:error] = "正しいキャンパスを選択してください。"
    redirect '/mypage_edit'
    # ここで処理を終了させることで、下の DB保存(exec_params) に進ませない！
  end

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

  # パラメータやDBから現在のユーザー情報を取得している前提
  current_avatar = current_user['avatar']

  # ユーザーのavatar画像のアップロード処理
  avatar_file = params[:avatar]

  # --- 1. 画像の保存処理 (Cloudinary対応版) ---
  if avatar_file
    tempfile = avatar_file[:tempfile]

    # 💡 ローカルへの保存処理の代わりに、Cloudinaryに直接アップロード
    # RenderのEnvironmentに登録した鍵を使って自動的に通信してくれる
    response = Cloudinary::Uploader.upload(tempfile.path)
    
    # 💡 データベース（avatarカラム）には、Cloudinary側で生成された「画像のURL」をそのまま保存する
    # これにより、下のSQL処理（unique_filenameの箇所）を変更せずにそのまま動かせる
    unique_filename = response['secure_url']
  else
    # 新しい画像が送られてこなかった場合は、既存の値を維持する処理、
    # あるいは現在のコードの仕様通り、変更なし（または既存のURLをそのまま渡す）に調整して
    # （※もし「画像を変更しない時」にDBの値が消えてしまう場合は、params等から既存の値を引き継ぐ必要がある）
    unique_filename = current_avatar
  end

  DB_POOL.with do | conn |
    conn.exec_params(
      "UPDATE users SET name_kana=$1, name=$2, email=$3, password=$4, campus=$5, school=$6, grade=$7, desired_school=$8, faculty=$9, department=$10, second_desired_school=$11, second_desired_faculty=$12, second_desired_department=$13, third_desired_school=$14, third_desired_faculty=$15, third_desired_department=$16, target_ct_reading=$17, target_ct_listening=$18, last_ct_reading=$19, last_ct_listening=$20, eiken_level=$21, desired_eiken_level=$22, strong_subject=$23, weak_subject=$24, hobby=$25, club=$26, desired_job=$27, dream=$28, resolution=$29, consult=$30, worry=$31, recommend_exam=$32, request_for_class=$33, avatar=$34 WHERE id=$35",
      [@name_kana, @name, @email, @password, @campus, @school, @grade, @desired_school, @faculty, @department, @second_desired_school, @second_desired_faculty, @second_desired_department, @third_desired_school, @third_desired_faculty, @third_desired_department, @target_ct_reading, @target_ct_listening, @last_ct_reading, @last_ct_listening, @eiken_level, @desired_eiken_level, @strong_subject, @weak_subject, @hobby, @club, @desired_job, @dream, @resolution, @consult, @worry, @recommend_exam, @request_for_class, unique_filename, user_id]
    )
  end

  redirect '/mypage'
end


# チャットルーム関係
get '/chat_rooms/new' do
  # 他のユーザー一覧を取得（自分以外）
  #current_user_id = session[:user_id]
  @users = DB_POOL.with do | conn |
    conn.exec_params(
      "SELECT id, name FROM users WHERE name = $1",
      ["須田丈夫"]
    ).to_a
  end

  erb :new_chat_room
end

post '/chat_rooms' do
  current_user_id = session[:user_id]
  other_user_id = params[:user_id].to_i  # フォームから送られてくる相手ID

  # 新しいチャットルームを作成（個別チャットは名前なし）
  result = DB_POOL.with do | conn |
    conn.exec_params(
      "INSERT INTO chat_rooms (name) VALUES ($1) RETURNING id",
      [nil]
    )
    chat_room_id = result[0]["id"]
  end

  # 参加者を登録（自分と相手）
  DB_POOL.with do | conn |
    [current_user_id, other_user_id].each do |uid|
      conn.exec_params(
        "INSERT INTO chat_room_users (chat_room_id, user_id) VALUES ($1, $2)",
        [chat_room_id, uid]
      )
    end
  end

  redirect "/chat_rooms/#{chat_room_id}"
end



get '/chat_rooms' do
  user_id = session[:user_id]
  
  # 自分が参加しているルームを取得
  @chat_rooms = DB_POOL.with do | conn |
    conn.exec_params(
      "SELECT cr.* FROM chat_rooms cr
      JOIN chat_room_users cru ON cr.id = cru.chat_room_id
      WHERE cru.user_id=$1",
      [user_id]
    ).to_a
  end

  erb :chat_rooms
end


get '/chat_rooms/:id' do
  chat_room_id = params[:id]
  
  # ルーム情報
  @chat_room = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM chat_rooms WHERE id=$1", [chat_room_id])[0]
  end
  
  # メッセージ一覧
  @messages = DB_POOL.with do | conn |
    conn.exec_params(
      "SELECT m.*, u.name FROM messages m
      JOIN users u ON m.sender_id = u.id
      WHERE chat_room_id=$1
      ORDER BY created_at ASC",
      [chat_room_id]
    ).to_a
  end

  erb :chat_room
end


post '/chat_rooms/:id/messages' do
  chat_room_id = params[:id]
  sender_id = session[:user_id]
  content = params[:content]

  DB_POOL.with do | conn |
    conn.exec_params(
      "INSERT INTO messages (chat_room_id, sender_id, content) VALUES ($1, $2, $3)",
      [chat_room_id, sender_id, content]
    )
  end

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
  
  DB_POOL.with do | conn |
    conn.exec_params(
      "INSERT INTO plans (user_id, subject, material, start_date, end_date, laps, completed_laps, purpose, status) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
      [@user_id, @subject, @material, @start_date, @end_date, @laps, @completed_laps, @purpose, @status]
    )
  end

  redirect '/plans'
end

get '/plans' do
  @user_id = session[:user_id]
  @plans = DB_POOL.with do | conn |
    conn.exec_params(
      "SELECT * FROM plans
        WHERE user_id = $1
        ORDER BY created_at ASC",
      [@user_id]
    ).to_a
  end

  erb :plans
end

get '/plans/:id/edit' do
  @plan_id = params[:id].to_i
  @plan = DB_POOL.with do | conn |
    conn.exec_params(
      "SELECT * FROM plans WHERE id=$1",
      [@plan_id]
    ).first
  end

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

  DB_POOL.with do | conn |
    conn.exec_params(
      "UPDATE plans SET subject=$1, material=$2, start_date=$3, end_date=$4, laps=$5, completed_laps=$6, purpose=$7, status=$8 WHERE id=$9",
      [@subject, @material, @start_date, @end_date, @laps, @completed_laps, @purpose, @status, @plan_id]
    )
  end

  redirect '/plans'
end

#面談記録関係

get '/consults' do
  @user_id = session[:user_id]
  @consults = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT * FROM consults
      WHERE user_id = $1
      ORDER BY date DESC",
    [@user_id]
  ).to_a
  end
  erb :consults
end

post '/consults/new' do
  @user_id = session[:user_id]
  @content = params[:content]
  @date = params[:date]
  
  DB_POOL.with do | conn |
    conn.exec_params(
    "INSERT INTO consults (user_id, content, date) VALUES ($1, $2, $3)",
    [@user_id, @content, @date]
  )
  end

  redirect '/consults'
end

#勉強日記関係
get '/diary' do
  @user_id = session[:user_id]
  @diary_entries = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT * FROM diary_entries
      WHERE user_id = $1
      ORDER BY date DESC",
    [@user_id]
  ).to_a
  end

  erb :diary
end

post '/diary/new' do
  @user_id = session[:user_id]
  @content = params[:content]
  @date = params[:date]

  DB_POOL.with do | conn |
    conn.exec_params(
    "INSERT INTO diary_entries (user_id, content, date) VALUES ($1, $2, $3)",
    [@user_id, @content, @date]
  )
  end

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

 DB_POOL.with do | conn |
    conn.exec_params(
   "INSERT INTO english_levels (user_id, word_level, grammar_level, reading_level) VALUES ($1, $2, $3, $4)",
   [@user_id, @w_lv, @g_lv, @r_lv]
 )
 end

@current_user = DB_POOL.with do | conn |
    conn.exec_params(
  "SELECT * FROM users WHERE id=$1",
  [@user_id]
).first
end
halt 404 unless @current_user

@recommended_books = DB_POOL.with do | conn |
    conn.exec_params( "SELECT * FROM english_books 
WHERE (category = 'word' AND level = $1) 
OR (category = 'grammar' AND level = $2) 
OR (category = 'reading' AND level = $3) 
ORDER BY category ASC, level DESC", 
[@w_lv, @g_lv, @r_lv] ).to_a
end

erb :recommends_results 
end

# 英語参考書の良書一覧
get '/recommends_list' do
  @user_id = session[:user_id]
  @recommendations = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT * FROM english_books eb"
  ).to_a
  end

  erb :recommends_list
end

# パスワードの再設定
get '/password_reset' do
  erb :password_reset
end

post '/password_reset' do
  email = params[:email]
  user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE email = $1", [email]).first
  end

  if user
    # 1. 使い捨てのランダムな「鍵（トークン）」を作る
    reset_token = SecureRandom.hex(32)
    # 2. データベースにトークンと有効期限（例: 1時間後）を保存する
    DB_POOL.with do | conn |
      conn.exec_params(
        "UPDATE users SET reset_token = $1, reset_token_expires_at = NOW() + INTERVAL '1 hour' WHERE id = $2",
        [reset_token, user['id']]
      )
    end

    # 3. ここでメールを送信する
    # パスワードリセット用リンクを含むメール
    # 環境変数 APP_URL があればそれを使い、なければローカル用を使う
    base_url = ENV['APP_URL'] || "http://localhost:10000"
    url = "#{base_url}/password_reset/edit?token=#{reset_token}"

    begin
      # 💡 共通化したヘルパーを呼び出すだけ！
      send_app_email(user['email'], "【CampusCore】パスワード再設定", "以下のURLをクリックして、1時間以内に再設定を完了してください。\n\n#{url}")
      
      @message = "ご登録のメールアドレスに再設定用のリンクを送信しました。メールボックスをご確認ください。"
    rescue => e
      @error = "メール送信に失敗しました: #{e.message}"
    end
  else
    @error = "そのメールアドレスは登録されていません。メールアドレスが正しいか確認してください。"
  end
  erb :password_reset
end

get '/password_reset/edit' do
  @token = params[:token]
  
  # DBからトークンが一致し、かつ期限（1時間）が切れていないユーザーを探す
  user = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT * FROM users WHERE reset_token = $1 AND reset_token_expires_at > NOW()",
    [@token]
    ).first
  end

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
  
  result = DB_POOL.with do | conn |
    conn.exec_params(
    "UPDATE users SET password = $1, reset_token = NULL, reset_token_expires_at = NULL 
     WHERE reset_token = $2 AND reset_token_expires_at > NOW() RETURNING id",
    [hashed_password, token]
    )
  end

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
  raw_data = DB_POOL.with do | conn |
    conn.exec_params("
    SELECT instructions.*, reads.read_at, reads.id AS read_record_id, instruction_replies.content AS ir_content, instruction_replies.created_at AS ir_created_at
    FROM instructions
    LEFT JOIN reads ON instructions.id = reads.instruction_id AND reads.user_id = $1
    LEFT JOIN instruction_replies ON instructions.id = instruction_replies.instruction_id
    WHERE instructions.user_id = $1 OR instructions.user_id IS NULL
    ORDER BY instructions.created_at DESC",
    [user_id]
    ).to_a
  end
  
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
  DB_POOL.with do | conn |
    conn.exec_params(
    "INSERT INTO reads (instruction_id, user_id) VALUES ($1, $2)",
    [instruction_id, @user_id]
    )
  end
  
  redirect '/instructions'
end

get '/instructions/new' do
  @users = DB_POOL.with do | conn |
    conn.exec_params("SELECT id, name FROM users ORDER BY name ASC").to_a
  end
  erb :make_instructions
end

post '/instructions/new' do
  user_id = params[:user_id]
  # 全員向け（NULL）の場合は、空文字ではなくnilにする処理
  target_user_id = (user_id == "" || user_id.nil?) ? nil : user_id

DB_POOL.with do | conn |
    conn.exec_params(
    "INSERT INTO instructions (content, category, user_id, created_at, updated_at) 
     VALUES ($1, $2, $3, NOW(), NOW())",
    [params[:content], params[:category], target_user_id]
  )
end

receiver = DB_POOL.with do | conn |
    conn.exec_params("SELECT email, name FROM users WHERE id = $1", [target_user_id]).first
end
  
  if receiver && receiver['email']
    subject = "【CampusCore】新着メッセージが届きました"
    body    = "#{receiver['name']} 様\n\n新着メッセージが届いています。【CampusCore】にログインして確認してください。"
    
    begin
      # 💡 同じヘルパーを使い回せる！
      send_app_email(receiver['email'], subject, body)
    rescue => e
      # 通知エラーが起きても、メッセージの投稿自体は成功しているので、
      # ログに出力するだけで処理を進める
      puts "通知メールの送信に失敗しました（処理は継続します）"
    end
  end

  redirect '/instructions'
end

post '/instructions/:id/reply' do
  instruction_id = params[:id]
  user_id = session[:user_id]
  content = params[:content]

  DB_POOL.with do | conn |
    conn.exec_params(
    "INSERT INTO instruction_replies (instruction_id, user_id, content, created_at) VALUES ($1, $2, $3, NOW())",
    [instruction_id, user_id, content]
  )
  end

  receiver = DB_POOL.with do | conn |
    conn.exec_params("SELECT email, name FROM users WHERE is_admin = $1", [true]).first
  end

  reply_sender = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT name 
    FROM users u
    JOIN instruction_replies ir ON u.id = ir.user_id
    WHERE ir.instruction_id = $1",
    [instruction_id]).first
  end
  
  if receiver && receiver['email']
    subject = "【CampusCore】#{reply_sender['name']}様への学習アドバイスに対する返信が届きました"
    body    = "#{receiver['name']} 様\n\n#{reply_sender['name']}様への学習アドバイスに対する返信が届いています。【CampusCore】にログインして確認してください。"
    
    begin
      # 💡 同じヘルパーを使い回せる！
      send_app_email(receiver['email'], subject, body)
    rescue => e
      # 通知エラーが起きても、メッセージの投稿自体は成功しているので、
      # ログに出力するだけで処理を進める
      puts "通知メールの送信に失敗しました（処理は継続します）"
    end
  end

  redirect "/instructions"
end

# 模試結果入力関係

get '/mock_exams' do

  user_id = session[:user_id]
  @mock_exams = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT * FROM mock_exams WHERE user_id = $1 ORDER BY taken_at DESC",
    [user_id]
  ).to_a
  end
  @success_message = session[:flash]
  session[:flash] = nil

  erb :mock_exams
end

post '/mock_exams/new' do
  title = params[:title]
  exam_type = params[:exam_type]
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

  # 模試結果PDFと画像のアップロード処理
  mock_exam_result_image_file = params[:mock_exam_result_image]

  # --- 1. PDFと画像の保存処理 (Cloudinary対応版) ---
  if mock_exam_result_image_file
    tempfile = mock_exam_result_image_file[:tempfile]

    # 💡 ローカルへの保存処理の代わりに、Cloudinaryに直接アップロード
    # RenderのEnvironmentに登録した鍵を使って自動的に通信してくれる
    response = Cloudinary::Uploader.upload(
      tempfile.path,
      resource_type: "image" 
      )
    
    # 💡 データベース（avatarカラム）には、Cloudinary側で生成された「PDFと画像のURL」をそのまま保存する
    # これにより、下のSQL処理（unique_filenameの箇所）を変更せずにそのまま動かせる
    unique_filename = response['secure_url']
  else
    # 新しい画像が送られてこなかった場合は、既存の値を維持する処理、
    # あるいは現在のコードの仕様通り、変更なし（または既存のURLをそのまま渡す）に調整して
    # （※もし「画像を変更しない時」にDBの値が消えてしまう場合は、params等から既存の値を引き継ぐ必要がある）
    unique_filename = nil 
  end


  DB_POOL.with do | conn |
    conn.exec_params(
    "INSERT INTO mock_exams (title, exam_type, user_id, english_r, english_l, math_1a, math_2bc, japanese, physics_basic, chemistry_basic, biology_basic, earth_science_basic, physics, chemistry, biology, earth_science, world_history, japanese_history, geography, civics_ethics, civics_politics, geography_basic, history_basic, civics_basic, informatics, taken_at, mock_exam_result_image_url) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25, $26, $27)",
    [title, exam_type, user_id, english_r, english_l, math_1a, math_2bc, japanese, physics_basic, chemistry_basic, biology_basic, earth_science_basic, physics, chemistry, biology, earth_science, world_history, japanese_history, geography, civics_ethics, civics_politics, geography_basic, history_basic, civics_basic, informatics, taken_at, unique_filename]
  )
  end
  redirect '/mock_exams'
end

# 模試結果を削除する
post "/mock_exams/:id/delete" do
  exam_id = params[:id]
  DB_POOL.with do | conn |
    conn.exec_params("DELETE FROM mock_exams WHERE id = $1", [exam_id])
  end
  redirect '/mock_exams'
end

# 模試結果を編集する
get '/mock_exams/:id/edit' do
  exam_id = params[:id]
  @mock_exam = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM mock_exams WHERE id = $1", [exam_id]).first
  end
  erb :mock_exams_edit
end

post '/mock_exams/:id/edit' do
  title = params[:title]
  exam_type = params[:exam_type]
  exam_id = params[:id]
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

  # 模試結果画像のアップロード処理
  mock_exam_result_image_file = params[:mock_exam_result_image]

  # --- 1. 画像の保存処理 (Cloudinary対応版) ---
  if mock_exam_result_image_file
    tempfile = mock_exam_result_image_file[:tempfile]

    # 💡 ローカルへの保存処理の代わりに、Cloudinaryに直接アップロード
    # RenderのEnvironmentに登録した鍵を使って自動的に通信してくれる
    response = Cloudinary::Uploader.upload(tempfile.path)
    
    # 💡 データベース（avatarカラム）には、Cloudinary側で生成された「画像のURL」をそのまま保存する
    # これにより、下のSQL処理（unique_filenameの箇所）を変更せずにそのまま動かせる
    unique_filename = response['secure_url']
  else
    # 新しい画像が送られてこなかった場合は、既存の値を維持する処理、
    # あるいは現在のコードの仕様通り、変更なし（または既存のURLをそのまま渡す）に調整して
    # （※もし「画像を変更しない時」にDBの値が消えてしまう場合は、params等から既存の値を引き継ぐ必要がある）
    unique_filename = nil 
  end

  DB_POOL.with do | conn |
    conn.exec_params(
    "UPDATE mock_exams SET title=$1, exam_type=$2, english_r=$3, english_l=$4, math_1a=$5, math_2bc=$6, japanese=$7, physics_basic=$8, chemistry_basic=$9, biology_basic=$10, earth_science_basic=$11, physics=$12, chemistry=$13, biology=$14, earth_science=$15, world_history=$16, japanese_history=$17, geography=$18, civics_ethics=$19, civics_politics=$20, geography_basic=$21, history_basic=$22, civics_basic=$23, informatics=$24, taken_at=$25, mock_exam_result_image_url=$26 WHERE id=$27 AND user_id=$28",
    [title, exam_type, english_r, english_l, math_1a, math_2bc, japanese, physics_basic, chemistry_basic, biology_basic, earth_science_basic, physics, chemistry, biology, earth_science, world_history, japanese_history, geography, civics_ethics, civics_politics, geography_basic, history_basic, civics_basic, informatics, taken_at, unique_filename, exam_id, user_id]
  )
  end
  session[:flash] = "模試・入試結果を更新しました。"

  redirect '/mock_exams'
end

# オンライン試験関係
get '/quiz_select' do
  erb :quiz_select
end

get '/quiz/:category' do
  user_id = session[:user_id]
  @quiz = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT * FROM english_questions WHERE category = $1 ORDER BY id ASC LIMIT 20 OFFSET 46",
    [params[:category]]
  ).to_a
  end

  erb :quiz
end

post '/quiz/submit' do
  user_id = session[:user_id]
  user_answers = params["answers"]
  session[:correct_count] = 0  # 正解数を数えるカウンター
  session[:total_count] = 0 # 合計回答数を数えるカウンター

  current_time = Time.now

  if user_answers
    user_answers.each do |_index, data|
      question_id = data["id"].to_i
      chosen_option = data["chosen"].to_i
      session[:total_count] += 1

      # 1. データベースから、その問題の正解を取得する
      question = DB_POOL.with do | conn |
        conn.exec_params(
        "SELECT correct_option FROM english_questions WHERE id = $1", 
        [question_id]
        ).first
      end

      # 2. ユーザーの回答と正解が一致しているか判定し、true か false を決める
      is_correct = false
      if question && question["correct_option"].to_i == chosen_option
        is_correct = true
        session[:correct_count] += 1  # 正解だったらカウントを増やす
      end

      # 3. 「誰が」「どの問題に」「何と答え」「正解したか」を1回でインサートする
      DB_POOL.with do | conn |
        conn.exec_params(
        "INSERT INTO answer_logs (user_id, question_id, selected_option, is_correct, answered_at) 
         VALUES ($1, $2, $3, $4, $5)",
        [user_id, question_id, chosen_option, is_correct, current_time]
        )
      end
    end
  end

  redirect '/quiz_result'
end

get '/quiz_result' do
  user_id = session[:user_id]
  test_id = session[:test_id] # もしテストIDを渡す場合はここで受け取る
  @correct_count = session[:correct_count].to_i
  @total_count = session[:total_count].to_i
  @test_name = session[:test_name]
  @wrong_count = @total_count - @correct_count

  # 💡 対策: このテストで、このユーザーが「最後に回答した日時」を1件特定する
  # これによって、過去の同じテストの回答ログが混ざるのを防ぎます
  last_attempt = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT date_trunc('second', answered_at) AS last_sec FROM answer_logs 
     WHERE user_id = $1 AND test_id = $2 
     ORDER BY answered_at DESC LIMIT 1",
    [user_id, test_id]
    ).first
  end

  if last_attempt
    # 最新の受験日時をセット（ミリ秒のズレを防ぐため、安全に文字列やそのまま利用）
    last_time_sec = last_attempt["last_sec"]
  end

  @correct_answers = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT q.id, q.question_text, q.option_1, q.option_2, q.option_3, q.option_4, q.correct_option, al.selected_option, al.answered_at 
     FROM answer_logs al
     JOIN english_questions q ON al.question_id = q.id
     WHERE al.user_id = $1 AND al.is_correct = true AND al.test_id = $2 
      AND date_trunc('second', al.answered_at) = date_trunc('second', $3::timestamp)
     ORDER BY al.answered_at DESC
    LIMIT $4",
    [user_id, test_id, last_time_sec, @correct_count]
    ).to_a
  end

  @wrong_answers = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT q.id, q.question_text, q.option_1, q.option_2, q.option_3, q.option_4, q.correct_option, al.selected_option, al.answered_at 
     FROM answer_logs al
     JOIN english_questions q ON al.question_id = q.id
     WHERE al.user_id = $1 AND al.is_correct = false AND al.test_id = $2 
      AND date_trunc('second', al.answered_at) = date_trunc('second', $3::timestamp)
     ORDER BY al.answered_at DESC
     LIMIT $4",
    [user_id, test_id, last_time_sec, @wrong_count]
    ).to_a
  end
  
  @accuracy_rate = @total_count > 0 ? (@correct_count.to_f / @total_count * 100).round(2) : 0

  # 💡 使い終わったセッションは消去（リロード対策）
  session[:test_id] = nil
  session[:test_name] = nil
  session[:correct_count] = nil
  session[:total_count] = nil

  erb :quiz_result
end

# 各ユーザーが自分の試験結果を閲覧するページ
get '/user_all_quiz_results' do
  @user_id = session[:user_id]

  @results = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT q.category, q.question_text, q.option_1, q.option_2, q.option_3, q.option_4, 
    q.correct_option, al.selected_option, al.is_correct, al.answered_at, u.name 
     FROM answer_logs al
     JOIN english_questions q ON al.question_id = q.id
     JOIN users u ON al.user_id = u.id
     WHERE u.id = $1
     ORDER BY al.answered_at DESC",
    [@user_id]
    ).to_a
  end

  @correct_answers = @results.select { |r| r["is_correct"] == "t" }
  @wrong_answers = @results.select { |r| r["is_correct"] == "f" }
  @total_count = @results.length
  @accuracy_rate = @total_count > 0 ? (@correct_answers.length.to_f / @total_count * 100).round(2) : 0

  @category_results = Hash.new{ |hash, key| hash[key] = {correct: 0, total: 0}}

  @results.each do |r|
    category = r["category"]
    is_correct = r["is_correct"] == "t"

    @category_results[category][:total] += 1
    @category_results[category][:correct] += 1 if is_correct

  end

  @test_results = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT al.selected_option, al.is_correct, t.id AS test_id, t.name AS test_name, al.answered_at AS answered_at
    FROM answer_logs al
    JOIN users u ON al.user_id = u.id
    JOIN tests t ON t.id = al.test_id
    WHERE u.id = $1
    ORDER BY al.answered_at DESC",
    [@user_id]
    )
  end

    @test_stats = Hash.new { |hash, key| hash[key] = {correct:0, total:0}}

    @test_results.each do |row|
      test_name = row["test_name"]
      is_correct = row["is_correct"] == "t"

      @test_stats[test_name][:total] += 1
      @test_stats[test_name][:correct] +=1 if is_correct
    end

  erb :user_all_quiz_results
end

#全生徒のオンラインテストの成績表示
get '/users_quiz_result' do
  # 管理者かどうかのチェック
  user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless user
  redirect '/' unless user["is_admin"].to_s == 't'

  @results = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT u.name AS user_name, u.id AS user_id, q.category, q.question_text, al.selected_option, al.is_correct, al.answered_at 
     FROM answer_logs al
     JOIN english_questions q ON al.question_id = q.id
     JOIN users u ON al.user_id = u.id
     ORDER BY al.answered_at DESC"
    ).to_a
  end

  # ユーザーごと、単元ごとの点数を集計するための空のハッシュを用意
  # 構造イメージ: { "ユーザー名" => { "単元名" => { correct: 0, total: 0 } } }
  @user_stats = Hash.new { |hash, key| hash[key] = Hash.new { |shash, skey| shash[skey] = { correct: 0, total: 0} } } 


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

    @test_results = DB_POOL.with do | conn |
      conn.exec_params(
      "SELECT u.name AS user_name, u.id AS user_id, al.selected_option, al.is_correct, t.id AS test_id, t.name AS test_name, al.answered_at AS answered_at
      FROM answer_logs al
      JOIN users u ON al.user_id = u.id
      JOIN tests t ON t.id = al.test_id
      ORDER BY al.answered_at DESC"
      )
    end

    @test_stats = Hash.new { |hash, key| hash[key] = Hash.new { |shash, skey| shash[skey] = {correct:0, total:0}}}

    @test_results.each do |row|
      user = row["user_name"]
      user_id = row["user_id"]
      test_name = row["test_name"]
      is_correct = row["is_correct"] == "t"

      @test_stats[user][test_name][:total] += 1
      @test_stats[user][test_name][:correct] +=1 if is_correct
    end

  erb :users_quiz_result
end

#ユーザーごとのオンラインテストの成績表示
get '/users_quiz_result/:user_name' do
  @user_name = params[:user_name]

  # 管理者かどうかのチェック
  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  @results = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT q.category, q.question_text, q.option_1, q.option_2, q.option_3, q.option_4, q.correct_option, al.selected_option, al.is_correct, al.answered_at 
     FROM answer_logs al
     JOIN english_questions q ON al.question_id = q.id
     JOIN users u ON al.user_id = u.id
     WHERE u.name = $1
     ORDER BY al.answered_at DESC",
    [@user_name]
    ).to_a
  end

  @correct_answers = @results.select { |r| r["is_correct"] == "t" }
  @wrong_answers = @results.select { |r| r["is_correct"] == "f" }
  @total_count = @results.length
  @accuracy_rate = @total_count > 0 ? (@correct_answers.length.to_f / @total_count * 100).round(2) : 0

  erb :users_quiz_result_detail
end

# クイズ作成用コンソール
# 💡 1. 問題選択コンソールを表示する画面
get '/admin/create-test' do
  # セッションからメッセージを取り出して、表示したら消す（一度きりの表示にするため）
  @success_message = session[:success]
  session[:success] = nil
  @selected_category = params[:category_filter]

  #　カテゴリー（分野）一覧を取得する
  categories = DB_POOL.with do | conn |
    conn.exec_params("SELECT category_ja FROM test_categories;")
  end
  @categories = categories.map { |row| row['category_ja'] }

  # 全ての問題をデータベースから取得
  if @selected_category.nil? || @selected_category.empty?
    @questions = DB_POOL.with do | conn |
    conn.exec_params(
      "SELECT id, category, question_text FROM english_questions ORDER BY category, id ASC"
      ).to_a
    end
  else
    @category_en_result = DB_POOL.with do | conn |
      conn.exec_params("SELECT category_en FROM test_categories WHERE category_ja = $1", [@selected_category]).first
    end
    @questions = DB_POOL.with do | conn |
      conn.exec_params(
      "SELECT id, category, question_text FROM english_questions WHERE category = $1 ORDER BY id ASC",
      [@category_en_result['category_en']]
      ).to_a
    end
  end

  erb :admin_create_test
end

# 💡 2. 選択された問題を受け取って処理する
post '/admin/save-test' do
  # 画面のチェックボックスで選ばれた問題のID配列を受け取る（例: ["4", "12", "15"])
  selected_ids = params[:question_ids]

  if selected_ids.nil? || selected_ids.empty?
    @error = "問題が選択されていません。最低1問以上選択してください。"
    # erbに必要な変数を全て設定する
    @selected_category = params[:category_filter]
    categories = DB_POOL.with do | conn |
      conn.exec_params("SELECT category_ja FROM test_categories;")
    end
    @categories = categories.map { |row| row['category_ja'] }
    @questions = DB_POOL.with do | conn |
      conn.exec_params("SELECT id, category, question_text FROM english_questions ORDER BY category, id ASC").to_a
    end
    return erb :admin_create_test
  end

  test_name = params[:test_name]
  test_id = DB_POOL.with do | conn |
    conn.exec_params("INSERT INTO tests (name) VALUES ($1) RETURNING id", [test_name])[0]["id"]
  end
  selected_ids.each do |q_id|
    DB_POOL.with do | conn |
      conn.exec_params("INSERT INTO test_questions (test_id, question_id) VALUES ($1, $2)", [test_id, q_id])
    end
  end

  # ✅ ここで、セッションにメッセージを代入する
  session[:success] = "テスト「#{test_name}」を保存しました！"

  redirect '/admin/create-test'
end

# admin_create_testで作成したテストの問題を受け取って表示する画面
get '/english_test/:test_name' do
  @test_name = params[:test_name]
  session[:test_name] = @test_name

  @test = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM tests WHERE name = $1", [@test_name]).first
  end
  halt 404 unless @test

  test_id = @test["id"]
  session[:test_id] = test_id

  @questions = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT q.* FROM english_questions q
     JOIN test_questions tq ON q.id = tq.question_id
     WHERE tq.test_id = $1",
     [test_id]
    ).to_a
  end

  erb :english_test
end

# admin_create_testで作成したテストの回答を送信する処理
post '/english_test/:test_name/submit' do
  test_name = params[:test_name]
  test_id = session[:test_id]
  user_id = session[:user_id]
  user_answers = params["answers"]
  @correct_count = 0

  current_time = Time.now  # 💡 全問で共通の時刻オブジェクトを作成

  if user_answers
    user_answers.each do |_index, data|
      question_id = data["id"].to_i
      chosen_option = data["chosen"].to_i

      question = DB_POOL.with do | conn |
        conn.exec_params(
        "SELECT correct_option FROM english_questions WHERE id = $1", 
        [question_id]
        ).first
      end

      is_correct = false
      if question && question["correct_option"].to_i == chosen_option
        is_correct = true
        @correct_count += 1
      end

      DB_POOL.with do | conn |
        conn.exec_params(
        "INSERT INTO answer_logs (user_id, question_id, selected_option, is_correct, answered_at, test_id) 
         VALUES ($1, $2, $3, $4, $5, $6)",
        [user_id, question_id, chosen_option, is_correct, current_time, test_id]
        )
      end
    end
  end


  session[:test_id] = test_id # 結果画面でどのテストの結果かを識別するためにセッションに保存
  session[:correct_count] = @correct_count
  session[:total_count] = user_answers ? user_answers.length.to_i : 0
  redirect '/quiz_result'
end


# 問題ごとの正答率を表示する画面（正答率の降順）
get '/question_stats' do
  # 管理者かどうかのチェック
  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  # 【修正】SQL側で正答率（accuracy_rate）を計算し、降順（DESC）で並び替える
  @question_stats = DB_POOL.with do | conn |
    conn.exec_params("
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
  end

  erb :question_stats
end

# 問題の単元（category）ごとの正答率を表示する画面（正答率の降順）
get '/question_stats_by_category' do
  # 管理者かどうかのチェック
  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  @question_categories = DB_POOL.with do | conn |
    conn.exec_params("SELECT DISTINCT category FROM english_questions ORDER BY category ASC").to_a
  end

  # 【修正】SQL側で正答率（accuracy_rate）を計算し、降順（DESC）で並び替える
  @question_stats = DB_POOL.with do | conn |
    conn.exec_params("
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
  end

  erb :question_stats_by_category
end

# これまでに作成したテストの一覧を表示する画面
get '/created_tests' do
  user_id = session[:user_id]

  # 管理者かどうかのチェック
  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [user_id]).first
  end
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  @tests = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM tests ORDER BY created_at DESC").to_a
  end

  erb :created_tests
end

# これまでに作成したテストの一覧から、出題するテストを選択する画面
post '/add_to_list' do
  # 1. チェックされたテストのID配列を取得する (例: ["3", "5", "12"])
  checkbox_params = params[:is_added_to_list] || [] # チェックされていない場合は空配列を代入
  selected_ids = checkbox_params.map(&:to_i)

  all_ids = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT id FROM tests"
    ).map{ |row| row['id'].to_i }
  end

  unselected_ids = all_ids - selected_ids

  # p selected_ids # ➔ ターミナルでどんな配列が届いているか確認できる

  # 2. 配列の中身をループ処理して、データベースを1件ずつ TRUE に更新する
  DB_POOL.with do | conn |
    selected_ids.each do |test_id|
      conn.exec_params(
        "UPDATE tests SET is_added_to_list = TRUE WHERE id = $1;",
        [test_id]
      )
    end
  end

  # 3. 配列の中身をループ処理して、選択されていないテストを1件ずつ FALSE に更新する
  DB_POOL.with do | conn |
    unselected_ids.each do |test_id|
      conn.exec_params(
        "UPDATE tests SET is_added_to_list = FALSE WHERE id = $1;",
        [test_id]
      )
    end
  end

  # 4. 処理が終わったらメッセージをセットして元のページに戻る
  session[:notice] = "#{selected_ids.length}件のテストを出題リストに追加しました！"
  redirect '/created_tests'
end


# 出題リストに追加されたテストを受験する画面
get '/listed_tests' do
  user_id = session[:user_id]

  @tests = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT tests.id AS test_id, tests.name AS test_name, tests.created_at AS created_at, test_questions.question_id AS question_id, english_questions.question_text AS question_text,
    english_questions.option_1 AS option_1, english_questions.option_2 AS option_2, english_questions.option_3 AS option_3, english_questions.option_4 AS option_4, english_questions.correct_option AS correct_option
    FROM tests
    JOIN test_questions ON tests.id = test_questions.test_id
    JOIN english_questions ON test_questions.question_id = english_questions.id
    WHERE tests.is_added_to_list = TRUE"
    )
  end

  @test_questions = {}

  @tests.each do | row |
    test_id = row['test_id']

    unless @test_questions[test_id]
      @test_questions[test_id] = {
        test_name: row['test_name'],
        questions: []
      }
    end

    @test_questions[test_id][:questions] << {
      question_id: row['question_id'],
      question_text: row['question_text'],
      option_1: row['option_1'],
      option_2: row['option_2'],
      option_3: row['option_3'],
      option_4: row['option_4'],
      correct_option: row['correct_option']
    }
  end

  erb :listed_tests
end

# テストを受験し、回答を送信する画面
post '/listed_tests/submit' do
  user_id = session[:user_id]
  test_id = params["test_id"]
  user_answers = params["answers"]

  test_name = DB_POOL.with do | conn |
    conn.exec_params(
    "select name from tests where id = $1", [test_id]
    ).first
  end

  session[:test_name] = test_name["name"]

  session[:correct_count] = 0
  session[:total_count] = 0

  # answer_logsテーブルに登録するanswered_atの時間を統一する
  current_time = Time.now

  if user_answers
    user_answers.each do | question_id, answer |

      session[:total_count] += 1

      correct_answer = DB_POOL.with do | conn |
        conn.exec_params(
          "select correct_option from english_questions where id = $1", [question_id.to_i]
        ).first["correct_option"].to_i
      end

      is_correct = false
      if correct_answer == answer.to_i
        is_correct = true
        session[:correct_count] += 1
      end
      
      DB_POOL.with do | conn |
          conn.exec_params(
          "INSERT INTO answer_logs (user_id, question_id, selected_option, is_correct, answered_at, test_id) 
          VALUES ($1, $2, $3, $4, $5, $6)",
          [user_id, question_id.to_i, answer.to_i, is_correct, current_time, test_id]
          )
      end
    end
  end

  session[:test_id] = test_id # 結果画面でどのテストの結果かを識別するためにセッションに保存
  redirect '/quiz_result'
end


# パスナビのサイトからのデータ取得
class PassNaviScraper
  def self.fetch_deviation(univ_id, department_name)
    url = "https://passnavi.obunsha.co.jp/univ/#{univ_id}/difficulty/"
    
    begin
      html = URI.open(url).read
      doc = Nokogiri::HTML.parse(html)
      
      rows = doc.css('.commonTable tr')
      puts "【デバッグ】見つかった行数: #{rows.size}件"

      found_deviation = nil
      
      rows.each do |row|
        cells = row.css('td')

        # 💡 【重要】列の数が4つ未満（見出し行や空の行）なら、エラーを防ぐために即スキップ
        next if cells.size < 4

        # 💡 4つ以上あることが確定してからデバッグ出力や処理を行う
        puts "【デバッグ】有効な行のcellsの中身: #{cells.map(&:text)}"
        
        # 4番目の列（偏差値が入る場所）を取得
        deviation_text = cells[3].text.strip
        
        # もし文字に「%」が含まれていたら、それは共通テストの行なので無視して次へ
        next if deviation_text.include?('%')
        
        # もし中身が空（得点率も偏差値も書かれていない行）なら無視して次へ
        next if deviation_text.empty?
        
        # 学科名の判定
        department_cell_text = cells[0].text
        if department_cell_text.include?(department_name)
          found_deviation = deviation_text
          break # 一般選抜の正しい偏差値が見つかったのでループを抜ける！
        end
      end
      
      return found_deviation
    rescue => e
      puts "スクレイピングエラー: #{e.message}"
      nil
    end
  end

  def self.fetch_border(univ_id, department_name)
    url = "https://passnavi.obunsha.co.jp/univ/#{univ_id}/difficulty/"
    
    begin
      html = URI.open(url).read
      doc = Nokogiri::HTML.parse(html)
      
      rows = doc.css('.commonTable tr')
      puts "【デバッグ】見つかった行数: #{rows.size}件"

      found_border = nil
      
      rows.each do |row|
        cells = row.css('td')

        # 💡 【重要】列の数が4つ未満（見出し行や空の行）なら、エラーを防ぐために即スキップ
        next if cells.size < 4

        # 💡 4つ以上あることが確定してからデバッグ出力や処理を行う
        puts "【デバッグ】有効な行のcellsの中身: #{cells.map(&:text)}"
        
        # 3番目の列（ボーダーが入る場所）を取得
        border_text = cells[2].text.strip
        
        # もし文字に「%」が含まれていたら、それはボーダーの行ではないで無視して次へ
        next if !border_text.include?('%')
        
        # もし中身が空（得点率もボーダーも書かれていない行）なら無視して次へ
        next if border_text.empty?
        
        # 学科名の判定
        department_cell_text = cells[0].text
        if department_cell_text.include?(department_name)
          found_border = border_text
          break # 一般選抜の正しいボーダーが見つかったのでループを抜ける
        end
      end
      
      return found_border
    rescue => e
      puts "スクレイピングエラー: #{e.message}"
      nil
    end
  end 

  def self.fetch_univ_id(univ_name)
    # 1. ブラウザの起動設定（ここではChromeを使用）
    options = Selenium::WebDriver::Chrome::Options.new
    # 画面を表示させずに裏で実行したい場合は以下を有効にする
    # options.add_argument('--headless') 

    driver = Selenium::WebDriver.for :chrome, options: options

    begin
      # 2. Googleのトップページを開く
      driver.get 'https://www.google.com'

      # 3. 検索窓（input要素）を見つけて、キーワードを入力
      # Googleの検索窓は name="q" という属性を持っています
      search_box = driver.find_element(name: 'q')
      search_box.send_keys('パスナビ ' + univ_name)
      search_box.submit # フォームを送信（検索実行）

      # 4. 検索結果が表示されるまで少し待つ（最大120秒）
      wait = Selenium::WebDriver::Wait.new(timeout: 120)
      wait.until { driver.find_element(id: 'search') }

      # 5. 検索結果のタイトル（h3タグ）をすべて取得して表示
      titles = driver.find_elements(css: 'h3').first.text
      return titles

    ensure
      # 6. 最後に必ずブラウザを閉じる
      driver.quit
    end
  end
    
end

get '/target_schools' do
  @user_id = session[:user_id]

  erb :target_schools
end

post '/target_schools' do
  @user_id = session[:user_id]
  univ_name = params[:univ_name]         # 例: "青学" などからIDを判定する仕組み、または直でID
  faculty_name = params[:faculty_name]   # 例: "経済学部"
  department_name = params[:department_name]  # 例: "経済学科"
  
  # 本来は大学名からパスナビの「univ_id（4桁の数字など）」を検索・特定する処理が必要
  univ_id = "2260" # 例として青山学院大学のID（仮）
  
  # スクレイピング実行
  deviation = PassNaviScraper.fetch_deviation(univ_id, department_name)
  
  if deviation
    # データベース（PostgreSQL）に志望校と取得した偏差値を保存
    DB_POOL.with do | conn |
      conn.exec_params(
        "INSERT INTO target_schools (university_name, faculty_name, department_name, deviation_value, user_id) VALUES ($1, $2, $3, $4, $5)",
        [univ_name, faculty_name, department_name, deviation.to_f, @user_id]
      )
    end
    session[:success] = "志望校と偏差値（#{deviation}）を登録しました！"
  else
    session[:error] = "偏差値の取得に失敗しました。学部名を確認してください。"
  end

  redirect '/target_schools'
end

post '/target_schools_border' do
  @user_id = session[:user_id]
  univ_name = params[:univ_name]         # 例: "青学" などからIDを判定する仕組み、または直でID
  faculty_name = params[:faculty_name]   # 例: "経済学部"
  department_name = params[:department_name]  # 例: "経済学科"
  
  # 本来は大学名からパスナビの「univ_id（4桁の数字など）」を検索・特定する処理が必要
  univ_id = "2260" # 例として青山学院大学のID（仮）
  
  # スクレイピング実行
  border = PassNaviScraper.fetch_border(univ_name)
  
  if border
    # データベース（PostgreSQL）に志望校と取得したボーダーを保存
    DB_POOL.with do | conn |
      conn.exec_params(
      "INSERT INTO target_schools (university_name, faculty_name, department_name, border_value, user_id) VALUES ($1, $2, $3, $4, $5)",
      [univ_name, faculty_name, department_name, border.to_f, @user_id]
      )
    end
    session[:success] = "志望校とボーダー（#{border}）を登録しました！"
  else
    session[:error] = "ボーダーの取得に失敗しました。学部名を確認してください。"
  end

  redirect '/target_schools'
end

post '/target_schools_id' do
  @user_id = session[:user_id]
  univ_name = params[:univ_name]         # 例: "青山学院"
  faculty_name = params[:faculty_name]   # 例: "経済"
  department_name = params[:department_name]  # 例: "経済"
  
  # スクレイピング実行
  univ_id = PassNaviScraper.fetch_univ_id(univ_name)
  
  if univ_id
    # データベース（PostgreSQL）に志望校と大学IDを保存
    DB_POOL.with do | conn |
      conn.exec_params(
      "INSERT INTO target_schools (university_name, faculty_name, department_name, passnavi_univ_id, user_id) VALUES ($1, $2, $3, $4, $5)",
      [univ_name, faculty_name, department_name, univ_id, @user_id]
      )
    end
    session[:success] = "志望校と大学ID（#{univ_id}）を登録しました！"
  else
    session[:error] = "大学IDの取得に失敗しました。"
  end

  redirect '/target_schools'
end


#面談予約機能
#面談枠作成画面
get '/create_interview_slots' do
  @user_id = session[:user_id]

  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [@user_id]).first
  end
  halt 404 unless current_user
  if current_user["is_admin"].to_s != 't'
    redirect '/'
  end

  erb :create_interview_slots
end

# 面談枠作成処理
post '/create_interview_slots' do
  @user_id = session[:user_id]
  campus = params[:campus]

  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [@user_id]).first
  end
  halt 404 unless current_user
  if current_user["is_admin"].to_s != 't'
    redirect '/'
  end

interview_slots = params[:interview_slot].split("\n").map(&:strip).reject(&:empty?)

  # 面談枠をデータベースに保存
  DB_POOL.with do | conn |
    conn.transaction do |conn|
      interview_slots.each do |slot|
        conn.exec_params(
          "INSERT INTO interview_slots (interview_slot, campus) VALUES ($1, $2)
          ON CONFLICT ON CONSTRAINT unique_interview_slot DO NOTHING",
          [slot, campus]
          )
      end
    end
  end

  session[:success] = "面談枠を作成しました。"
  redirect '/create_interview_slots'
end


# 面談予約画面
get '/interview_reservations' do
  @user_id = session[:user_id]

  # 面談枠をデータベースから取得（予約済みのものは除外）
  @available_slots = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT * FROM interview_slots WHERE user_id IS NULL ORDER BY id ASC"
    ).to_a
  end

  @grouped_slots = @available_slots.group_by { |slot| slot["campus"] }

  # 自分の面談予約状況を取得
  @my_reservations = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT * FROM interview_slots WHERE user_id = $1 ORDER BY id ASC",
    [@user_id]
    ).to_a
  end


  erb :interview_reservations
end

# 面談予約処理
post '/interview_reservations' do
  @user_id = session[:user_id]
  slot_id = params[:id]

  # 面談枠を予約（user_idを更新）
  result = DB_POOL.with do | conn |
    conn.exec_params(
    "UPDATE interview_slots SET user_id = $1 WHERE id = $2 AND user_id IS NULL",
    [@user_id, slot_id]
    )
  end

  if result.cmd_tuples > 0
    session[:success] = "面談を予約しました。"
  else
    session[:error] = "面談の予約に失敗しました。すでに予約されている可能性があります。"
  end

  redirect '/interview_reservations'
end

# 予約キャンセル処理
post '/interview_reservations/cancel' do
  @user_id = session[:user_id]
  slot_id = params[:id]

  # 面談枠の予約をキャンセル（user_idをNULLに更新）
  result = DB_POOL.with do | conn |
    conn.exec_params(
    "UPDATE interview_slots SET user_id = NULL WHERE id = $1 AND user_id = $2",
    [slot_id, @user_id]
    )
  end

  if result.cmd_tuples > 0
    session[:cancel_success] = "面談の予約をキャンセルしました。"
  else
    session[:cancel_error] = "面談の予約キャンセルに失敗しました。"
  end

  redirect '/interview_reservations'
end


# 管理者が全ユーザーの面談予約状況を確認する画面
get '/admin_interview_reservations' do
  @user_id = session[:user_id]

  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [@user_id]).first
  end
  halt 404 unless current_user
  if current_user["is_admin"].to_s != 't'
    redirect '/'
  end

  # 全ユーザーの面談予約状況を取得
  @all_reservations = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT slots.id, slots.interview_slot, slots.campus, u.name AS user_name
     FROM interview_slots slots
     LEFT JOIN users u ON slots.user_id = u.id
     ORDER BY slots.id ASC"
    ).to_a
  end

  @grouped_reservations = @all_reservations.group_by { |slot| slot["campus"] }

  erb :admin_interview_reservations
end


# 講師からのお知らせを登録する画面
get '/create_teacher_announcement' do
  @user_id = session[:user_id]

  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [@user_id]).first
  end
  halt 404 unless current_user
  if current_user["is_admin"].to_s != 't'
    redirect '/'
  end

  @announcements = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT * FROM teacher_announcements ORDER BY created_at DESC"
    ).to_a
  end

  erb :create_teacher_announcement
end

# 講師からのお知らせを登録する処理
post '/create_teacher_announcement' do
  @user_id = session[:user_id]
  title = params[:title]
  content = params[:content]

  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [@user_id]).first
  end
  halt 404 unless current_user
  if current_user["is_admin"].to_s != 't'
    redirect '/'
  end

  # お知らせをデータベースに保存
  DB_POOL.with do | conn |
    conn.exec_params(
    "INSERT INTO teacher_announcements (title, content, user_id) VALUES ($1, $2, $3)",
    [title, content, @user_id]
    )
  end

  session[:success] = "お知らせを登録しました。"
  redirect '/create_teacher_announcement'
end

