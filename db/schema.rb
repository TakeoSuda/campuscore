# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_05_124400) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "chat_room_users", id: :serial, force: :cascade do |t|
    t.integer "chat_room_id"
    t.datetime "joined_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.integer "user_id"
  end

  create_table "chat_rooms", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.string "name", limit: 255
    t.datetime "updated_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
  end

  create_table "consults", id: :serial, force: :cascade do |t|
    t.string "content", limit: 300, null: false
    t.datetime "created_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.date "date"
    t.datetime "updated_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.integer "user_id", null: false
  end

  create_table "diary_entries", id: :serial, force: :cascade do |t|
    t.string "content", limit: 400, null: false
    t.datetime "created_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.date "date"
    t.datetime "updated_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.integer "user_id", null: false
  end

  create_table "english_books", id: :serial, force: :cascade do |t|
    t.string "category", limit: 20
    t.text "description"
    t.integer "level"
    t.string "title", limit: 255, null: false
    t.check_constraint "category::text = ANY (ARRAY['word'::character varying, 'grammar'::character varying, 'reading'::character varying]::text[])", name: "english_books_category_check"
    t.check_constraint "level >= 1 AND level <= 5", name: "english_books_level_check"
  end

  create_table "english_levels", id: :serial, force: :cascade do |t|
    t.integer "grammar_level"
    t.integer "reading_level"
    t.datetime "recorded_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.integer "user_id"
    t.integer "word_level"
    t.check_constraint "grammar_level >= 1 AND grammar_level <= 5", name: "english_levels_grammar_level_check"
    t.check_constraint "reading_level >= 1 AND reading_level <= 5", name: "english_levels_reading_level_check"
    t.check_constraint "word_level >= 1 AND word_level <= 5", name: "english_levels_word_level_check"
  end

  create_table "instructions", force: :cascade do |t|
    t.string "category"
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "messages", id: :serial, force: :cascade do |t|
    t.integer "chat_room_id"
    t.text "content", null: false
    t.datetime "created_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "read_at", precision: nil
    t.integer "sender_id"
  end

  create_table "plans", id: :serial, force: :cascade do |t|
    t.integer "completed_laps", default: 0
    t.datetime "created_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.date "end_date"
    t.integer "laps"
    t.string "material", limit: 100
    t.text "purpose"
    t.date "start_date"
    t.string "status", limit: 20, default: "not_started"
    t.string "subject", limit: 50, null: false
    t.datetime "updated_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.integer "user_id", null: false
    t.check_constraint "status::text = ANY (ARRAY['not_started'::character varying, 'in_progress'::character varying, 'completed'::character varying]::text[])", name: "plans_status_check"
  end

  create_table "users", id: :serial, force: :cascade do |t|
    t.string "club", limit: 255
    t.text "consult"
    t.datetime "created_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.text "department"
    t.text "desired_eiken_level"
    t.text "desired_job"
    t.text "desired_school"
    t.text "dream"
    t.text "eiken_level"
    t.text "email"
    t.text "faculty"
    t.text "grade", null: false
    t.string "hobby", limit: 255
    t.boolean "is_admin", default: false
    t.integer "last_ct_listening"
    t.integer "last_ct_reading"
    t.text "name", null: false
    t.text "name_kana", null: false
    t.string "password", limit: 255, null: false
    t.boolean "recommend_exam", default: false
    t.text "request_for_class"
    t.string "reset_token", limit: 255
    t.datetime "reset_token_expires_at", precision: nil, default: -> { "(now() + 'PT1H'::interval)" }
    t.text "resolution"
    t.text "school", null: false
    t.text "second_desired_department"
    t.text "second_desired_faculty"
    t.text "second_desired_school"
    t.text "strong_subject"
    t.integer "target_ct_listening"
    t.integer "target_ct_reading"
    t.datetime "updated_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.text "weak_subject"
    t.text "worry"

    t.unique_constraint ["email"], name: "users_email_key"
  end

  add_foreign_key "chat_room_users", "chat_rooms", name: "chat_room_users_chat_room_id_fkey"
  add_foreign_key "chat_room_users", "users", name: "chat_room_users_user_id_fkey"
  add_foreign_key "consults", "users", name: "consults_user_id_fkey"
  add_foreign_key "diary_entries", "users", name: "diary_entries_user_id_fkey"
  add_foreign_key "english_levels", "users", name: "english_levels_user_id_fkey"
  add_foreign_key "messages", "chat_rooms", name: "messages_chat_room_id_fkey"
  add_foreign_key "messages", "users", column: "sender_id", name: "messages_sender_id_fkey"
  add_foreign_key "plans", "users", name: "plans_user_id_fkey"
end
