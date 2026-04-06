class AddUserIdToInstructions < ActiveRecord::Migration[8.1]
  def change
    # instructionsテーブルにuser_id（整数型）を追加する
    add_column :instructions, :user_id, :integer
    
    # オプション：usersテーブルのidと紐付ける制約（インデックス）を付ける
    add_index :instructions, :user_id
  end
end

