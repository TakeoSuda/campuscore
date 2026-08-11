
# 自由英作文の答案自動採点機能
# 自由英作文の答案画像をアップロードする画面
get '/essay_writing' do
  @user_id = session[:user_id]
  erb :essay_writing
end

post '/essay_writing' do
  @user_id = session[:user_id]
  @question = params[:question]
  essay_file = params[:essay_image]

  # 💡 最初にあらかじめ空の文字列を入れておき、スコープ（変数の有効範囲）の事故を防ぐ
  detected_text = ""
  unique_filename = nil

  if essay_file
    tempfile = essay_file[:tempfile] # フォームから取り出したファイル
    # --- ✨ Google Cloud Vision API による高精度OCR処理 ---
    begin
      # 1. 設置した JSON ファイルを使って、GoogleのAIクライアントを起動
      # 1-1. 認証鍵ファイルのパスを環境変数（ENV）にセットする
      ENV["VISION_CREDENTIALS"] = "google-credentials.json"

      # 1-2. 引数なしでクライアントを起動（自動的に上記の環境変数を読み込んでくれる）
      image_annotator = Google::Cloud::Vision.image_annotator

      # 2. 画像ファイルをGoogle Cloudに投げて、文章（ドキュメント）として解析を依頼
      response = image_annotator.document_text_detection(image: tempfile.path)

      # 3. 解析結果からテキストをまるごと抽出
      if response.responses.first&.full_text_annotation
        detected_text = response.responses.first.full_text_annotation.text.strip
      end

      puts "====== [Google OCR 読み取り成功！] ======"
      puts detected_text.inspect
      puts "========================================"

    rescue => e
      # 万が一エラーが起きた場合は、原因が分かるようにDBにエラーメッセージを入れます
      detected_text = "【Google OCRエラー】: #{e.message}"
      puts detected_text
    end

    # --- 画像の保存処理 (Cloudinary) ---
    response = Cloudinary::Uploader.upload(tempfile.path)
    unique_filename = response['secure_url']
  end


  # --------------------------------------------------
  # 🚀【ここから新規追加】OpenAIによるAI添削処理
  # --------------------------------------------------
  
  # 1. OpenAIクライアントの初期化（自動で ENV['OPENAI_API_KEY'] を読み込みます）
  openai_client = OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY"))

  # 🧪 試しにターミナルにキーの最初と最後だけを表示させてみる
  puts "=== 読み込まれているキー: #{ENV['OPENAI_API_KEY']&.start_with?('sk') ? 'OK' : '空っぽです'} ==="
    
  # 2. AIに「プロの英語教師」としての役割と、返却してほしいJSONの形（プロンプト）を指示する
  system_prompt = <<~TEXT
    あなたは親切で優秀な英語のプロ講師です。
    ユーザーが書いた自由英作文の文章を添削し、必ず指定された以下のJSON形式でのみ返答してください。
    挨拶や解説などの余計なテキストは一切含めず、純粋なJSONデータだけを返してください。
    
    {
      "original_text": "元の文章",
      "corrected_text": "文法や表現を綺麗に修正した後の完璧な文章",
      "score": 100点満点中の点数(数値のみ),
      "feedback": "全体的な講評や、もっと良くなるためのアドバイス（日本語）",
      "grammars": [
        {"mistake": "間違っていた部分や不自然な表現", "reason": "なぜ間違っているか、どう直すべきかの丁寧な解説（日本語）"}
      ]
    }
  TEXT

  begin
    # 3. OpenAIのAPIへリクエストを送信
    response = openai_client.chat(
      parameters: {
        model: "gpt-4o-mini", # コスパ最強＆爆速の最新モデル
        response_format: { type: "json_object" }, # 確実にJSONで返してもらうための魔法の設定
        messages: [
          { role: "system", content: system_prompt },
          { 
            role: "user", 
            # 💡 question と detected_text を分かりやすくドッキングさせて渡す
            content: "【質問/お題】\n#{@question}\n\n【ユーザーが書いた英作文】\n#{detected_text}" 
          }
        ],
        temperature: 0.3 # 回答のブレを抑え、安定した添削を行わせる設定
      }
    )

    # 4. AIから返ってきたJSON形式の文字列を取り出す
    ai_response_json = response.dig("choices", 0, "message", "content")
    
    # 5. JSON文字列をRubyのハッシュ（連想配列）に変換して、ビュー（ERB）に渡せるようにする
    @result = JSON.parse(ai_response_json)


    # 6. AIによる添削結果をessaysテーブルとessay_grammarsテーブルに格納する。また、保存と同時に、生成されたばかりの id をその場で取得する。
    if unique_filename
    
      essay_result = DB_POOL.with do | conn |
        conn.exec_params(
        "INSERT INTO essays (essay_image, question, user_id, title, ocr_text, corrected_text, score, feedback) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
        [unique_filename, @question, @user_id, @title, detected_text, @result["corrected_text"], @result["score"], @result["feedback"]]
        )
      end
      # 配列（ハッシュの配列）として結果が返ってくるので、最初の1件の "id" を取り出す
      essay_id = essay_result.first["id"].to_i

      if @result["grammars"] && @result["grammars"].is_a?(Array)
        @result["grammars"].each do |grammar|
          DB_POOL.with do | conn |
            conn.exec_params(
            "INSERT INTO essay_grammars (essay_id, mistake, reason) VALUES ($1, $2, $3)",
            [essay_id, grammar["mistake"], grammar["reason"]]
            )
          end
        end
      end
      session[:success] = "自由英作文の画像をアップロードしました。文字の自動解析も完了しました！"

    else
      session[:error] = "処理に失敗しました。"
    end


    # 7. 添削結果を表示する専用のERB画面（次に作ります）へ進む
    erb :essay_writing_result

  rescue => e
    # 万が一AI処理でエラーが起きた場合のセーフティ
    puts "AI添削エラーが発生しました: #{e.message}"
    @error_message = "AI添削中にエラーが発生しました。もう一度お試しいただくか、管理者にお問い合わせください。"
    erb :essay_writing # 必要に応じてエラー画面を用意（または既存のフォーム画面に戻すなど）
  end

end




# 画面から直接、自由英作文の文章を入力してAIに添削させる場合の処理
post '/form_input_essay_writing' do
  @user_id = session[:user_id]
  @title = params[:title]
  @question = params[:question]

  # 💡 最初にあらかじめ空の文字列を入れておき、スコープ（変数の有効範囲）の事故を防ぐ
  form_input_text = ""
  question = ""

  form_input_text = params[:form_input_text] if params[:form_input_text]
  question = params[:question] if params[:question]

  # --------------------------------------------------
  # 🚀【ここから新規追加】OpenAIによるAI添削処理
  # --------------------------------------------------
  
  # 1. OpenAIクライアントの初期化（自動で ENV['OPENAI_API_KEY'] を読み込みます）
  openai_client = OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY"))

  # 2. AIに「プロの英語教師」としての役割と、返却してほしいJSONの形（プロンプト）を指示する
  system_prompt = <<~TEXT
    あなたは親切で優秀な英語のプロ講師です。
    ユーザーが書いた自由英作文の文章を添削し、必ず指定された以下のJSON形式でのみ返答してください。
    挨拶や解説などの余計なテキストは一切含めず、純粋なJSONデータだけを返してください。
    
    {
      "original_text": "元の文章",
      "corrected_text": "文法や表現を綺麗に修正した後の完璧な文章",
      "score": 100点満点中の点数(数値のみ),
      "feedback": "全体的な講評や、もっと良くなるためのアドバイス（日本語）",
      "grammars": [
        {"mistake": "間違っていた部分や不自然な表現", "reason": "なぜ間違っているか、どう直すべきかの丁寧な解説（日本語）"}
      ]
    }
  TEXT

  begin
    # 3. OpenAIのAPIへリクエストを送信
    response = openai_client.chat(
      parameters: {
        model: "gpt-4o-mini", # コスパ最強＆爆速の最新モデル
        response_format: { type: "json_object" }, # 確実にJSONで返してもらうための魔法の設定
        messages: [
          { role: "system", content: system_prompt },
          { 
            role: "user", 
            # 💡 question と form_input_text を分かりやすくドッキングさせて渡す
            content: "【質問/お題】\n#{question}\n\n【ユーザーが書いた英作文】\n#{form_input_text}" 
          }
        ],
        temperature: 0.3 # 回答のブレを抑え、安定した添削を行わせる設定
      }
    )

    # 4. AIから返ってきたJSON形式の文字列を取り出す
    ai_response_json = response.dig("choices", 0, "message", "content")
    
    # 5. JSON文字列をRubyのハッシュ（連想配列）に変換して、ビュー（ERB）に渡せるようにする
    @result = JSON.parse(ai_response_json)

    puts @result

    # 6. AIによる添削結果をessaysテーブルとessay_grammarsテーブルに格納する。また、保存と同時に、生成されたばかりの id をその場で取得する。
    essay_result = DB_POOL.with do | conn |
      conn.exec_params(
      "INSERT INTO essays (question, user_id, title, form_input_text, corrected_text, score, feedback) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id",
      [@question, @user_id, @title, form_input_text, @result["corrected_text"], @result["score"], @result["feedback"]]
      )
    end
    # 配列（ハッシュの配列）として結果が返ってくるので、最初の1件の "id" を取り出す
    essay_id = essay_result.first["id"].to_i

    if @result["grammars"] && @result["grammars"].is_a?(Array)
      @result["grammars"].each do |grammar|
        DB_POOL.with do | conn |
          conn.exec_params(
          "INSERT INTO essay_grammars (essay_id, mistake, reason) VALUES ($1, $2, $3)",
          [essay_id, grammar["mistake"], grammar["reason"]]
          )
        end
      end
    end

    # 7. 添削結果を表示する専用のERB画面（次に作ります）へ進む
    erb :essay_writing_result

  rescue => e
    # 万が一AI処理でエラーが起きた場合のセーフティ
    puts "AI添削エラーが発生しました: #{e.message}"
    @error_message = "AI添削中にエラーが発生しました。もう一度お試しいただくか、管理者にお問い合わせください。"
    erb :essay_writing # 必要に応じてエラー画面を用意（または既存のフォーム画面に戻すなど）
  end

end


# 全ユーザーの自由英作文の答案と添削結果を一覧表示する画面
get '/users_essay_results' do
  # 管理者かどうかのチェック
  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  raw_results = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT e.id, e.question, e.title, e.essay_image, e.form_input_text, 
    e.corrected_text, e.score, e.feedback, u.name AS user_name, e.created_at, e.human_feedback,
    eg.mistake, eg.reason
     FROM essays e
     JOIN users u ON e.user_id = u.id
     JOIN essay_grammars eg ON e.id = eg.essay_id
     ORDER BY e.created_at DESC"
    ).to_a
  end

  @grouped_essays = raw_results.group_by { |row| row["id"] }

  puts @grouped_essays


  erb :users_essay_results
end

# 全ユーザーの自由英作文の答案に対して、個別に人間の講師の添削メッセージを追加する画面
post '/users_essay_results/:essay_id/feedback' do
  essay_id = params[:essay_id]
  human_feedback = params[:human_feedback]

  # 管理者かどうかのチェック
  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  # essaysテーブルのhuman_feedbackカラムを更新する
  DB_POOL.with do | conn |
    conn.exec_params(
    "UPDATE essays SET human_feedback = $1 WHERE id = $2",
    [human_feedback, essay_id]
    )
  end

  session[:success] = "添削メッセージを更新しました。"
  redirect '/users_essay_results'
end

#　各ユーザーが自分の書いた英作文答案に対する、添削結果を確認する画面
get '/my_essay_results' do
  @user_id = session[:user_id]

  @results = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT e.id, e.question, e.title, e.essay_image, e.form_input_text, 
    e.corrected_text, e.score, e.feedback, u.name AS user_name, e.created_at, e.human_feedback,
    eg.mistake, eg.reason
     FROM essays e
     JOIN users u ON e.user_id = u.id
     JOIN essay_grammars eg ON e.id = eg.essay_id
     WHERE u.id = $1
     ORDER BY e.created_at DESC",
    [@user_id]
    ).to_a
  end

  @grouped_essays = @results.group_by { |row| row["id"] }

  erb :my_essay_results
end


# グラフ自由英作文の答案自動採点機能
# グラフ自由英作文の問題画像と答案画像をアップロードする画面
get '/essay_writing_graph' do
  @user_id = session[:user_id]
  erb :essay_writing_graph
end

post '/essay_writing_graph' do
  @user_id = session[:user_id]
  @title = params[:title]
  @question = params[:question]
  @answer = params[:answer_graph]
  
  essay_file = params[:image_graph]


  # 💡 最初にあらかじめ空の文字列を入れておき、スコープ（変数の有効範囲）の事故を防ぐ
  unique_filename = nil

  if essay_file
    tempfile = essay_file[:tempfile] # フォームから取り出したファイル
    
    # --- 画像の保存処理 (Cloudinary) ---
    response = Cloudinary::Uploader.upload(tempfile.path)
    unique_filename = response['secure_url']
  end

  # --------------------------------------------------
  # 🚀【ここから新規追加】OpenAIによるAI添削処理
  # --------------------------------------------------
  
  # 1. OpenAIクライアントの初期化（自動で ENV['OPENAI_API_KEY'] を読み込みます）
  openai_client = OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY"))

  # 🧪 試しにターミナルにキーの最初と最後だけを表示させてみる
  puts "=== 読み込まれているキー: #{ENV['OPENAI_API_KEY']&.start_with?('sk') ? 'OK' : '空っぽです'} ==="
    
  # 2. AIに「プロの英語教師」としての役割と、返却してほしいJSONの形（プロンプト）を指示する
  system_prompt = <<~TEXT
    あなたは親切で優秀な英語のプロ講師です。
    ユーザーが書いた「グラフ型の自由英作文」の答案を添削してください。
    添付されたグラフ画像や設問内容と、ユーザーの英作文の内容が一致しているか（グラフのデータを正しく読み取って英作文に反映できているか）も含めて採点してください。

    必ず指定された以下のJSON形式でのみ返答してください。余計なテキストは一切含めないでください。
    
    {
      "original_text": "元の文章",
      "corrected_text": "文法や表現を綺麗に修正した後の完璧な文章",
      "score": 100点満点中の点数(数値のみ。グラフの読み取りの正確さも考慮すること),
      "feedback": "全体的な講評や、グラフの読み取りに関するアドバイス、もっと良くなるための指導（日本語）",
      "grammars": [
        {"mistake": "間違っていた部分や不自然な表現", "reason": "なぜ間違っているか、どう直すべきかの丁寧な解説（日本語）"}
      ]
    }
  TEXT


  # --- ユーザーメッセージの内容（テキスト＋画像）を構築 ---
  user_content = [
    {
      type: "text",
      text: "【質問/お題】\n#{@question}\n\n【ユーザーが書いた英作文】\n#{@answer}\n\n上記の英作文が、添付されたグラフ画像の内容を正確に描写・説明できているかも含めて添削してください。"
    }
  ]

  # 画像が存在する場合は、image_url を追加する
  if unique_filename
    user_content << {
      type: "image_url",
      image_url: {
        url: unique_filename
      }
    }
  end


  begin
    # 3. OpenAIのAPIへリクエストを送信
    response = openai_client.chat(
      parameters: {
        model: "gpt-4o-mini", # コスパ最強＆爆速の最新モデル
        response_format: { type: "json_object" }, # 確実にJSONで返してもらうための魔法の設定
        messages: [
          { role: "system", content: system_prompt },
          { 
            role: "user", 
            # 💡 question と detected_text を分かりやすくドッキングさせて渡す
            content: user_content
          } #　配列形式でテキストと画像を渡す
        ],
        temperature: 0.3 # 回答のブレを抑え、安定した添削を行わせる設定
      }
    )

    # 4. AIから返ってきたJSON形式の文字列を取り出す
    ai_response_json = response.dig("choices", 0, "message", "content")
    
    # 5. JSON文字列をRubyのハッシュ（連想配列）に変換して、ビュー（ERB）に渡せるようにする
    @result = JSON.parse(ai_response_json)


    # 6. AIによる添削結果をessays_graphテーブルとessay_grammars_graphテーブルに格納する。また、保存と同時に、生成されたばかりの id をその場で取得する。
    if unique_filename
    
      essay_result = DB_POOL.with do | conn |
        conn.exec_params(
        "INSERT INTO essays_graph (image_graph, question_graph, user_id, title_graph, answer_graph, corrected_answer_graph, score, feedback) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
        [unique_filename, @question, @user_id, @title, @answer, @result["corrected_text"], @result["score"], @result["feedback"]]
        )
      end
      # 配列（ハッシュの配列）として結果が返ってくるので、最初の1件の "id" を取り出す
      essay_id = essay_result.first["id"].to_i

      if @result["grammars"] && @result["grammars"].is_a?(Array)
        DB_POOL.with do | conn |  
          @result["grammars"].each do |grammar|
            conn.exec_params(
            "INSERT INTO essay_grammars_graph (essay_id_graph, mistake, reason) VALUES ($1, $2, $3)",
            [essay_id, grammar["mistake"], grammar["reason"]]
            )
          end
        end
      end
      session[:success] = "グラフ型自由英作文の問題画像をアップロードし、採点が完了しました！"

    else
      session[:error] = "画像のアップロードに失敗しました。"
    end


    # 7. 添削結果を表示する専用のERB画面（次に作ります）へ進む
    erb :essay_writing_result_graph

  rescue => e
    # 万が一AI処理でエラーが起きた場合のセーフティ
    puts "AI添削エラーが発生しました: #{e.message}"
    @error_message = "AI添削中にエラーが発生しました。もう一度お試しいただくか、管理者にお問い合わせください。"
    erb :essay_writing_graph # 必要に応じてエラー画面を用意（または既存のフォーム画面に戻すなど）
  end

end



#　各ユーザーが自分の書いた英作文答案に対する、添削結果を確認する画面
get '/my_essay_results_graph' do
  @user_id = session[:user_id]

  @results = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT eg.id, eg.question_graph, eg.title_graph, eg.image_graph, eg.answer_graph, 
    eg.corrected_answer_graph, eg.score, eg.feedback, u.name AS user_name, eg.created_at, eg.human_feedback,
    egg.mistake, egg.reason
     FROM essays_graph eg
     JOIN users u ON eg.user_id = u.id
     JOIN essay_grammars_graph egg ON eg.id = egg.essay_id_graph
     WHERE u.id = $1
     ORDER BY eg.created_at DESC",
    [@user_id]
    ).to_a
  end

  @grouped_essays = @results.group_by { |row| row["id"] }

  erb :my_essay_results_graph
end



# ✒️英文和訳の答案自動採点機能
# 英文和訳を入力する画面
get '/english_to_japanese_translation' do
  @user_id = session[:user_id]
  erb :english_to_japanese_translation
end

# 画面から直接、和訳の文章を入力してAIに添削させる場合の処理
post '/english_to_japanese_translation' do
  @user_id = session[:user_id]
  @title = params[:title]
  
  # 💡 最初にあらかじめ空の文字列を入れておき、スコープ（変数の有効範囲）の事故を防ぐ
  e_to_j_translation = ""
  e_to_j_translation = params[:e_to_j_translation] if params[:e_to_j_translation]
  @english_text = ""
  @english_text = params[:english_text] if params[:english_text]

  # --------------------------------------------------
  # 🚀【ここから新規追加】OpenAIによるAI添削処理
  # --------------------------------------------------
  
  # 1. OpenAIクライアントの初期化（自動で ENV['OPENAI_API_KEY'] を読み込みます）
  openai_client = OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY"))

  # 2. AIに「プロの英語教師」としての役割と、返却してほしいJSONの形（プロンプト）を指示する
  system_prompt = <<~TEXT
    あなたは親切で優秀な英語のプロ講師です。
    ユーザーが書いた英文和訳の文章を添削し、必ず指定された以下のJSON形式でのみ返答してください。
    挨拶や解説などの余計なテキストは一切含めず、純粋なJSONデータだけを返してください。
    
    {
      "original_text": "元の文章",
      "corrected_text": "文法や表現を綺麗に修正した後の完璧な文章",
      "score": 100点満点中の点数(数値のみ),
      "feedback": "全体的な講評や、もっと良くなるためのアドバイス（日本語）",
      "mistakes": [
        {"mistake_content": "文法的に間違っていた部分や意味的に間違っていた部分", "reason": "なぜ間違っているか、どう直すべきかの丁寧な解説（日本語）"}
      ]
    }
  TEXT

  begin
    # 3. OpenAIのAPIへリクエストを送信
    response = openai_client.chat(
      parameters: {
        model: "gpt-4o-mini", # コスパ最強＆爆速の最新モデル
        response_format: { type: "json_object" }, # 確実にJSONで返してもらうための魔法の設定
        messages: [
          { role: "system", content: system_prompt },
          { 
            role: "user", 
            # 💡 english_text と e_to_j_translation を分かりやすくドッキングさせて渡す
            content: "【英文】\n#{@english_text}\n\n【ユーザーが書いた和訳】\n#{e_to_j_translation}" 
          }
        ],
        temperature: 0.3 # 回答のブレを抑え、安定した添削を行わせる設定
      }
    )

    # 4. AIから返ってきたJSON形式の文字列を取り出す
    ai_response_json = response.dig("choices", 0, "message", "content")
    
    # 5. JSON文字列をRubyのハッシュ（連想配列）に変換して、ビュー（ERB）に渡せるようにする
    @result = JSON.parse(ai_response_json)

    puts @result

    # 6. AIによる添削結果をtranslationsテーブルとtranslation_mistakesテーブルに格納する。また、保存と同時に、生成されたばかりの id をその場で取得する。
    translation_result = DB_POOL.with do | conn |
      conn.exec_params(
      "INSERT INTO translations (user_id, title, english_text, japanese_translation, corrected_text, score, feedback) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id",
      [@user_id, @title, @english_text, e_to_j_translation, @result["corrected_text"], @result["score"], @result["feedback"]]
      )
    end
    # 配列（ハッシュの配列）として結果が返ってくるので、最初の1件の "id" を取り出す
    translation_id = translation_result.first["id"].to_i

    if @result["mistakes"] && @result["mistakes"].is_a?(Array)
      @result["mistakes"].each do |mistake|
        DB_POOL.with do | conn |
          conn.exec_params(
          "INSERT INTO translation_mistakes (translation_id, mistake, reason) VALUES ($1, $2, $3)",
          [translation_id, mistake["mistake_content"], mistake["reason"]]
          )
        end
      end
    end

    # 7. 添削結果を表示する専用のERB画面（次に作ります）へ進む
    erb :english_to_japanese_translation_result

  rescue => e
    # 万が一AI処理でエラーが起きた場合のセーフティ
    puts "AI添削エラーが発生しました: #{e.message}"
    @error_message = "AI添削中にエラーが発生しました。もう一度お試しいただくか、管理者にお問い合わせください。"
    erb :english_to_japanese_translation # 必要に応じてエラー画面を用意（または既存のフォーム画面に戻すなど）
  end

end


# 全ユーザーの英文和訳の答案と添削結果を一覧表示する画面
get '/users_translation_results' do
  # 管理者かどうかのチェック
  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  raw_results = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT t.id, t.english_text, t.title, t.japanese_translation,
    t.corrected_text, t.score, t.feedback, u.name AS user_name, t.created_at, t.human_feedback,
    tm.mistake, tm.reason
     FROM translations t
     JOIN users u ON t.user_id = u.id
     JOIN translation_mistakes tm ON t.id = tm.translation_id
     ORDER BY t.created_at DESC"
    ).to_a
  end

  @grouped_translations = raw_results.group_by { |row| row["id"] }

  puts @grouped_translations


  erb :users_translation_results
end

# 全ユーザーの自由英作文の答案に対して、個別に人間の講師の添削メッセージを追加する画面
post '/users_translation_results/:translation_id/feedback' do
  translation_id = params[:translation_id]
  human_feedback = params[:human_feedback]

  # 管理者かどうかのチェック
  current_user = DB_POOL.with do | conn |
    conn.exec_params("SELECT * FROM users WHERE id=$1", [session[:user_id]]).first
  end
  halt 404 unless current_user
  redirect '/' unless current_user["is_admin"].to_s == 't'

  # translationsテーブルのhuman_feedbackカラムを更新する
  DB_POOL.with do | conn |
    conn.exec_params(
    "UPDATE translations SET human_feedback = $1 WHERE id = $2",
    [human_feedback, translation_id]
    )
  end

  session[:success] = "添削メッセージを更新しました。"
  redirect '/users_translation_results'
end

#　各ユーザーが自分の書いた英作文答案に対する、添削結果を確認する画面
get '/my_english_to_japanese_translation_results' do
  @user_id = session[:user_id]

  @results = DB_POOL.with do | conn |
    conn.exec_params(
    "SELECT t.id, t.english_text, t.title, t.japanese_translation, 
    t.corrected_text, t.score, t.feedback, u.name AS user_name, t.created_at, t.human_feedback,
    tm.mistake, tm.reason
     FROM translations t
     JOIN users u ON t.user_id = u.id
     JOIN translation_mistakes tm ON t.id = tm.translation_id
     WHERE u.id = $1
     ORDER BY t.created_at DESC",
    [@user_id]
    ).to_a
  end

  @grouped_translations = @results.group_by { |row| row["id"] }

  erb :my_english_to_japanese_translation_results
end

