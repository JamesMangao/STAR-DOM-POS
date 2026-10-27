// scripts/change-owner.js — Update or create the owner account in Supabase.
//
// Usage:
//   node scripts/change-owner.js
//
// Reads OWNER_EMAIL and OWNER_PASSWORD from .env, updates the auth user in Supabase,
// confirms the email, and links it to the store.
'use strict';

const { createClient } = require('@supabase/supabase-js');
const env = require('./env');
const { writeClient } = require('./pg');

async function main() {
  const e = env.load();
  if (!e.OWNER_EMAIL || !e.OWNER_PASSWORD) {
    console.error('Error: OWNER_EMAIL and OWNER_PASSWORD must be set in .env');
    process.exit(1);
  }

  console.log('=== Update Owner Email / Account ===');
  console.log('Target Email:', e.OWNER_EMAIL);

  const supabaseAdmin = createClient(e.SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const list = await supabaseAdmin.auth.admin.listUsers();
  const users = list.data?.users || [];
  let user = users.find((u) => u.email === e.OWNER_EMAIL);

  if (user) {
    // User already exists, update password and ensure confirmed
    const updated = await supabaseAdmin.auth.admin.updateUserById(user.id, {
      password: e.OWNER_PASSWORD,
      email_confirm: true,
    });
    if (updated.error) throw new Error(updated.error.message);
    console.log('✅ User already exists. Password & confirmation updated for:', e.OWNER_EMAIL);
  } else if (users.length === 1) {
    // Only 1 owner user exists in the project; update their email & password directly
    const oldUser = users[0];
    console.log(`Changing owner from ${oldUser.email} -> ${e.OWNER_EMAIL} (id: ${oldUser.id})`);
    const updated = await supabaseAdmin.auth.admin.updateUserById(oldUser.id, {
      email: e.OWNER_EMAIL,
      password: e.OWNER_PASSWORD,
      email_confirm: true,
    });
    if (updated.error) throw new Error(updated.error.message);
    user = updated.data.user;
    console.log('✅ Email and password updated in Supabase Auth!');
  } else {
    // Create new owner user
    const created = await supabaseAdmin.auth.admin.createUser({
      email: e.OWNER_EMAIL,
      password: e.OWNER_PASSWORD,
      email_confirm: true,
    });
    if (created.error) throw new Error(created.error.message);
    user = created.data.user;
    console.log('✅ Created new owner user in Supabase Auth:', e.OWNER_EMAIL);
  }

  // Update store row if stores table exists
  try {
    const { client, close } = await writeClient();
    const hasStores = (await client.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'stores'"
    )).rows.length > 0;

    if (hasStores && user) {
      await client.query('UPDATE stores SET owner_id = $1', [user.id]);
      console.log('✅ Store owner_id updated to user:', user.id);
    }
    await close();
  } catch (err) {
    // Non-fatal if stores table not migrated yet
    console.log('Note: stores table not updated (may need import.js):', err.message);
  }

  console.log('\n🎉 Success! You can now log into the app with:');
  console.log('Email:', e.OWNER_EMAIL);
  console.log('Password: (the password from .env)');
}

main().catch((err) => {
  console.error('Failed to change owner:', err.message);
  process.exit(1);
});
