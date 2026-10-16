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
  const scheme = String(dsn).split('://')[0].toLowerCase();
  if (scheme !== 'postgres' && scheme !== 'postgresql') {
    // Never echo the value — only the (non-secret) scheme.
    throw new Error(
      `SUPABASE_DB_URL is not a Postgres connection string (scheme "${scheme || 'none'}"). ` +
        'Use the Supabase Session-pooler URI (postgresql://...), not the https API URL.',
    );
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

/** True when the DSN host names the STAR:DOM project. */
function assertProjectRef(ref) {
  const dsn = requireDsn();
  let host;
  try {
    host = new URL(dsn).host;
  } catch {
    host = dsn;
  }
  if (!host.includes(ref)) {
    throw new Error(
      `SUPABASE_DB_URL host does not contain "${ref}" — refusing to continue.`,
    );
  }
  return host;
}

module.exports = { readOnlyClient, writeClient, assertProjectRef, requireDsn };
