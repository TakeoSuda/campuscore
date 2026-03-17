require 'sinatra'

enable :sessions

require 'sinatra/reloader'
require 'sinatra/cookies'

require 'pg'
client = PG.connect(
  host: "localhost",
  dbname: "campuscore"
)

require 'bcrypt'

# ユーザー登録・ログイン関係
get '/signup' do
  erb :signup
end

post "/signup" do
  @name_kana = params[:name_kana]
  @name = params[:name]
  @email = params[:email]
  
  if params[:password] == params[:password_confirm] 
    # bcryptで暗号化
    @password = BCrypt::Password.create(params[:password])
  else
    @error = "パスワードが一致しません。"
    return erb :signup
  end

  @school = params[:school]
  @grade = params[:grade]

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

  # DBからユーザーを取得（ハッシュも取得）
  result = client.exec_params("SELECT * FROM users WHERE email = $1", [email])
  user = result.first

  if user && BCrypt::Password.new(user['password']) == password
    # 照合成功
    session[:user] = user
    redirect "/mypage"
  else
    @error = "メールアドレスまたはパスワードが間違っています"
    erb :login
  end
end

get '/logout' do
  session.clear
  redirect '/login'
end


# マイページ関係
get '/mypage' do
  user_id = session[:user]["id"]

  result = client.exec_params(
  "SELECT * FROM users WHERE id=$1",
  [user_id]
  )

  @user = result[0]
  erb :mypage
end

get "/mypage_edit" do
  user_id = session[:user]["id"]

  result = client.exec_params(
    "SELECT * FROM users WHERE id=$1",
    [user_id]
  )

  @user = result[0]

  erb :mypage_edit
end

post '/mypage_edit' do
  user_id = session[:user]["id"]
  @name_kana = params[:name_kana]
  @name = params[:name]
  @email = params[:email]
  
# パスワードが入力された時だけ更新するロジック 
if params[:password] && params[:password] != "" && params[:password] == params[:password_confirm]
# パスワードをハッシュ化して保存する処理 

# パスワードをハッシュ化する処理 
# params[:password] はフォームから送られてきた生パスワード 
  raw_password = params[:password] 
# 1. ハッシュ化を実行（「ソルト」と呼ばれるランダムな値も自動で付与されます） 
  @password = BCrypt::Password.create(raw_password) 
else
  @password = session[:user]["password"]  # パスワードが入力されていない場合は現在のパスワードを保持
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
  # 文字列として受け取る
  recommend_exam_param = params[:recommend_exam]

  # Booleanに変換
  @recommend_exam = recommend_exam_param == "true"

  client.exec_params(
    "UPDATE users SET name_kana=$1, name=$2, email=$3, password=$4, school=$5, grade=$6, desired_school=$7, faculty=$8, department=$9, second_desired_school=$10, second_desired_faculty=$11, second_desired_department=$12, target_ct_reading=$13, target_ct_listening=$14, last_ct_reading=$15, last_ct_listening=$16, eiken_level=$17, desired_eiken_level=$18, strong_subject=$19, weak_subject=$20, hobby=$21, club=$22, desired_job=$23, dream=$24, resolution=$25, consult=$26, worry=$27, recommend_exam=$28 WHERE id=$29",
    [@name_kana, @name, @email, @password, @school, @grade, @desired_school, @faculty, @department, @second_desired_school, @second_desired_faculty, @second_desired_department, @target_ct_reading, @target_ct_listening, @last_ct_reading, @last_ct_listening, @eiken_level, @desired_eiken_level, @strong_subject, @weak_subject, @hobby, @club, @desired_job, @dream, @resolution, @consult, @worry, @recommend_exam, user_id]
  )

  redirect '/mypage'
end


# チャットルーム関係
get '/chat_rooms/new' do
  # 他のユーザー一覧を取得（自分以外）
  current_user_id = session[:user]["id"]
  @users = client.exec_params(
    "SELECT id, name FROM users WHERE id <> $1",
    [current_user_id]
  ).to_a

  erb :new_chat_room
end

post '/chat_rooms' do
  current_user_id = session[:user]["id"]
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
  user_id = session[:user]["id"]
  
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
  sender_id = session[:user]["id"]
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
  @user_id = session[:user]["id"]
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
  @user_id = session[:user]["id"]
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
  @user_id = session[:user]["id"]
  @consults = client.exec_params(
    "SELECT * FROM consults
      WHERE user_id = $1
      ORDER BY date DESC",
    [@user_id]
  ).to_a
  erb :consults
end

post '/consults/new' do
  @user_id = session[:user]["id"]
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
  @user_id = session[:user]["id"]
  @diary_entries = client.exec_params(
    "SELECT * FROM diary_entries
      WHERE user_id = $1
      ORDER BY date DESC",
    [@user_id]
  ).to_a
  erb :diary
end

post '/diary/new' do
  @user_id = session[:user]["id"]
  @content = params[:content]
  @date = params[:date]

  client.exec_params(
    "INSERT INTO diary_entries (user_id, content, date) VALUES ($1, $2, $3)",
    [@user_id, @content, @date]
  )

  redirect '/diary'
end

get '/recommends' do
	@user_id = session[:user]["id"]
	erb :recommends
end

# 英語レベルに基づく教材推薦
post '/recommends' do 
# 1. フォームデータの受け取り 
@user_id = session[:user]["id"]
@w_lv = params[:word_level].to_i 
@g_lv = params[:grammar_level].to_i 
@r_lv = params[:reading_level].to_i

 client.exec_params(
   "INSERT INTO english_levels (user_id, word_level, grammar_level, reading_level) VALUES ($1, $2, $3, $4)",
   [@user_id, @w_lv, @g_lv, @r_lv]
 )

@recommended_books = client.exec_params( "SELECT * FROM english_books 
WHERE (category = 'word' AND level = $1) 
OR (category = 'grammar' AND level = $2) 
OR (category = 'reading' AND level = $3) 
ORDER BY category ASC, level DESC", 
[@w_lv, @g_lv, @r_lv] ).to_a

erb :recommends_results 
end
