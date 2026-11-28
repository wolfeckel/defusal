-- ==================== START: copy everything from this line ====================
-- Defusal online leaderboard. Run this in Supabase → SQL Editor → New query → Run.
-- Safe to run again: it keeps existing scores and only adds or updates what's needed.
-- The game's public key can only call the functions below; the tables themselves stay locked.
-- The main game has 300 levels (900 stars). Hard Mode isn't on the leaderboard.

-- ── Saves and linked devices (created first: the leaderboard functions below read player_links) ──
-- players: each player's progress backed up online, protected by a 4-digit code used with their name.
create table if not exists public.players (
  player_id  uuid primary key,
  name       text  not null check (char_length(name) between 1 and 20),
  pin        text  not null check (pin ~ '^[0-9]{4}$'),
  progress   jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.players enable row level security;        -- no policies: no direct reads or writes
-- player_links: an old device ID now playing as another player. Nothing is deleted; the old ID's
-- leaderboard rows are just left out of the boards.
create table if not exists public.player_links (
  old_id    uuid primary key,
  new_id    uuid not null,
  linked_at timestamptz not null default now()
);
alter table public.player_links enable row level security;   -- no policies: no direct reads or writes

-- ── Overall board: levels cleared, stars, and total time ─────────────────────
create table if not exists public.scores (
  player_id  uuid primary key,
  name       text not null check (char_length(name) between 1 and 20),
  levels     int  not null default 0,
  stars      int  not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.scores add column if not exists total_ms bigint check (total_ms >= 0);
-- level and star limits follow the number of levels in the game
alter table public.scores drop constraint if exists scores_levels_check;
alter table public.scores add  constraint scores_levels_check check (levels between 0 and 300);
alter table public.scores drop constraint if exists scores_stars_check;
alter table public.scores add  constraint scores_stars_check  check (stars between 0 and 900);
alter table public.scores enable row level security;   -- no policies: no direct reads or writes

-- a player's name, as the database knows it. Names change only through rename_player; scores, times and
-- saves sent by a device never overwrite a name that's already stored (new players use the name they send).
create or replace function public.player_name(p_id uuid, p_name text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select p.name from players p where p.player_id = p_id),
                  (select s.name from scores s where s.player_id = p_id),
                  left(trim(p_name), 20));
$$;

-- save a player's totals; levels and stars only ever go up.
-- total_ms is the sum of the player's best time on every level they've cleared (mistakes included)
create or replace function public.submit_score(p_id uuid, p_name text, p_levels int, p_stars int, p_total_ms bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_levels < 1 or p_levels > 300 or p_stars < p_levels or p_stars > p_levels * 3
     or p_total_ms < p_levels * 1000 or p_total_ms > p_levels * 300000 then
    raise exception 'invalid score';
  end if;
  insert into scores (player_id, name, levels, stars, total_ms)
  values (p_id, public.player_name(p_id, p_name), p_levels, p_stars, p_total_ms)
  on conflict (player_id) do update set
    name       = scores.name,                 -- names change only through rename_player
    levels     = greatest(scores.levels, excluded.levels),
    stars      = greatest(scores.stars,  excluded.stars),
    -- take the new total only when it comes with at least as much progress
    total_ms   = case when excluded.levels >= scores.levels and excluded.stars >= scores.stars
                      then excluded.total_ms else scores.total_ms end,
    updated_at = case when excluded.levels > scores.levels or excluded.stars > scores.stars
                      then now() else scores.updated_at end;
end $$;

-- older game pages send no time; keep accepting them
create or replace function public.submit_score(p_id uuid, p_name text, p_levels int, p_stars int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_levels < 1 or p_levels > 300 or p_stars < p_levels or p_stars > p_levels * 3 then
    raise exception 'invalid score';
  end if;
  insert into scores (player_id, name, levels, stars)
  values (p_id, public.player_name(p_id, p_name), p_levels, p_stars)
  on conflict (player_id) do update set
    name       = scores.name,                 -- names change only through rename_player
    levels     = greatest(scores.levels, excluded.levels),
    stars      = greatest(scores.stars,  excluded.stars),
    updated_at = case when excluded.levels > scores.levels or excluded.stars > scores.stars
                      then now() else scores.updated_at end;
end $$;

-- the top n players: most levels, then most stars, then fastest total time, then whoever got there first
drop function if exists public.top_scores(int);
create function public.top_scores(n int default 50)
returns table (pos bigint, name text, levels int, stars int, total_ms bigint)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by s.levels desc, s.stars desc, s.total_ms asc nulls last, s.updated_at asc),
         s.name, s.levels, s.stars, s.total_ms
  from scores s
  where s.player_id not in (select old_id from player_links)
  order by 1
  limit least(greatest(n, 1), 100);
$$;

-- one player's position on the overall board
create or replace function public.my_rank(p_id uuid)
returns bigint language sql stable security definer set search_path = public as $$
  select t.r from (
    select s.player_id,
           row_number() over (order by s.levels desc, s.stars desc, s.total_ms asc nulls last, s.updated_at asc) as r
    from scores s
    where s.player_id not in (select old_id from player_links)
  ) t where t.player_id = p_id;
$$;

-- ── Per-level speed records ──────────────────────────────────────────────────
create table if not exists public.level_times (
  player_id uuid not null,
  level     int  not null,
  name      text not null check (char_length(name) between 1 and 20),
  ms        int  not null check (ms between 1000 and 300000),
  set_at    timestamptz not null default now(),
  primary key (player_id, level)
);
alter table public.level_times drop constraint if exists level_times_level_check;
alter table public.level_times add  constraint level_times_level_check check (level between 1 and 300);
alter table public.level_times enable row level security;   -- no policies: no direct reads or writes

-- save a time; only ever keeps the player's fastest
create or replace function public.submit_time(p_id uuid, p_name text, p_level int, p_ms int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_level < 1 or p_level > 300 or p_ms < 1000 or p_ms > 300000 then
    raise exception 'invalid time';
  end if;
  insert into level_times (player_id, level, name, ms)
  values (p_id, p_level, public.player_name(p_id, p_name), p_ms)
  on conflict (player_id, level) do update set
    name   = level_times.name,
    ms     = least(level_times.ms, excluded.ms),
    set_at = case when excluded.ms < level_times.ms then now() else level_times.set_at end;
end $$;

-- the fastest n times on one level (ties go to whoever set it first)
create or replace function public.top_times(p_level int, n int default 10)
returns table (pos bigint, name text, ms int)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by t.ms asc, t.set_at asc), t.name, t.ms
  from level_times t
  where t.level = p_level and t.player_id not in (select old_id from player_links)
  order by 1
  limit least(greatest(n, 1), 50);
$$;

-- one player's time and position on one level
create or replace function public.my_time(p_id uuid, p_level int)
returns table (pos bigint, ms int)
language sql stable security definer set search_path = public as $$
  select x.r, x.ms from (
    select t.player_id, t.ms, row_number() over (order by t.ms asc, t.set_at asc) as r
    from level_times t where t.level = p_level and t.player_id not in (select old_id from player_links)
  ) x where x.player_id = p_id;
$$;

-- ── Daily bomb: one shared device per day, fastest time wins ─────────────────
create table if not exists public.daily_times (
  player_id uuid not null,
  day       date not null,
  name      text not null check (char_length(name) between 1 and 20),
  ms        int  not null check (ms between 1000 and 300000),
  set_at    timestamptz not null default now(),
  primary key (player_id, day)
);
alter table public.daily_times enable row level security;   -- no policies: no direct reads or writes

-- save a daily time; only today's bomb (± a day for time zones), only the fastest is kept
create or replace function public.submit_daily(p_id uuid, p_name text, p_day date, p_ms int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_day < current_date - 1 or p_day > current_date + 1 or p_ms < 1000 or p_ms > 300000 then
    raise exception 'invalid daily time';
  end if;
  insert into daily_times (player_id, day, name, ms)
  values (p_id, p_day, public.player_name(p_id, p_name), p_ms)
  on conflict (player_id, day) do update set
    name   = daily_times.name,
    ms     = least(daily_times.ms, excluded.ms),
    set_at = case when excluded.ms < daily_times.ms then now() else daily_times.set_at end;
end $$;

-- the fastest n times for one day
create or replace function public.top_daily(p_day date, n int default 10)
returns table (pos bigint, name text, ms int)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by t.ms asc, t.set_at asc), t.name, t.ms
  from daily_times t
  where t.day = p_day and t.player_id not in (select old_id from player_links)
  order by 1
  limit least(greatest(n, 1), 50);
$$;

-- one player's time and position for one day
create or replace function public.my_daily(p_id uuid, p_day date)
returns table (pos bigint, ms int)
language sql stable security definer set search_path = public as $$
  select x.r, x.ms from (
    select t.player_id, t.ms, row_number() over (order by t.ms asc, t.set_at asc) as r
    from daily_times t where t.day = p_day and t.player_id not in (select old_id from player_links)
  ) x where x.player_id = p_id;
$$;

-- ── Saves: progress = {"unlocked": n, "best": {"<level index>": {"s": stars, "t": secs left, "ms": time}}} ──
-- merging two saves keeps the better of each: most stars, most time left, fastest time; progress only goes up
create or replace function public.better_level(a jsonb, b jsonb)
returns jsonb language sql immutable as $$
  select case when a is null then b when b is null then a else jsonb_strip_nulls(jsonb_build_object(
    's',  greatest(coalesce((a->>'s')::int, 0), coalesce((b->>'s')::int, 0)),
    't',  greatest(coalesce((a->>'t')::int, 0), coalesce((b->>'t')::int, 0)),
    'ms', nullif(least(coalesce((a->>'ms')::int, 2147483647), coalesce((b->>'ms')::int, 2147483647)), 2147483647)
  )) end;
$$;
create or replace function public.merge_progress(a jsonb, b jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'unlocked', greatest(coalesce((a->>'unlocked')::int, 0), coalesce((b->>'unlocked')::int, 0)),
    'best', coalesce((
      select jsonb_object_agg(k, public.better_level(a->'best'->k, b->'best'->k))
      from (select jsonb_object_keys(coalesce(a->'best', '{}'::jsonb)) as k
            union select jsonb_object_keys(coalesce(b->'best', '{}'::jsonb))) ks
    ), '{}'::jsonb));
$$;

-- back up a player's progress (merged with what's already saved). The first save sets their code.
create or replace function public.save_progress(p_id uuid, p_name text, p_pin text, p_progress jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare cur public.players;
begin
  if p_pin !~ '^[0-9]{4}$' or jsonb_typeof(p_progress) <> 'object' or pg_column_size(p_progress) > 60000 then
    raise exception 'invalid save';
  end if;
  select * into cur from players where player_id = p_id;
  if not found then
    -- name + code must point to one player, so a code already used with this name can't be reused
    if exists (select 1 from players where lower(name) = lower(trim(p_name)) and pin = p_pin) then
      raise exception 'pin taken';
    end if;
    insert into players (player_id, name, pin, progress)
    values (p_id, public.player_name(p_id, p_name), p_pin, merge_progress('{}'::jsonb, p_progress));
  elsif cur.pin <> p_pin then
    raise exception 'wrong pin';
  else
    update players set progress = merge_progress(cur.progress, p_progress), updated_at = now()
    where player_id = p_id;
  end if;
end $$;

-- read a player's saved progress (needs their code); "_name" tells the device its current name
create or replace function public.load_progress(p_id uuid, p_pin text)
returns jsonb language sql stable security definer set search_path = public as $$
  select p.progress || jsonb_build_object('_name', p.name) from players p where p.player_id = p_id and p.pin = p_pin;
$$;

-- rename a player everywhere (needs their code); a name another player uses is refused
create or replace function public.rename_player(p_id uuid, p_pin text, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare n text := left(trim(p_name), 20);
begin
  if char_length(n) < 1 then raise exception 'invalid name'; end if;
  if not exists (select 1 from players where player_id = p_id and pin = p_pin) then raise exception 'wrong pin'; end if;
  if exists (select 1 from players where lower(name) = lower(n) and player_id <> p_id) then raise exception 'name taken'; end if;
  update players     set name = n, updated_at = now() where player_id = p_id;
  update scores      set name = n where player_id = p_id;
  update level_times set name = n where player_id = p_id;
  update daily_times set name = n where player_id = p_id;
end $$;

-- play as an existing player on this device: name + code. The device's own old ID (if any) is linked,
-- so its separate leaderboard rows stop showing; they are kept, not deleted.
create or replace function public.claim_player(p_name text, p_pin text, p_old_id uuid default null)
returns table (out_id uuid, out_progress jsonb)
language plpgsql security definer set search_path = public as $$
declare r public.players;
begin
  select * into r from players p
  where lower(p.name) = lower(trim(p_name)) and p.pin = p_pin and p.player_id not in (select old_id from player_links)
  order by coalesce((p.progress->>'unlocked')::int, 0) desc, p.updated_at desc limit 1;
  if not found then raise exception 'no match'; end if;
  if p_old_id is not null and p_old_id <> r.player_id then
    insert into player_links (old_id, new_id) values (p_old_id, r.player_id)
    on conflict (old_id) do update set new_id = excluded.new_id, linked_at = now();
  end if;
  return query select r.player_id, r.progress;
end $$;

-- is this name already used by a player with an online save? (the game then asks for that player's code)
create or replace function public.name_taken(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from players p where lower(p.name) = lower(trim(p_name)));
$$;
-- is this name already someone else's on the board or in the saves? (ignores the asking device's own player,
-- and players linked into another). The game then asks for that player's code.
create or replace function public.name_taken(p_name text, p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from players p where lower(p.name) = lower(trim(p_name)) and p.player_id is distinct from p_id
                   and p.player_id not in (select old_id from player_links))
      or exists (select 1 from scores s where lower(s.name) = lower(trim(p_name)) and s.player_id is distinct from p_id
                   and s.player_id not in (select old_id from player_links));
$$;

-- log in by name: your name is your player. Finds the player with that name (most progress wins), builds an
-- online save from the leaderboard if they never had one, and links this device's own player for that name
-- (e.g. an empty one made by mistake) to it. Nothing is deleted. Returns no rows for a brand-new name.
create or replace function public.login_player(p_name text, p_old_id uuid default null)
returns table (out_id uuid, out_pin text, out_progress jsonb)
language plpgsql security definer set search_path = public as $$
declare sid uuid; r public.players; n text := lower(trim(p_name));
begin
  with c as (
    select p.player_id from players p where lower(p.name) = n
    union select s.player_id from scores s where lower(s.name) = n)
  select c.player_id into sid
  from c left join scores s on s.player_id = c.player_id left join players p on p.player_id = c.player_id
  where c.player_id not in (select old_id from player_links)
  order by greatest(coalesce(s.levels, 0), coalesce((p.progress->>'unlocked')::int, 0)) desc,
           coalesce(s.stars, 0) desc, coalesce(p.updated_at, s.updated_at) desc nulls last
  limit 1;
  if sid is null then return; end if;
  -- an old player with no online save yet: build one from their leaderboard times (all reached levels unlocked)
  insert into players (player_id, name, pin, progress)
  select s.player_id, s.name, lpad(floor(random() * 10000)::int::text, 4, '0'),
    jsonb_build_object(
      'unlocked', least(299, coalesce((select max(t.level) from level_times t where t.player_id = s.player_id), s.levels)),
      'best', coalesce((select jsonb_object_agg((t.level - 1)::text, jsonb_build_object('s', 1, 'ms', t.ms))
                        from level_times t where t.player_id = s.player_id), '{}'::jsonb))
  from scores s where s.player_id = sid
  on conflict (player_id) do nothing;
  select * into r from players where player_id = sid;
  if not found then return; end if;
  if p_old_id is not null and p_old_id <> sid then
    insert into player_links (old_id, new_id) values (p_old_id, sid)
    on conflict (old_id) do update set new_id = excluded.new_id, linked_at = now();
  end if;
  return query select r.player_id, r.pin, r.progress || jsonb_build_object('_name', r.name);
end $$;

-- ── Access: the public key may call these functions and nothing else ─────────
-- logging in by name alone is switched off: a name on the board needs its code (claim_player)
revoke all on function public.login_player(text, uuid) from public, anon, authenticated;
revoke all on function public.name_taken(text), public.name_taken(text, uuid), public.rename_player(uuid, text, text), public.player_name(uuid, text) from public;
grant execute on function public.name_taken(text), public.name_taken(text, uuid), public.rename_player(uuid, text, text) to anon, authenticated;
revoke all on function
  public.submit_score(uuid, text, int, int, bigint), public.submit_score(uuid, text, int, int),
  public.top_scores(int), public.my_rank(uuid),
  public.submit_time(uuid, text, int, int), public.top_times(int, int), public.my_time(uuid, int),
  public.submit_daily(uuid, text, date, int), public.top_daily(date, int), public.my_daily(uuid, date),
  public.save_progress(uuid, text, text, jsonb), public.load_progress(uuid, text), public.claim_player(text, text, uuid)
from public;
grant execute on function
  public.submit_score(uuid, text, int, int, bigint), public.submit_score(uuid, text, int, int),
  public.top_scores(int), public.my_rank(uuid),
  public.submit_time(uuid, text, int, int), public.top_times(int, int), public.my_time(uuid, int),
  public.submit_daily(uuid, text, date, int), public.top_daily(date, int), public.my_daily(uuid, date),
  public.save_progress(uuid, text, text, jsonb), public.load_progress(uuid, text), public.claim_player(text, text, uuid)
to anon, authenticated;
-- ==================== FINISH: copy everything up to this line ====================
