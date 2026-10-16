// scripts/readonly-proof.js — prove the read paths cannot write.
//
//   node scripts/readonly-proof.js
//
// Connects with scripts/pg.js readOnlyClient() (SET default_transaction_read_only
// = on + BEGIN READ ONLY) and checks:
//   1. SHOW transaction_read_only          -> must be 'on'
//   2. CREATE TEMP TABLE …                 -> must be REJECTED by the server
//   3. INSERT INTO a real table            -> must be REJECTED by the server
// Prints no credential values.
'use strict';

const { readOnlyClient } = require('./pg');

// Each check gets its own connection so one failure cannot abort the next
// check's transaction (25P02 would otherwise mask the real read-only error).
async function attempt(label, sql) {
  const { client, close } = await readOnlyClient();
  try {
    const res = await client.query(sql);
    return { label, ok: false, row: res.rows[0] };
  } catch (e) {
    return { label, ok: true, code: e.code, message: e.message };
  } finally {
    await close();
  }
}

async function main() {
  let failures = 0;

  const { client, close } = await readOnlyClient();
  try {
    const ro = await client.query('show transaction_read_only');
    const on = ro.rows[0].transaction_read_only === 'on';
    console.log(`SHOW transaction_read_only    = '${ro.rows[0].transaction_read_only}'  ${on ? 'OK' : 'FAIL'}`);
    if (!on) failures++;
  } finally {
    await close();
  }

  const checks = [
    ['CREATE TEMP TABLE             ', 'create temp table readonly_proof (x int)'],
    [
      'INSERT INTO public.categories ',
      `insert into public.categories (id, name) select -1, 'readonly_probe'`,
    ],
    [
      'UPDATE public.categories      ',
      `update public.categories set name = name where id = -1`,
    ],
    ['DELETE FROM public.categories ', `delete from public.categories where id = -1`],
  ];
  for (const [label, sql] of checks) {
    const r = await attempt(label, sql);
    if (r.ok) {
      console.log(`${r.label}= rejected OK (${r.code} ${r.message})`);
    } else {
      console.log(`${r.label}= ALLOWED  FAIL`);
      failures++;
    }
  }

  console.log(failures === 0 ? '\nread-only enforcement: PROVEN' : `\nread-only enforcement: ${failures} FAILURE(S)`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('proof failed to run:', e.message);
  process.exit(2);
});
