class Invidious::Jobs::ClearExpiredItemsJob < Invidious::Jobs::BaseJob
  # Remove items (videos, nonces, sessions) whose cache is outdated every hour.
  # Removes the need for a cron job.
  def begin
    loop do
      failed = false

      LOGGER.info("jobs: running ClearExpiredItems job")

      begin
        Invidious::Database::Videos.delete_expired
        Invidious::Database::Nonces.delete_expired

        revoked = Invidious::Database::SessionIDs.delete_expired(session_cutoff)
        LOGGER.info("jobs: ClearExpiredItems revoked #{revoked} aged session(s)") if revoked > 0
      rescue DB::Error
        failed = true
      end

      # Retry earlier than scheduled on DB error
      if failed
        LOGGER.info("jobs: ClearExpiredItems failed. Retrying in 10 minutes.")
        sleep 10.minutes
      else
        LOGGER.info("jobs: ClearExpiredItems done.")
        sleep 1.hour
      end
    end
  end

  # session_ids has no last-seen column — `issued` is an issue date — so the
  # SID cookie's own lifetime is the only retention this table can express
  # without revoking a session that is in daily use. A shorter cap would log
  # out a browser holding a valid cookie, and would revoke the API tokens
  # Materialious and Yattee keep in the same table. Reaching further back needs
  # a last_seen column, and that means a write on every authenticated request.
  private def session_cutoff : Time
    Time.utc - Invidious::User::Cookies::SID_LIFETIME
  end
end
