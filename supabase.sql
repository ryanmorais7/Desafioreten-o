-- Desafio da Retenção — banco de dados Supabase (v2: controle total do apresentador)
-- Rode este arquivo inteiro no Supabase: SQL Editor > New query > colar > Run.
-- ATENÇÃO: este script recria as tabelas do quiz (apaga salas, participantes e respostas existentes).
--
-- Fluxo de cada pergunta (controlado pelo servidor):
--   lobby -> locked (só enunciado) -> answering (alternativas + tempo oficial) -> result (gabarito + pontos) -> próxima / finished
-- As alternativas, o gabarito e a explicação ficam em quiz_questions (sem acesso público) e só são
-- copiados para quiz_rooms (público + Realtime) quando o apresentador libera cada etapa.

create extension if not exists pgcrypto with schema extensions;

-- ============ LIMPEZA DA VERSÃO ANTERIOR ============

drop function if exists public._quiz_check_host(uuid, text);
drop function if exists public.create_quiz_room(text, text, int);
drop function if exists public.join_quiz_room(text, text);
drop function if exists public.start_quiz_room(uuid, text);
drop function if exists public.reveal_quiz_question(uuid, text);
drop function if exists public.advance_quiz_room(uuid, text);
drop function if exists public.mark_quiz_question_read(uuid, uuid, int);
drop function if exists public.submit_quiz_answer(uuid, uuid, int, int);

drop function if exists public._quiz_hash(text);
drop function if exists public._quiz_check_player(uuid, uuid, text);
drop function if exists public._quiz_set_question(uuid, int);
drop function if exists public.quiz_now();
drop function if exists public.is_quiz_host(uuid, text);
drop function if exists public.join_quiz_room(text, text, text);
drop function if exists public.resume_quiz_player(uuid, uuid, text);
drop function if exists public.reveal_quiz_result(uuid, text);
drop function if exists public.mark_quiz_question_read(uuid, uuid, text, int);
drop function if exists public.submit_quiz_answer(uuid, uuid, text, int, int);
drop function if exists public.get_my_quiz_answer(uuid, uuid, text, int);
drop function if exists public.get_quiz_host_question(uuid, text);

drop table if exists public.quiz_question_reads, public.quiz_answers, public.quiz_player_secrets,
  public.quiz_players, public.quiz_room_hosts, public.quiz_rooms, public.quiz_answer_key,
  public.quiz_questions cascade;

-- ============ TABELAS ============

-- Banco de perguntas (privado).
create table public.quiz_questions (
  question_index int primary key,
  level text not null,
  question text not null,
  options jsonb not null,
  correct_index int not null,
  explanation text not null
);

-- Estado público da sala. É a "fonte da verdade" que todos os aparelhos acompanham via Realtime.
create table public.quiz_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique,
  title text not null default 'Desafio da Retenção',
  phase text not null default 'lobby' check (phase in ('lobby','locked','answering','result','finished')),
  current_question int,
  total_questions int not null,
  time_limit int not null default 20 check (time_limit between 5 and 300),
  question_text text,
  question_level text,
  options jsonb,                    -- preenchido só em answering/result
  question_started_at timestamptz,  -- horário oficial de início (servidor)
  question_ends_at timestamptz,     -- horário oficial de término (servidor)
  correct_index int,                -- preenchido só em result
  explanation text,                 -- preenchido só em result
  created_at timestamptz not null default now()
);

create table public.quiz_room_hosts (
  room_id uuid primary key references public.quiz_rooms(id) on delete cascade,
  host_token_hash text not null
);

create table public.quiz_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  nickname text not null,
  score int not null default 0,
  last_answered_question int,
  joined_at timestamptz not null default now()
);
create index quiz_players_room_idx on public.quiz_players(room_id);
create unique index quiz_players_room_nick_idx on public.quiz_players(room_id, lower(nickname));

create table public.quiz_player_secrets (
  player_id uuid primary key references public.quiz_players(id) on delete cascade,
  token_hash text not null
);

create table public.quiz_answers (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  player_id uuid not null references public.quiz_players(id) on delete cascade,
  question_index int not null,
  answer_index int not null,
  is_correct boolean not null,
  points_earned int not null,
  answered_at timestamptz not null default now(),
  unique (player_id, question_index)  -- uma resposta por pergunta, mesmo com várias abas
);
create index quiz_answers_room_q_idx on public.quiz_answers(room_id, question_index);

create table public.quiz_question_reads (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.quiz_rooms(id) on delete cascade,
  player_id uuid not null references public.quiz_players(id) on delete cascade,
  nickname text not null,
  question_index int not null,
  read_at timestamptz not null default now(),
  unique (player_id, question_index)
);
create index quiz_reads_room_q_idx on public.quiz_question_reads(room_id, question_index);

insert into public.quiz_questions (question_index, level, question, options, correct_index, explanation) values
  (0, 'FÁCIL', 'Qual é o primeiro passo quando um filiado pede cancelamento?', '["Falar imediatamente sobre todos os benefícios","Ouvir e entender o motivo do pedido","Dizer que ele vai se arrepender","Encerrar o atendimento"]'::jsonb, 1, 'A retenção começa pela escuta e pela identificação do motivo real.'),
  (1, 'FÁCIL', 'O que significa praticar escuta ativa?', '["Esperar a vez de falar","Ouvir com atenção, confirmar o entendimento e fazer perguntas pertinentes","Ler um roteiro sem interrupções","Concordar com tudo"]'::jsonb, 1, 'Escuta ativa exige atenção, confirmação e perguntas que esclareçam a necessidade.'),
  (2, 'FÁCIL', 'Antes de sugerir um benefício, o conciliador deve:', '["Entender o que é importante para o filiado","Escolher o benefício mais popular","Oferecer sempre a mesma solução","Falar apenas sobre preço"]'::jsonb, 0, 'A sugestão deve fazer sentido para a necessidade identificada.'),
  (3, 'FÁCIL', 'Para que consultar o CTN antes do atendimento?', '["Para evitar conversar com o filiado","Para verificar informações disponíveis, como dependentes e histórico","Para decidir pelo filiado","Para dispensar o registro do atendimento"]'::jsonb, 1, 'O CTN ajuda a preparar uma conversa personalizada; confirme informações com o filiado.'),
  (4, 'FÁCIL', 'Se o filiado fala calmamente e aceita conversar, qual postura combina melhor?', '["Acolhedora e objetiva","Defensiva","Apressada","Confrontadora"]'::jsonb, 0, 'Adapte o ritmo e mantenha uma conversa respeitosa.'),
  (5, 'FÁCIL', 'O filiado diz que tem filhos. Qual é a melhor pergunta?', '["“Então você precisa de educação, certo?”","“Quais interesses ou necessidades da sua família você gostaria de atender?”","“Você já conhece todos os benefícios?”","“Por que não usa mais o cartão?”"]'::jsonb, 1, 'Não presuma a necessidade; investigue os interesses da família.'),
  (6, 'FÁCIL', 'Se você não tem certeza sobre a condição atual de um benefício, deve:', '["Prometer para não perder a retenção","Consultar a fonte oficial antes de orientar","Usar uma informação antiga","Evitar responder e mudar de assunto"]'::jsonb, 1, 'Confirme regras e disponibilidade antes de afirmar qualquer condição.'),
  (7, 'FÁCIL', 'Qual atitude ajuda a criar confiança?', '["Prometer uma solução imediata sem verificar","Explicar com clareza o que será feito e o que depende de confirmação","Interromper para ganhar tempo","Evitar registrar o caso"]'::jsonb, 1, 'Transparência e próximos passos realistas aumentam a confiança.'),
  (8, 'FÁCIL', 'Qual é o objetivo de apresentar benefícios na retenção?', '["Falar de todos, independentemente do perfil","Relacionar opções relevantes às necessidades identificadas","Convencer a qualquer custo","Substituir a escuta por uma lista"]'::jsonb, 1, 'Benefícios devem ser conectados ao que o filiado valoriza.'),
  (9, 'FÁCIL', 'Depois de combinar um próximo passo com o filiado, o que fazer?', '["Deixar para lembrar depois","Registrar o atendimento e o combinado no canal definido","Prometer que outra pessoa vai resolver sem encaminhar","Encerrar sem confirmar entendimento"]'::jsonb, 1, 'O registro dá continuidade ao atendimento e evita perda de informação.'),
  (10, 'MÉDIA', 'O filiado diz: “Não uso o cartão”. Qual pergunta abre melhor a investigação?', '["“Por que você não aproveita?”","“O que você esperava utilizar e o que dificultou esse uso?”","“Você sabe quantos benefícios existem?”","“Posso explicar tudo de novo?”"]'::jsonb, 1, 'Investigue expectativa e barreiras antes de propor uma alternativa.'),
  (11, 'MÉDIA', 'Você identificou dependentes no CTN. Como usar essa informação corretamente?', '["Presumir o que a família precisa","Perguntar sobre interesses e confirmar se aquela informação ainda faz sentido","Apresentar apenas benefícios infantis","Não mencionar os dependentes"]'::jsonb, 1, 'Use os dados como ponto de partida, nunca como conclusão automática.'),
  (12, 'MÉDIA', 'Uma mãe demonstra interesse em apoiar os estudos dos filhos. Qual caminho faz sentido?', '["Explorar opções educacionais, como Refuturiza, e confirmar condições vigentes","Garantir matrícula gratuita em qualquer curso","Falar apenas sobre consultas","Dizer que todos os cursos são iguais"]'::jsonb, 0, 'Conecte o interesse a uma opção pertinente e explique condições confirmadas.'),
  (13, 'MÉDIA', 'O filiado se interessa por economia no gás de cozinha. O conciliador deve:', '["Garantir cashback em qualquer compra","Apresentar a opção relacionada à Ultragaz e confirmar regras atuais","Mudar para benefícios de saúde sem explicar","Garantir que não há condições"]'::jsonb, 1, 'Explique apenas o que estiver confirmado nas regras vigentes.'),
  (14, 'MÉDIA', 'O filiado está irritado e diz que já explicou o problema várias vezes. Qual é a melhor resposta?', '["“Você precisa se acalmar”","Reconhecer o desgaste, ouvir e resumir o que entendeu antes de encaminhar","Repetir o roteiro desde o começo","Interromper para explicar a política"]'::jsonb, 1, 'Validar a experiência e resumir o entendimento evita que o cliente precise repetir tudo.'),
  (15, 'MÉDIA', 'Uma pessoa relata dificuldade para usar o aplicativo. Qual é a melhor abordagem?', '["Dizer que é simples e encerrar","Orientar passo a passo e confirmar se conseguiu acompanhar","Presumir que não tem familiaridade digital","Oferecer um benefício diferente sem resolver a barreira"]'::jsonb, 1, 'Apoie a pessoa no processo concreto e confira se a orientação funcionou.'),
  (16, 'MÉDIA', 'O filiado afirma que a mensalidade pesa no orçamento. O que investigar?', '["Se ele pode pedir dinheiro emprestado","Quais fatores pesam no orçamento e quais benefícios ele realmente utiliza ou valoriza","Se ele conhece o valor de outras pessoas","Se aceita pagar mais"]'::jsonb, 1, 'Aborde a dificuldade com respeito, sem constranger ou presumir capacidade financeira.'),
  (17, 'MÉDIA', 'A pessoa quer cancelar por insatisfação com uma clínica parceira. O que fazer?', '["Dizer que a clínica não tem culpa","Entender o ocorrido, registrar detalhes e explicar o encaminhamento possível","Prometer que nunca mais acontecerá","Ignorar a reclamação e falar de descontos"]'::jsonb, 1, 'A reclamação precisa ser compreendida e encaminhada, não encoberta com uma oferta.'),
  (18, 'MÉDIA', 'O filiado diz que já pagou, mas a pendência ainda aparece. Qual é a conduta adequada?', '["Cobrar novamente sem verificar","Solicitar/consultar os dados necessários, verificar o registro e explicar os próximos passos","Dizer que o sistema nunca erra","Mandar cancelar o cartão"]'::jsonb, 1, 'Verifique a informação antes de concluir que há inadimplência.'),
  (19, 'MÉDIA', 'Como diferenciar retenção de adimplência?', '["São a mesma atividade em todos os casos","Retenção busca entender e reduzir o cancelamento; adimplência trata da regularização de pagamentos","Retenção é apenas enviar cobrança","Adimplência é apresentar benefícios para impedir cancelamento"]'::jsonb, 1, 'Cada atendimento tem objetivo e abordagem próprios, ainda que possam se relacionar.'),
  (20, 'DIFÍCIL', 'Um filiado quer cancelar, reclama de preço e diz que não usa benefícios. Qual sequência é mais consistente?', '["Oferecer desconto, depois perguntar o nome","Investigar o motivo, entender uso e valor percebido, explorar opção pertinente e combinar próximo passo","Listar todos os parceiros e insistir","Dizer que o preço é baixo e encerrar"]'::jsonb, 1, 'Organize o atendimento: diagnóstico, relevância, proposta compatível e acordo claro.'),
  (21, 'DIFÍCIL', 'O CTN mostra dependentes, mas o filiado afirma que não precisa de benefícios para a família. O que fazer?', '["Insistir porque o sistema mostra dependentes","Respeitar a resposta, perguntar quais prioridades existem hoje e adaptar a conversa","Dizer que ele está errado","Continuar oferecendo benefícios infantis"]'::jsonb, 1, 'Dados do sistema não substituem a fala e a autonomia do filiado.'),
  (22, 'DIFÍCIL', 'Uma pessoa irritada exige promessa de solução ainda hoje, mas você não controla o prazo. Como responder?', '["Prometer para acalmá-la","Explicar o que será feito, quem avaliará e qual prazo está confirmado, sem garantir o que não controla","Dizer que não pode fazer nada","Encerrar o contato"]'::jsonb, 1, 'Seja responsável: diferencie o que você pode fazer do que depende de confirmação.'),
  (23, 'DIFÍCIL', 'O filiado reclama publicamente de um benefício e ameaça procurar o PROCON. Qual é a prioridade?', '["Debater nas redes sociais","Acolher, registrar fatos, orientar pelos canais adequados e não impedir o exercício dos direitos dele","Prometer qualquer compensação","Dizer que a reclamação prejudicará o atendimento"]'::jsonb, 1, 'Mantenha postura profissional, documentação adequada e encaminhamento transparente.'),
  (24, 'DIFÍCIL', 'Você tem pouco tempo e percebe que a pessoa está ansiosa. Qual estratégia tende a ser mais eficaz?', '["Falar rápido para passar todas as informações","Reconhecer a emoção, fazer uma pergunta objetiva, resumir a necessidade e explicar um próximo passo de cada vez","Apresentar todos os benefícios de uma vez","Evitar perguntas"]'::jsonb, 1, 'Estruture a conversa em etapas curtas e confirme o entendimento.'),
  (25, 'DIFÍCIL', 'O filiado se interessa por um benefício, mas você não confirmou elegibilidade ou disponibilidade. Como avançar?', '["Garantir o benefício e corrigir depois","Explicar que vai confirmar as condições e retornar com informação verificada","Dizer que todos têm direito","Registrar como resolvido"]'::jsonb, 1, 'Não transforme uma possibilidade em promessa; valide antes de confirmar.'),
  (26, 'DIFÍCIL', 'Uma unidade tem alto volume de cancelamentos por “não uso”. Qual análise ajuda mais a montar um plano de ação?', '["Enviar a mesma mensagem para todos","Segmentar motivos, investigar barreiras de utilização, observar perfis e testar ações com indicadores de resultado","Culpar os clientes por não utilizarem","Aumentar a quantidade de ofertas sem medir resultado"]'::jsonb, 1, 'Diagnóstico por causa e acompanhamento de indicadores permitem ações mais direcionadas.'),
  (27, 'DIFÍCIL', 'Após apresentar uma opção relevante, o filiado continua decidido a cancelar. Qual é a postura correta?', '["Pressionar até mudar de ideia","Respeitar a decisão, esclarecer dúvidas finais e seguir o processo de registro/encaminhamento","Dizer que ele perderá todos os direitos","Omitir informações para tentar retê-lo"]'::jsonb, 1, 'Retenção ética não significa impedir uma decisão consciente do filiado.'),
  (28, 'DIFÍCIL', 'Como avaliar se uma estratégia de retenção realmente funcionou, além de contar quantos atendimentos foram feitos?', '["Medir apenas a duração média da conversa","Acompanhar cancelamentos evitados, motivos, qualidade dos registros e indicadores definidos para a estratégia","Contar quantos benefícios foram citados","Considerar sucesso sempre que a pessoa não cancelar na hora"]'::jsonb, 1, 'Avalie resultado e qualidade, não apenas volume ou impressão imediata.'),
  (29, 'DIFÍCIL', 'Um conciliador identifica necessidade, oferece opção pertinente, registra o combinado e agenda retorno. O filiado não responde ao retorno. Qual é a melhor ação?', '["Marcar automaticamente como retido","Seguir o fluxo de acompanhamento definido, registrar tentativas e não presumir resultado sem evidência","Apagar o registro","Enviar mensagens repetidas sem critério"]'::jsonb, 1, 'O status precisa refletir evidências e o processo de acompanhamento estabelecido.');

-- ============ SEGURANÇA (RLS) ============
-- Leitura pública só do estado da sala, participantes/ranking e leituras.
-- Perguntas, gabarito, respostas e tokens: sem policies = inacessíveis pela API (só via funções).

alter table public.quiz_questions enable row level security;
alter table public.quiz_rooms enable row level security;
alter table public.quiz_room_hosts enable row level security;
alter table public.quiz_players enable row level security;
alter table public.quiz_player_secrets enable row level security;
alter table public.quiz_answers enable row level security;
alter table public.quiz_question_reads enable row level security;

create policy "leitura publica" on public.quiz_rooms for select using (true);
create policy "leitura publica" on public.quiz_players for select using (true);
create policy "leitura publica" on public.quiz_question_reads for select using (true);

-- ============ FUNÇÕES INTERNAS ============

create function public._quiz_hash(p text)
returns text language sql immutable set search_path = public, extensions as $$
  select encode(digest(coalesce(p, ''), 'sha256'), 'hex')
$$;

create function public._quiz_check_host(p_room_id uuid, p_host_token text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from quiz_room_hosts
                 where room_id = p_room_id and host_token_hash = _quiz_hash(p_host_token)) then
    raise exception 'Apenas o apresentador desta sala pode fazer isso.';
  end if;
end $$;

create function public._quiz_check_player(p_room_id uuid, p_player_id uuid, p_player_token text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from quiz_players p join quiz_player_secrets s on s.player_id = p.id
                 where p.id = p_player_id and p.room_id = p_room_id and s.token_hash = _quiz_hash(p_player_token)) then
    raise exception 'Participante não reconhecido nesta sala. Entre novamente com o PIN.';
  end if;
end $$;

-- Coloca a sala na fase "locked" com o enunciado da pergunta p_index (sem alternativas, tempo parado).
create function public._quiz_set_question(p_room_id uuid, p_index int)
returns void language plpgsql security definer set search_path = public as $$
declare v_q quiz_questions;
begin
  select * into v_q from quiz_questions where question_index = p_index;
  update quiz_rooms set
    phase = 'locked', current_question = p_index,
    question_text = v_q.question, question_level = v_q.level,
    options = null, question_started_at = null, question_ends_at = null,
    correct_index = null, explanation = null
  where id = p_room_id;
end $$;

revoke all on function public._quiz_hash(text) from public, anon, authenticated;
revoke all on function public._quiz_check_host(uuid, text) from public, anon, authenticated;
revoke all on function public._quiz_check_player(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public._quiz_set_question(uuid, int) from public, anon, authenticated;

-- ============ FUNÇÕES PÚBLICAS (RPC) ============

-- Relógio do servidor em milissegundos: os aparelhos usam para calcular o tempo restante real.
create function public.quiz_now()
returns double precision language sql volatile as $$
  select extract(epoch from clock_timestamp()) * 1000
$$;

create function public.create_quiz_room(p_title text, p_host_token text, p_time_limit int)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_code text;
  v_id uuid;
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i int;
begin
  if coalesce(length(p_host_token), 0) < 32 then raise exception 'Token do apresentador inválido.'; end if;
  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1);
    end loop;
    exit when not exists (select 1 from quiz_rooms where room_code = v_code);
  end loop;

  insert into quiz_rooms (room_code, title, time_limit, total_questions)
  values (v_code, left(coalesce(nullif(trim(p_title), ''), 'Desafio da Retenção'), 80),
          least(greatest(coalesce(p_time_limit, 20), 5), 300),
          (select count(*) from quiz_questions))
  returning id into v_id;

  insert into quiz_room_hosts (room_id, host_token_hash) values (v_id, _quiz_hash(p_host_token));
  return json_build_object('room_id', v_id, 'room_code', v_code);
end $$;

create function public.is_quiz_host(p_room_id uuid, p_host_token text)
returns boolean language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from quiz_room_hosts
                 where room_id = p_room_id and host_token_hash = _quiz_hash(p_host_token))
$$;

create function public.join_quiz_room(p_room_code text, p_nickname text, p_player_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_room quiz_rooms;
  v_player_id uuid;
  v_nick text := left(trim(coalesce(p_nickname, '')), 24);
begin
  if v_nick = '' then raise exception 'Informe seu nome.'; end if;
  if coalesce(length(p_player_token), 0) < 32 then raise exception 'Token do participante inválido.'; end if;
  select * into v_room from quiz_rooms where room_code = upper(trim(p_room_code));
  if not found then raise exception 'Sala não encontrada. Confira o PIN.'; end if;
  if v_room.phase = 'finished' then raise exception 'Esta rodada já foi encerrada.'; end if;
  if exists (select 1 from quiz_players where room_id = v_room.id and lower(nickname) = lower(v_nick)) then
    raise exception 'Já existe alguém com esse nome nesta sala. Use outro nome ou apelido.';
  end if;

  insert into quiz_players (room_id, nickname) values (v_room.id, v_nick) returning id into v_player_id;
  insert into quiz_player_secrets (player_id, token_hash) values (v_player_id, _quiz_hash(p_player_token));
  return json_build_object('room_id', v_room.id, 'room_code', v_room.room_code,
                           'player_id', v_player_id, 'nickname', v_nick);
end $$;

-- Volta para a sala depois de atualizar a página / reconectar (mesmo participante, sem duplicar).
create function public.resume_quiz_player(p_room_id uuid, p_player_id uuid, p_player_token text)
returns json language plpgsql security definer set search_path = public as $$
declare v_p quiz_players;
begin
  perform _quiz_check_player(p_room_id, p_player_id, p_player_token);
  select * into v_p from quiz_players where id = p_player_id;
  return json_build_object('room_id', v_p.room_id, 'player_id', v_p.id, 'nickname', v_p.nickname,
                           'room_code', (select room_code from quiz_rooms where id = v_p.room_id));
end $$;

-- 1. Preparação: inicia a rodada mostrando o enunciado da pergunta 1 (bloqueada).
create function public.start_quiz_room(p_room_id uuid, p_host_token text)
returns json language plpgsql security definer set search_path = public as $$
declare v_room quiz_rooms;
begin
  perform _quiz_check_host(p_room_id, p_host_token);
  select * into v_room from quiz_rooms where id = p_room_id for update;
  if v_room.phase <> 'lobby' then raise exception 'A rodada já foi iniciada.'; end if;
  perform _quiz_set_question(p_room_id, 0);
  return json_build_object('phase', 'locked', 'current_question', 0);
end $$;

-- 3/4. Autorização: libera as alternativas e grava o horário oficial de início e término.
create function public.reveal_quiz_question(p_room_id uuid, p_host_token text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_room quiz_rooms;
  v_start timestamptz := clock_timestamp();
begin
  perform _quiz_check_host(p_room_id, p_host_token);
  select * into v_room from quiz_rooms where id = p_room_id for update;
  if v_room.phase <> 'locked' then raise exception 'As alternativas desta pergunta já foram reveladas.'; end if;

  update quiz_rooms set
    phase = 'answering',
    options = (select options from quiz_questions where question_index = v_room.current_question),
    question_started_at = v_start,
    question_ends_at = v_start + make_interval(secs => v_room.time_limit)
  where id = p_room_id;
  return json_build_object('phase', 'answering', 'started_at', v_start,
                           'ends_at', v_start + make_interval(secs => v_room.time_limit));
end $$;

-- 5. Respostas: valida pergunta atual, prazo oficial e resposta única. Pontos só entram no ranking no resultado.
create function public.submit_quiz_answer(p_room_id uuid, p_player_id uuid, p_player_token text,
                                          p_question_index int, p_answer_index int)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_room quiz_rooms;
  v_q quiz_questions;
  v_now timestamptz := clock_timestamp();
  v_elapsed numeric;
  v_is_correct boolean;
  v_points int := 0;
  v_rows int;
begin
  perform _quiz_check_player(p_room_id, p_player_id, p_player_token);
  -- "for share" serializa com o apresentador: nenhuma resposta entra depois do resultado revelado.
  select * into v_room from quiz_rooms where id = p_room_id for share;
  if v_room.phase <> 'answering' or v_room.current_question <> p_question_index then
    raise exception 'Esta pergunta não está aberta para respostas.';
  end if;
  -- 0,5 s de tolerância apenas para o trânsito da rede; o botão já trava no prazo oficial.
  if v_now > v_room.question_ends_at + interval '500 milliseconds' then
    raise exception 'O tempo desta pergunta acabou. Resposta não registrada.';
  end if;

  select * into v_q from quiz_questions where question_index = p_question_index;
  if p_answer_index < 0 or p_answer_index >= jsonb_array_length(v_q.options) then
    raise exception 'Alternativa inválida.';
  end if;

  v_elapsed := greatest(0, extract(epoch from (v_now - v_room.question_started_at)));
  v_is_correct := (p_answer_index = v_q.correct_index);
  -- 500 pela resposta certa + até 500 pela rapidez (estilo Kahoot)
  if v_is_correct then
    v_points := 500 + round(500 * greatest(0, 1 - v_elapsed / v_room.time_limit))::int;
  end if;

  insert into quiz_answers (room_id, player_id, question_index, answer_index, is_correct, points_earned)
  values (p_room_id, p_player_id, p_question_index, p_answer_index, v_is_correct, v_points)
  on conflict (player_id, question_index) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then raise exception 'Você já respondeu esta pergunta.'; end if;

  update quiz_players set last_answered_question = p_question_index where id = p_player_id;
  return json_build_object('registered', true, 'answer_index', p_answer_index);
end $$;

-- 6/7. Encerramento + resultado: fecha as respostas, revela gabarito/explicação e soma os pontos no ranking.
create function public.reveal_quiz_result(p_room_id uuid, p_host_token text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_room quiz_rooms;
  v_q quiz_questions;
begin
  perform _quiz_check_host(p_room_id, p_host_token);
  select * into v_room from quiz_rooms where id = p_room_id for update;
  if v_room.phase <> 'answering' then raise exception 'Revele as alternativas antes de mostrar o resultado.'; end if;
  select * into v_q from quiz_questions where question_index = v_room.current_question;

  update quiz_rooms set
    phase = 'result',
    correct_index = v_q.correct_index,
    explanation = v_q.explanation,
    question_ends_at = least(question_ends_at, clock_timestamp())
  where id = p_room_id;

  update quiz_players p set score = p.score + a.points_earned
    from quiz_answers a
   where a.player_id = p.id and a.room_id = p_room_id and a.question_index = v_room.current_question;

  return json_build_object('phase', 'result', 'correct_index', v_q.correct_index);
end $$;

-- 8. Próxima pergunta (ou fim da rodada), sempre manual.
create function public.advance_quiz_room(p_room_id uuid, p_host_token text)
returns json language plpgsql security definer set search_path = public as $$
declare v_room quiz_rooms;
begin
  perform _quiz_check_host(p_room_id, p_host_token);
  select * into v_room from quiz_rooms where id = p_room_id for update;
  if v_room.phase <> 'result' then raise exception 'Mostre o resultado antes de avançar.'; end if;

  if v_room.current_question + 1 >= v_room.total_questions then
    update quiz_rooms set phase = 'finished' where id = p_room_id;
    return json_build_object('phase', 'finished');
  end if;
  perform _quiz_set_question(p_room_id, v_room.current_question + 1);
  return json_build_object('phase', 'locked', 'current_question', v_room.current_question + 1);
end $$;

-- Sinal opcional "Já li a pergunta" (não libera nada; só informa o apresentador).
create function public.mark_quiz_question_read(p_room_id uuid, p_player_id uuid, p_player_token text, p_question_index int)
returns json language plpgsql security definer set search_path = public as $$
declare v_room quiz_rooms;
begin
  perform _quiz_check_player(p_room_id, p_player_id, p_player_token);
  select * into v_room from quiz_rooms where id = p_room_id;
  if v_room.phase not in ('locked','answering') or v_room.current_question <> p_question_index then
    raise exception 'Esta não é a pergunta atual.';
  end if;
  insert into quiz_question_reads (room_id, player_id, nickname, question_index)
  select p_room_id, p_player_id, nickname, p_question_index from quiz_players where id = p_player_id
  on conflict (player_id, question_index) do nothing;
  return json_build_object('ok', true);
end $$;

-- Resposta do próprio participante (para recuperar após atualizar a página). Acerto/pontos só após o resultado.
create function public.get_my_quiz_answer(p_room_id uuid, p_player_id uuid, p_player_token text, p_question_index int)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_room quiz_rooms;
  v_a quiz_answers;
  v_show boolean;
begin
  perform _quiz_check_player(p_room_id, p_player_id, p_player_token);
  select * into v_room from quiz_rooms where id = p_room_id;
  select * into v_a from quiz_answers where player_id = p_player_id and question_index = p_question_index;
  if not found then return json_build_object('answered', false); end if;
  v_show := v_room.phase in ('result','finished') or p_question_index < v_room.current_question;
  return json_build_object('answered', true, 'answer_index', v_a.answer_index,
                           'is_correct', case when v_show then v_a.is_correct end,
                           'points_earned', case when v_show then v_a.points_earned end);
end $$;

-- Prévia completa da pergunta atual só para o apresentador (inclui alternativas e gabarito).
create function public.get_quiz_host_question(p_room_id uuid, p_host_token text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_room quiz_rooms;
  v_q quiz_questions;
begin
  perform _quiz_check_host(p_room_id, p_host_token);
  select * into v_room from quiz_rooms where id = p_room_id;
  if v_room.current_question is null then return null; end if;
  select * into v_q from quiz_questions where question_index = v_room.current_question;
  return json_build_object('question_index', v_q.question_index, 'options', v_q.options,
                           'correct_index', v_q.correct_index, 'explanation', v_q.explanation);
end $$;

grant execute on function public.quiz_now() to anon, authenticated;
grant execute on function public.create_quiz_room(text, text, int) to anon, authenticated;
grant execute on function public.is_quiz_host(uuid, text) to anon, authenticated;
grant execute on function public.join_quiz_room(text, text, text) to anon, authenticated;
grant execute on function public.resume_quiz_player(uuid, uuid, text) to anon, authenticated;
grant execute on function public.start_quiz_room(uuid, text) to anon, authenticated;
grant execute on function public.reveal_quiz_question(uuid, text) to anon, authenticated;
grant execute on function public.submit_quiz_answer(uuid, uuid, text, int, int) to anon, authenticated;
grant execute on function public.reveal_quiz_result(uuid, text) to anon, authenticated;
grant execute on function public.advance_quiz_room(uuid, text) to anon, authenticated;
grant execute on function public.mark_quiz_question_read(uuid, uuid, text, int) to anon, authenticated;
grant execute on function public.get_my_quiz_answer(uuid, uuid, text, int) to anon, authenticated;
grant execute on function public.get_quiz_host_question(uuid, text) to anon, authenticated;

-- ============ REALTIME ============
do $$
declare t text;
begin
  foreach t in array array['quiz_rooms','quiz_players','quiz_question_reads'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
