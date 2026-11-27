# Defusal

A mobile-style bomb-defusal game with 150 levels across 11 worlds, plus a Daily bomb (one shared device per day with its own fastest-time board). Play it at https://wolfeckel.github.io/defusal/

The whole game is in `index.html`: inline CSS and JS, with every sound synthesised by Web Audio (no audio files). External services: Google Fonts, and optionally Supabase for the online leaderboard.

## Development

```sh
npm install
npm run dev     # serves at http://localhost:5173 and reloads when you save
```

You can also just open `index.html` in a browser. Every push to `main` updates the live site through GitHub Pages.

## Online leaderboard (Supabase)

The leaderboard stays hidden until it's connected:

1. Create a free project at https://supabase.com.
2. In the project, open **SQL Editor → New query**, paste in `supabase/leaderboard.sql`, and press **Run**.
3. Open **Project Settings → API** and copy the **Project URL** and the **publishable** (or `anon` public) key.
4. Put them in `index.html` where it says `const LB={url:'',key:''};`.

The leaderboard has two tabs: **Overall** (levels cleared, then stars, then total time) and **Fastest** (each level's best times; mistakes add their penalty to the time). The SQL file is safe to run again after updates: it keeps existing scores and only adds what's missing.

The key is meant to be public: it can only call the functions in the SQL file, which validate scores and only ever keep a player's best. Players can't read or edit the tables directly. Free Supabase projects pause after a week without visits; open the dashboard to wake one up.

## History

Earlier iterations are in git history (`git log -- index.html`).
