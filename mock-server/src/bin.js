import { DurableObject } from "cloudflare:workers";

// One Durable Object instance per bin name. Holds that bin's captured
// requests in its own SQLite database, newest-N capped and time-expired.
export class Bin extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.ensureSchema();
  }

  ensureSchema() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS requests (
        seq         INTEGER PRIMARY KEY AUTOINCREMENT,
        id          TEXT NOT NULL,
        received_at INTEGER NOT NULL,
        entry       TEXT NOT NULL
      )
    `);
  }

  async record(entry) {
    const max = Number(this.env.MAX_REQUESTS_PER_BIN) || 200;
    this.sql.exec(
      "INSERT INTO requests (id, received_at, entry) VALUES (?, ?, ?)",
      entry.id,
      entry.receivedAt,
      JSON.stringify(entry),
    );
    this.sql.exec(
      "DELETE FROM requests WHERE seq NOT IN (SELECT seq FROM requests ORDER BY seq DESC LIMIT ?)",
      max,
    );
    if ((await this.ctx.storage.getAlarm()) === null) {
      await this.ctx.storage.setAlarm(Date.now() + this.retentionMs());
    }
  }

  // Newest first. `since` returns only entries received after that seq, for polling.
  list(limit = 50, since = 0) {
    const rows = this.sql
      .exec(
        "SELECT seq, entry FROM requests WHERE seq > ? ORDER BY seq DESC LIMIT ?",
        since,
        Math.min(limit, 500),
      )
      .toArray();
    return rows.map((r) => ({ seq: r.seq, ...JSON.parse(r.entry) }));
  }

  get(id) {
    const row = this.sql.exec("SELECT seq, entry FROM requests WHERE id = ?", id).toArray()[0];
    return row ? { seq: row.seq, ...JSON.parse(row.entry) } : null;
  }

  async clear() {
    this.sql.exec("DELETE FROM requests");
    await this.ctx.storage.deleteAlarm();
  }

  async alarm() {
    this.sql.exec("DELETE FROM requests WHERE received_at < ?", Date.now() - this.retentionMs());
    const oldest = this.sql.exec("SELECT MIN(received_at) AS t FROM requests").one().t;
    if (oldest !== null) {
      await this.ctx.storage.setAlarm(oldest + this.retentionMs());
    } else {
      // Nothing left: drop all storage so idle bins cost nothing.
      await this.ctx.storage.deleteAll();
      this.ensureSchema();
    }
  }

  retentionMs() {
    return (Number(this.env.RETENTION_HOURS) || 72) * 3600 * 1000;
  }
}
