// scripts/env.test.js — validator tests. FAKE values only; never reads .env.
//   node --test scripts/env.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { validate, dbUrlProblem, PROJECT_REF } = require('./env');

const valid = () => ({
  SUPABASE_URL: `https://${PROJECT_REF}.supabase.co`,
  SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE_ANON',
  SUPABASE_SERVICE_ROLE_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE_SERVICE',
  SUPABASE_DB_URL:
    `postgresql://postgres.${PROJECT_REF}:fake-password@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres`,
  OWNER_EMAIL: 'owner@example.com',
  OWNER_PASSWORD: 'x'.repeat(16),
});

const keys = (problems) => problems.map(([k]) => k);

test('valid shapes -> no problems', () => {
  assert.deepEqual(validate(valid()), []);
});

test('https:// DB URL is rejected', () => {
  const p = validate({ ...valid(), SUPABASE_DB_URL: `https://${PROJECT_REF}.supabase.co` });
  assert.ok(keys(p).includes('SUPABASE_DB_URL'));
  assert.match(p.find(([k]) => k === 'SUPABASE_DB_URL')[1], /not a Postgres DSN/);
});

test('wrong ref in DB user is rejected', () => {
  const p = validate({
    ...valid(),
    SUPABASE_DB_URL: 'postgresql://postgres.otherref:pw@h.pooler.supabase.com:5432/postgres',
  });
  assert.ok(keys(p).includes('SUPABASE_DB_URL'));
});

test('non-pooler host is rejected', () => {
  const p = validate({
    ...valid(),
    SUPABASE_DB_URL: `postgresql://postgres.${PROJECT_REF}:pw@db.${PROJECT_REF}.supabase.co:5432/postgres`,
  });
  assert.ok(keys(p).includes('SUPABASE_DB_URL'));
});

test('port 6543 is rejected', () => {
  const p = validate({
    ...valid(),
    SUPABASE_DB_URL: `postgresql://postgres.${PROJECT_REF}:pw@h.pooler.supabase.com:6543/postgres`,
  });
  assert.match(p.find(([k]) => k === 'SUPABASE_DB_URL')[1], /6543/);
});

test('empty anon key is rejected', () => {
  const p = validate({ ...valid(), SUPABASE_ANON_KEY: '' });
  assert.ok(keys(p).includes('SUPABASE_ANON_KEY'));
});

test('identical anon and service keys are rejected', () => {
  const p = validate({
    ...valid(),
    SUPABASE_ANON_KEY: 'same',
    SUPABASE_SERVICE_ROLE_KEY: 'same',
  });
  assert.ok(
    keys(p).includes('SUPABASE_ANON_KEY/SUPABASE_SERVICE_ROLE_KEY'),
  );
});

test('whitespace in a key is rejected', () => {
  const p = validate({ ...valid(), SUPABASE_ANON_KEY: 'has space' });
  assert.match(p.find(([k]) => k === 'SUPABASE_ANON_KEY')[1], /whitespace/);
});

test('short owner password is rejected', () => {
  const p = validate({ ...valid(), OWNER_PASSWORD: 'short' });
  assert.ok(keys(p).includes('OWNER_PASSWORD'));
});

test('invalid owner email is rejected', () => {
  const p = validate({ ...valid(), OWNER_EMAIL: 'not-an-email' });
  assert.ok(keys(p).includes('OWNER_EMAIL'));
});

test('missing keys are all reported', () => {
  const p = validate({});
  assert.equal(p.length, 6);
});

test('dbUrlProblem returns null for a good DSN', () => {
  assert.equal(dbUrlProblem(valid().SUPABASE_DB_URL), null);
});
