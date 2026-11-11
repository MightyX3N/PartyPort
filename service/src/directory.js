import { DurableObject } from "cloudflare:workers";

/**
 * Global lookup from invite code to party. Party objects register and
 * remove their codes here; the Worker looks codes up when someone joins.
 */
export class Directory extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec("CREATE TABLE IF NOT EXISTS invites (code TEXT PRIMARY KEY, party_id TEXT NOT NULL)");
    this.sql.exec("CREATE INDEX IF NOT EXISTS invites_party ON invites(party_id)");
  }

  /** Reserve a code for a party. Returns false if the code is already taken. */
  claim(code, partyId) {
    const taken = this.sql.exec("SELECT 1 FROM invites WHERE code = ?", code).toArray().length > 0;
    if (taken) return false;
    this.sql.exec("INSERT INTO invites (code, party_id) VALUES (?, ?)", code, partyId);
    return true;
  }

  lookup(code) {
    const row = this.sql.exec("SELECT party_id FROM invites WHERE code = ?", code).toArray()[0];
    return row ? row.party_id : null;
  }

  release(code) {
    this.sql.exec("DELETE FROM invites WHERE code = ?", code);
  }

  releaseParty(partyId) {
    this.sql.exec("DELETE FROM invites WHERE party_id = ?", partyId);
  }
}
