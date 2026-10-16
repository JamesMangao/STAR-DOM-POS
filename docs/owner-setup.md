# STAR:DOM POS — owner set-up and booth procedure

**Print this page and keep it with the iPad.** No code, no terminal.

---

## Part 1 — Install the app (once)

1. Open **Safari** on the iPad (Chrome or Firefox cannot install a Home-Screen app).
2. Type the app address into the address bar and let it load fully.
3. Tap the **Share** button (square with the up arrow) → **Add to Home Screen** → **Add**.
4. **Close Safari completely.** Open the app **from the new icon** on the Home Screen. It must
   open without the address bar; that is what "standalone" means.
5. Sign in **once, inside the installed app**: owner email + password → **Sign in**.
   - You will not have to do this again. The session refreshes by itself.
   - If you skip this, the app still sells, but nothing syncs: you will see the
     **"Sign in to sync"** button instead of **Synced**.
6. Wait until the status chip in the top-right says **Synced**.

## Part 2 — iPad settings for the booth

7. **Settings → Display & Brightness → Auto-Lock → Never.**
8. **Settings → Battery → Low Power Mode → OFF.** Keep the iPad **on the charger** at the booth.
9. **Settings → Accessibility → Guided Access → ON**, set a passcode.
   At the booth: open the app, then **triple-click the side button** → **Guided Access → Start**.
   This locks the iPad into the POS so nothing else can be tapped. Triple-click + passcode ends it.
10. **Wi-Fi:** connect to the booth hotspot if there is one. The app works fully offline; Wi-Fi
    only decides *when* data syncs.

## Part 3 — Before you open (every booth day)

11. **Airplane Mode test** (do this once before go-live, then repeat if anything feels wrong):
    turn Airplane Mode ON, open the app, and confirm it opens and shows the sales screen and the
    orange **Offline** chip. Turn Airplane Mode OFF. That is the booth's worst case, and the app
    must survive it.
12. Check the chip says **Synced** (or **Offline · N** with a small N) before you start selling.

## Part 4 — During the booth

13. Selling never needs the internet. Sales are stored on the iPad first and uploaded later.
14. If the **red banner "Unsynced sales on this device…"** appears, connect to the internet and tap
    **Sync now**. Do not ignore it for a full day.
15. **Never delete the app icon** and **never clear website data** while there are unsynced sales.
    Deleting the icon deletes the sales that have not been uploaded yet.

## Part 5 — Keeping it healthy

16. **Open the app online at least every few days.** A free Supabase project pauses after 7 days
    without activity; data is kept and it resumes from the dashboard, but the iPad cannot sync
    until it does.
17. **Settings → Export data (JSON)** once a month, and keep the file somewhere safe (Files, email
    to yourself). This is your own copy of every sale on the device.
18. When you update the app (a new upload by the developer): open the app once while online. The
    new version loads the next time you open it.

## Part 6 — If something looks wrong

| What you see | What to do |
|---|---|
| Orange **Offline · N** chip | Normal without Wi-Fi. Sales keep working. Sync when you have a connection. |
| Red **Failed · N** chip | Tap **Sync now**. If it stays red for more than a day, contact the developer. |
| **Sign in to sync** button | Session expired. Tap it and sign in again. Selling still works. |
| Red unsynced-sales banner | Connect to the internet, tap **Sync now**, and do not delete the icon. |
| App will not open offline | Open it once while online so the update completes, then retest Airplane Mode. |
| Numbers look duplicated | Do not touch anything; report it. Sync is designed never to duplicate a sale. |
