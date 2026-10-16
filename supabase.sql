-- Desafio da Retenção — banco de dados Supabase
-- Rode este arquivo inteiro no Supabase: SQL Editor > New query > colar > Run.
-- Cria tabelas, segurança (RLS), funções RPC usadas pelo index.html e ativa o Realtime.

create extension if not exists pgcrypto with schema extensions;

-- ============ TABELAS ============

create table if not exists public.quiz_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique,
  title text not null default 'Desafio da Retenção',
  status text not null default 'waiting' check (status in ('waiting','running','finished')),
  current_question int,
  question_started_at timestamptz,
  time_limit int not null default 20 check (time_limit between 5 and 300),
  created_at timestamptz not null default now()
);

-- Token do facilitador fica separado e sem acesso público.
create table if not exists public.quiz_room_hosts (
  room_id uuid primary key references public.quiz_rooms(id) on delete cascade,
  host_token_hash text not null
);

create table if not exists public.quiz_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  nickname text not null,
  score int not null default 0,
  joined_at timestamptz not null default now()
);
create index if not exists quiz_players_room_idx on public.quiz_players(room_id);

create table if not exists public.quiz_answers (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  player_id uuid not null references public.quiz_players(id) on delete cascade,
  question_index int not null,
  answer_index int not null,
  is_correct boolean not null,
  points_earned int not null,
  answered_at timestamptz not null default now(),
  unique (player_id, question_index)
);
create index if not exists quiz_answers_room_idx on public.quiz_answers(room_id);

create table if not exists public.quiz_question_reads (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  player_id uuid not null references public.quiz_players(id) on delete cascade,
  nickname text not null,
  question_index int not null,
  read_at timestamptz not null default now(),
  unique (player_id, question_index)
);
create index if not exists quiz_reads_room_idx on public.quiz_question_reads(room_id, question_index);

-- Gabarito (índice da alternativa correta de cada pergunta, na mesma ordem do index.html).
create table if not exists public.quiz_answer_key (
  question_index int primary key,
  correct_index int not null
);
insert into public.quiz_answer_key (question_index, correct_index) values
  (0,1),(1,1),(2,0),(3,1),(4,0),(5,1),(6,1),(7,1),(8,1),(9,1),
  (10,1),(11,1),(12,0),(13,1),(14,1),(15,1),(16,1),(17,1),(18,1),(19,1),
  (20,1),(21,1),(22,1),(23,1),(24,1),(25,1),(26,1),(27,1),(28,1),(29,1)
on conflict (question_index) do update set correct_index = excluded.correct_index;

-- ============ SEGURANÇA (RLS) ============
-- Leitura pública das salas/ranking; escrita só pelas funções abaixo.

alter table public.quiz_rooms enable row level security;
alter table public.quiz_room_hosts enable row level security;
alter table public.quiz_players enable row level security;
alter table public.quiz_answers enable row level security;
alter table public.quiz_question_reads enable row level security;
alter table public.quiz_answer_key enable row level security;

drop policy if exists "leitura publica" on public.quiz_rooms;
create policy "leitura publica" on public.quiz_rooms for select using (true);
drop policy if exists "leitura publica" on public.quiz_players;
create policy "leitura publica" on public.quiz_players for select using (true);
drop policy if exists "leitura publica" on public.quiz_answers;
create policy "leitura publica" on public.quiz_answers for select using (true);
drop policy if exists "leitura publica" on public.quiz_question_reads;
create policy "leitura publica" on public.quiz_question_reads for select using (true);
-- quiz_room_hosts e quiz_answer_key: sem policies = ninguém lê pela API.

-- ============ FUNÇÕES (RPC) ============

create or replace function public._quiz_check_host(p_room_id uuid, p_host_token text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (
    select 1 from quiz_room_hosts
    where room_id = p_room_id
      and host_token_hash = encode(digest(p_host_token, 'sha256'), 'hex')
  ) then
    raise exception 'Token do facilitador inválido para esta sala.';
  end if;
end $$;
revoke all on function public._quiz_check_host(uuid, text) from public, anon, authenticated;

create or replace function public.create_quiz_room(p_title text, p_host_token text, p_time_limit int)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_code text;
  v_id uuid;
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i int;
begin
  if coalesce(length(p_host_token), 0) < 32 then
    raise exception 'Token do facilitador inválido.';
  end if;
  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1);
    end loop;
    exit when not exists (select 1 from quiz_rooms where room_code = v_code);
  end loop;

  insert into quiz_rooms (room_code, title, time_limit)
  values (v_code, left(coalesce(nullif(trim(p_title), ''), 'Desafio da Retenção'), 80),
          least(greatest(coalesce(p_time_limit, 20), 5), 300))
  returning id into v_id;

  insert into quiz_room_hosts (room_id, host_token_hash)
  values (v_id, encode(digest(p_host_token, 'sha256'), 'hex'));

  return json_build_object('room_id', v_id, 'room_code', v_code);
end $$;

create or replace function public.join_quiz_room(p_room_code text, p_nickname text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_room quiz_rooms;
  v_player_id uuid;
  v_nick text := left(trim(coalesce(p_nickname, '')), 24);
begin
  if v_nick = '' then raise exception 'Informe seu nome.'; end if;
  select * into v_room from quiz_rooms where room_code = upper(trim(p_room_code));
  if not found then raise exception 'Sala não encontrada. Confira o PIN.'; end if;
  if v_room.status = 'finished' then raise exception 'Esta rodada já foi encerrada.'; end if;

  insert into quiz_players (room_id, nickname) values (v_room.id, v_nick)
  returning id into v_player_id;

  return json_build_object('room_id', v_room.id, 'room_code', v_room.room_code, 'player_id', v_player_id);
end $$;

create or replace function public.start_quiz_room(p_room_id uuid, p_host_token text)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform _quiz_check_host(p_room_id, p_host_token);
  update quiz_rooms
     set status = 'running', current_question = 0, question_started_at = null
   where id = p_room_id;
  return json_build_object('status', 'running', 'current_question', 0);
end $$;

create or replace function public.reveal_quiz_question(p_room_id uuid, p_host_token text)
returns json language plpgsql security definer set search_path = public as $$
declare v_room quiz_rooms;
begin
  perform _quiz_check_host(p_room_id, p_host_token);
  select * into v_room from quiz_rooms where id = p_room_id;
  if v_room.status <> 'running' then raise exception 'Inicie a rodada primeiro.'; end if;
  update quiz_rooms set question_started_at = now() where id = p_room_id;
  return json_build_object('status', 'running', 'current_question', v_room.current_question);
end $$;

create or replace function public.advance_quiz_room(p_room_id uuid, p_host_token text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_room quiz_rooms;
  v_total int;
begin
  perform _quiz_check_host(p_room_id, p_host_token);
  select * into v_room from quiz_rooms where id = p_room_id;
  if v_room.status <> 'running' then raise exception 'A rodada não está em andamento.'; end if;
  select count(*) into v_total from quiz_answer_key;

  if v_room.current_question + 1 >= v_total then
    update quiz_rooms set status = 'finished', question_started_at = null where id = p_room_id;
    return json_build_object('status', 'finished');
  end if;

  update quiz_rooms
     set current_question = v_room.current_question + 1, question_started_at = null
   where id = p_room_id;
  return json_build_object('status', 'running', 'current_question', v_room.current_question + 1);
end $$;

create or replace function public.mark_quiz_question_read(p_room_id uuid, p_player_id uuid, p_question_index int)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_room quiz_rooms;
  v_nick text;
begin
  select * into v_room from quiz_rooms where id = p_room_id;
  if not found or v_room.status <> 'running' then raise exception 'A rodada não está em andamento.'; end if;
  if v_room.current_question <> p_question_index then raise exception 'Esta não é a pergunta atual.'; end if;
  select nickname into v_nick from quiz_players where id = p_player_id and room_id = p_room_id;
  if not found then raise exception 'Participante não encontrado nesta sala.'; end if;

  insert into quiz_question_reads (room_id, player_id, nickname, question_index)
  values (p_room_id, p_player_id, v_nick, p_question_index)
  on conflict (player_id, question_index) do nothing;
  return json_build_object('ok', true);
end $$;

create or replace function public.submit_quiz_answer(p_room_id uuid, p_player_id uuid, p_question_index int, p_answer_index int)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_room quiz_rooms;
  v_correct int;
  v_elapsed numeric;
  v_is_correct boolean;
  v_points int := 0;
begin
  select * into v_room from quiz_rooms where id = p_room_id;
  if not found or v_room.status <> 'running' then raise exception 'A rodada não está em andamento.'; end if;
  if v_room.current_question <> p_question_index then raise exception 'Esta não é a pergunta atual.'; end if;
  if v_room.question_started_at is null then raise exception 'Aguarde o facilitador iniciar o tempo da pergunta.'; end if;
  if not exists (select 1 from quiz_players where id = p_player_id and room_id = p_room_id) then
    raise exception 'Participante não encontrado nesta sala.';
  end if;
  if exists (select 1 from quiz_answers where player_id = p_player_id and question_index = p_question_index) then
    raise exception 'Você já respondeu esta pergunta.';
  end if;

  v_elapsed := extract(epoch from (now() - v_room.question_started_at));
  -- 1,5 s de tolerância para atraso de rede
  if v_elapsed > v_room.time_limit + 1.5 then raise exception 'O tempo desta pergunta acabou.'; end if;

  select correct_index into v_correct from quiz_answer_key where question_index = p_question_index;
  v_is_correct := (p_answer_index = v_correct);
  -- Estilo Kahoot: 500 pela resposta certa + até 500 pela rapidez
  if v_is_correct then
    v_points := 500 + round(500 * greatest(0, 1 - v_elapsed / v_room.time_limit))::int;
  end if;

  insert into quiz_answers (room_id, player_id, question_index, answer_index, is_correct, points_earned)
  values (p_room_id, p_player_id, p_question_index, p_answer_index, v_is_correct, v_points);
  update quiz_players set score = score + v_points where id = p_player_id;

  return json_build_object('is_correct', v_is_correct, 'points_earned', v_points);
end $$;

grant execute on function public.create_quiz_room(text, text, int) to anon, authenticated;
grant execute on function public.join_quiz_room(text, text) to anon, authenticated;
grant execute on function public.start_quiz_room(uuid, text) to anon, authenticated;
grant execute on function public.reveal_quiz_question(uuid, text) to anon, authenticated;
grant execute on function public.advance_quiz_room(uuid, text) to anon, authenticated;
grant execute on function public.mark_quiz_question_read(uuid, uuid, int) to anon, authenticated;
grant execute on function public.submit_quiz_answer(uuid, uuid, int, int) to anon, authenticated;

-- ============ REALTIME ============
-- Liga as atualizações em tempo real para as tabelas que o index.html escuta.
do $$
declare t text;
begin
  foreach t in array array['quiz_rooms','quiz_players','quiz_answers','quiz_question_reads'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
