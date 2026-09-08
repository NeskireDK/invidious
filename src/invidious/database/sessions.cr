require "./base.cr"

module Invidious::Database::SessionIDs
  extend self

  # -------------------
  #  Insert
  # -------------------

  def insert(sid : String, email : String, handle_conflicts : Bool = false)
    request = <<-SQL
      INSERT INTO session_ids
      VALUES ($1, $2, now())
    SQL

    request += " ON CONFLICT (id) DO NOTHING" if handle_conflicts

    PG_DB.exec(request, sid, email)
  end

  # -------------------
  #  Delete
  # -------------------

  def delete(*, sid : String)
    request = <<-SQL
      DELETE FROM session_ids *
      WHERE id = $1
    SQL

    PG_DB.exec(request, sid)
  end

  def delete(*, email : String)
    request = <<-SQL
      DELETE FROM session_ids *
      WHERE email = $1
    SQL

    PG_DB.exec(request, email)
  end

  def delete(*, sid : String, email : String)
    request = <<-SQL
      DELETE FROM session_ids *
      WHERE id = $1 AND email = $2
    SQL

    PG_DB.exec(request, sid, email)
  end

  # Sessions issued before `issued_before`, and the number removed.
  def delete_expired(issued_before : Time) : Int64
    request = <<-SQL
      DELETE FROM session_ids *
      WHERE issued < $1
    SQL

    PG_DB.exec(request, issued_before).rows_affected
  end

  # -------------------
  #  Select
  # -------------------

  def select_email(sid : String) : String?
    request = <<-SQL
      SELECT email FROM session_ids
      WHERE id = $1
    SQL

    PG_DB.query_one?(request, sid, as: String)
  end

  def select_all(email : String) : Array({session: String, issued: Time})
    request = <<-SQL
      SELECT id, issued FROM session_ids
      WHERE email = $1
      ORDER BY issued DESC
    SQL

    PG_DB.query_all(request, email, as: {session: String, issued: Time})
  end
end
