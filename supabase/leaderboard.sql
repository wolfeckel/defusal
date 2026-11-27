-- Defusal online leaderboard. Run this once in Supabase → SQL Editor → New query → Run.
-- The game's public key can only call the three functions below; the table itself stays locked.

create table if not exists public.scores (
  player_id  uuid primary key,
  name       text not null check (char_length(name) between 1 and 20),
  levels     int  not null default 0 check (levels between 0 and 100),
  stars      int  not null default 0 check (stars between 0 and 300),
  updated_at timestamptz not null default now()
);
alter table public.scores enable row level security;   -- no policies: no direct reads or writes

-- save a player's totals; only ever raises them, never lowers
create or replace function public.submit_score(p_id uuid, p_name text, p_levels int, p_stars int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_levels < 1 or p_levels > 100 or p_stars < p_levels or p_stars > p_levels * 3 then
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

-- the top n players: most levels cleared, then most stars, then whoever got there first
create or replace function public.top_scores(n int default 50)
returns table (pos bigint, name text, levels int, stars int)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by s.levels desc, s.stars desc, s.updated_at asc), s.name, s.levels, s.stars
  from scores s
  order by 1
  limit least(greatest(n, 1), 100);
$$;

-- one player's position
create or replace function public.my_rank(p_id uuid)
returns bigint language sql stable security definer set search_path = public as $$
  select t.r from (
    select s.player_id, row_number() over (order by s.levels desc, s.stars desc, s.updated_at asc) as r from scores s
  ) t where t.player_id = p_id;
$$;

revoke all on function public.submit_score(uuid, text, int, int), public.top_scores(int), public.my_rank(uuid) from public;
grant execute on function public.submit_score(uuid, text, int, int), public.top_scores(int), public.my_rank(uuid) to anon, authenticated;
