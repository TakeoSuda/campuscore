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



