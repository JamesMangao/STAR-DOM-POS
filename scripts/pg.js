// scripts/pg.js — Postgres connections for the POS scripts.
//
// READ-ONLY is enforced twice for the read paths:
//   1. `SET default_transaction_read_only = on` for the session, and
//   2. `BEGIN READ ONLY` around the work.
// Any write on that connection is rejected by the server, not by our code.
// The DSN comes only from scripts/env.js (POS .env).
'use strict';

const { Client } = require('pg');
const env = require('./env');

function requireDsn() {
  const dsn = env.requireKeys(['SUPABASE_DB_URL']).SUPABASE_DB_URL;
  // Shape-validate BEFORE any network/DB call; message contains no value.
  const problem = env.dbUrlProblem(dsn);
  if (problem) {
    throw new Error(`SUPABASE_DB_URL: ${problem}`);
  }
  return dsn;
}

/** A connection on which every write is a server-side error. */
async function readOnlyClient() {
  const c = new Client({ connectionString: requireDsn() });
  await c.connect();
  await c.query('SET default_transaction_read_only = on');
  await c.query('BEGIN READ ONLY');
  return {
    client: c,
    async close() {
      await c.query('ROLLBACK');
      await c.end();
    },
  };
}

/** A write-capable connection (reset.js --execute and import.js only). */
async function writeClient() {
  const c = new Client({ connectionString: requireDsn() });
  await c.connect();
  return { client: c, close: () => c.end() };
}

/** A writable connection's host label (hostname only; never user/password). */
function hostLabel() {
  const dsn = requireDsn();
  try {
    return new URL(dsn).hostname;
  } catch {
    return 'unknown-host';
  }
}

/** True when the DSN host or username names the STAR:DOM project. */
function assertProjectRef(ref) {
  const dsn = requireDsn();
  let host;
  let username = '';
  try {
    const u = new URL(dsn);
    host = u.host;
    username = u.username;
  } catch {
    host = dsn;
  }
  if (!host.includes(ref) && !username.includes(ref) && !dsn.includes(ref)) {
    throw new Error(
      `SUPABASE_DB_URL host or username does not contain "${ref}" — refusing to continue.`,
    );
  }
  return host;
}

module.exports = { readOnlyClient, writeClient, assertProjectRef, requireDsn, hostLabel };
