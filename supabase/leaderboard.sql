-- Defusal online leaderboard. Run this in Supabase → SQL Editor → New query → Run.
-- Safe to run again: it keeps existing scores and only adds or updates what's needed.
-- The game's public key can only call the functions below; the tables themselves stay locked.
-- The game has 150 levels (450 stars).

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
alter table public.scores add  constraint scores_levels_check check (levels between 0 and 150);
alter table public.scores drop constraint if exists scores_stars_check;
alter table public.scores add  constraint scores_stars_check  check (stars between 0 and 450);
alter table public.scores enable row level security;   -- no policies: no direct reads or writes

-- save a player's totals; levels and stars only ever go up.
-- total_ms is the sum of the player's best time on every level they've cleared (mistakes included)
create or replace function public.submit_score(p_id uuid, p_name text, p_levels int, p_stars int, p_total_ms bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_levels < 1 or p_levels > 150 or p_stars < p_levels or p_stars > p_levels * 3
     or p_total_ms < p_levels * 1000 or p_total_ms > p_levels * 300000 then
    raise exception 'invalid score';
  end if;
  insert into scores (player_id, name, levels, stars, total_ms)
  values (p_id, left(trim(p_name), 20), p_levels, p_stars, p_total_ms)
  on conflict (player_id) do update set
    name       = excluded.name,
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
  if p_levels < 1 or p_levels > 150 or p_stars < p_levels or p_stars > p_levels * 3 then
    raise exception 'invalid score';
  end if;
  insert into scores (player_id, name, levels, stars)
  values (p_id, left(trim(p_name), 20), p_levels, p_stars)
  on conflict (player_id) do update set
    name       = excluded.name,
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
alter table public.level_times add  constraint level_times_level_check check (level between 1 and 150);
alter table public.level_times enable row level security;   -- no policies: no direct reads or writes

-- save a time; only ever keeps the player's fastest
create or replace function public.submit_time(p_id uuid, p_name text, p_level int, p_ms int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_level < 1 or p_level > 150 or p_ms < 1000 or p_ms > 300000 then
    raise exception 'invalid time';
  end if;
  insert into level_times (player_id, level, name, ms)
  values (p_id, p_level, left(trim(p_name), 20), p_ms)
  on conflict (player_id, level) do update set
    name   = excluded.name,
    ms     = least(level_times.ms, excluded.ms),
    set_at = case when excluded.ms < level_times.ms then now() else level_times.set_at end;
end $$;

-- the fastest n times on one level (ties go to whoever set it first)
create or replace function public.top_times(p_level int, n int default 10)
returns table (pos bigint, name text, ms int)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by t.ms asc, t.set_at asc), t.name, t.ms
  from level_times t
  where t.level = p_level
  order by 1
  limit least(greatest(n, 1), 50);
$$;

-- one player's time and position on one level
create or replace function public.my_time(p_id uuid, p_level int)
returns table (pos bigint, ms int)
language sql stable security definer set search_path = public as $$
  select x.r, x.ms from (
    select t.player_id, t.ms, row_number() over (order by t.ms asc, t.set_at asc) as r
    from level_times t where t.level = p_level
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
  values (p_id, p_day, left(trim(p_name), 20), p_ms)
  on conflict (player_id, day) do update set
    name   = excluded.name,
    ms     = least(daily_times.ms, excluded.ms),
    set_at = case when excluded.ms < daily_times.ms then now() else daily_times.set_at end;
end $$;

-- the fastest n times for one day
create or replace function public.top_daily(p_day date, n int default 10)
returns table (pos bigint, name text, ms int)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by t.ms asc, t.set_at asc), t.name, t.ms
  from daily_times t
  where t.day = p_day
  order by 1
  limit least(greatest(n, 1), 50);
$$;

-- one player's time and position for one day
create or replace function public.my_daily(p_id uuid, p_day date)
returns table (pos bigint, ms int)
language sql stable security definer set search_path = public as $$
  select x.r, x.ms from (
    select t.player_id, t.ms, row_number() over (order by t.ms asc, t.set_at asc) as r
    from daily_times t where t.day = p_day
  ) x where x.player_id = p_id;
$$;

-- ── Access: the public key may call these functions and nothing else ─────────
revoke all on function
  public.submit_score(uuid, text, int, int, bigint), public.submit_score(uuid, text, int, int),
  public.top_scores(int), public.my_rank(uuid),
  public.submit_time(uuid, text, int, int), public.top_times(int, int), public.my_time(uuid, int),
  public.submit_daily(uuid, text, date, int), public.top_daily(date, int), public.my_daily(uuid, date)
from public;
grant execute on function
  public.submit_score(uuid, text, int, int, bigint), public.submit_score(uuid, text, int, int),
  public.top_scores(int), public.my_rank(uuid),
  public.submit_time(uuid, text, int, int), public.top_times(int, int), public.my_time(uuid, int),
  public.submit_daily(uuid, text, date, int), public.top_daily(date, int), public.my_daily(uuid, date)
to anon, authenticated;
