class CreateInstructions < ActiveRecord::Migration[8.1]
  def change
    create_table :instructions do |t|
      t.text :content       # 指示の内容
      t.string :category    # カテゴリ
      t.timestamps          # 作成日時と更新日時を自動追加
    end
  end
end



