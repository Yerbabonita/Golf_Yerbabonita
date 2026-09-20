-- ============================================================
-- Yerbabonita · rondas compartidas (9 o 18 hoyos, salida por vuelta, partidas guardadas)
-- Pega TODO este archivo en Supabase → SQL Editor → Run.
-- Es seguro correrlo más de una vez.
-- ============================================================

-- 1) Tablas -------------------------------------------------------------
create table if not exists rondas (
  codigo text primary key,
  creada timestamptz not null default now()
);

-- Configuración de la partida: 9 o 18 hoyos y color de salida de cada vuelta
alter table rondas add column if not exists hoyos int  not null default 9 check (hoyos in (9, 18));
alter table rondas add column if not exists tee1  text not null default 'blanca';
alter table rondas add column if not exists tee2  text;
-- Partida guardada: cuando alguien toca "Guardar partida", la ronda queda terminada
alter table rondas add column if not exists terminada     timestamptz;
alter table rondas add column if not exists terminada_por text;
-- Identificador para no duplicar partidas si el celular reintenta el envío
alter table rondas add column if not exists origen text unique;

create table if not exists jugadores (
  codigo text not null references rondas(codigo) on delete cascade,
  pos    int  not null check (pos between 0 and 4),
  nombre text not null default '',
  hcp    int,
  primary key (codigo, pos)
);

create table if not exists scores (
  codigo      text not null,
  pos         int  not null,
  hoyo        int  not null check (hoyo between 1 and 18),
  golpes      int  check (golpes between 1 and 20),
  editado_por text,
  editado_en  timestamptz not null default now(),
  primary key (codigo, pos, hoyo),
  foreign key (codigo, pos) references jugadores(codigo, pos) on delete cascade
);

-- (si la tabla ya existía con hoyos 10 a 18, se amplía el rango a 1 a 18)
alter table scores drop constraint if exists scores_hoyo_check;
alter table scores add constraint scores_hoyo_check check (hoyo between 1 and 18);

-- Historial: quién cambió qué y cuándo
create table if not exists cambios (
  id          bigint generated always as identity primary key,
  codigo      text not null references rondas(codigo) on delete cascade,
  pos         int  not null,
  hoyo        int  not null,
  anterior    int,
  nuevo       int,
  editado_por text,
  en          timestamptz not null default now()
);
create index if not exists cambios_codigo_idx on cambios (codigo, id desc);

-- 2) Seguridad: las tablas quedan cerradas al público.
--    Solo se puede entrar con el código, a través de las funciones de abajo.
alter table rondas    enable row level security;
alter table jugadores enable row level security;
alter table scores    enable row level security;
alter table cambios   enable row level security;
revoke all on rondas, jugadores, scores, cambios from anon, authenticated;

-- 3) Funciones ----------------------------------------------------------

drop function if exists crear_ronda(text, int);   -- versión anterior

-- Uso interno: valida la configuración y crea la ronda con un código libre.
create or replace function _nueva_ronda(p_hoyos int, p_tee1 text, p_tee2 text)
returns text language plpgsql security definer set search_path = public as $$
declare
  letras constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ';
  tees   constant text[] := array['azul', 'blanca', 'roja', 'amarilla'];
  c text;
  i int;
begin
  if p_hoyos not in (9, 18) or not (coalesce(p_tee1, '') = any (tees))
     or (p_hoyos = 18 and not (coalesce(p_tee2, '') = any (tees))) then
    raise exception 'config_invalida';
  end if;
  loop
    c := '';
    for i in 1..4 loop
      c := c || substr(letras, 1 + floor(random() * length(letras))::int, 1);
    end loop;
    begin
      insert into rondas(codigo, hoyos, tee1, tee2)
        values (c, p_hoyos, p_tee1, case when p_hoyos = 18 then p_tee2 else null end);
      return c;
    exception when unique_violation then
      null;  -- código repetido: se intenta otro
    end;
  end loop;
end $$;
revoke all on function _nueva_ronda(int, text, text) from public, anon, authenticated;

create or replace function crear_ronda(
  p_nombre text, p_hcp int, p_hoyos int, p_tee1 text, p_tee2 text)
returns json language plpgsql security definer set search_path = public as $$
declare c text;
begin
  c := _nueva_ronda(p_hoyos, p_tee1, p_tee2);
  insert into jugadores(codigo, pos, nombre, hcp) values
    (c, 0, left(trim(coalesce(p_nombre, '')), 30), p_hcp),
    (c, 1, '', null),
    (c, 2, '', null);
  return json_build_object('codigo', c, 'pos', 0);
end $$;

create or replace function unirse_ronda(p_codigo text, p_nombre text, p_hcp int)
returns json language plpgsql security definer set search_path = public as $$
declare
  cod  text := upper(trim(p_codigo));
  nom  text := left(trim(coalesce(p_nombre, '')), 30);
  pos_ int;
  fin  boolean;
begin
  if not exists (select 1 from rondas where codigo = cod) then
    return null;
  end if;
  perform pg_advisory_xact_lock(hashtext(cod));
  fin := (select terminada is not null from rondas where codigo = cod);
  -- 1) ¿ya estoy en la ronda con ese nombre?
  if nom <> '' then
    select j.pos into pos_ from jugadores j
      where j.codigo = cod and lower(trim(j.nombre)) = lower(nom)
      order by j.pos limit 1;
  end if;
  if pos_ is null and fin then raise exception 'ronda_terminada'; end if;
  -- 2) si no, tomo un lugar en blanco
  if pos_ is null then
    select j.pos into pos_ from jugadores j
      where j.codigo = cod and trim(j.nombre) = ''
      order by j.pos limit 1;
  end if;
  -- 3) si no, agrego un lugar nuevo
  if pos_ is null then
    select g into pos_ from generate_series(0, 4) g
      where not exists (select 1 from jugadores j where j.codigo = cod and j.pos = g)
      order by g limit 1;
    if pos_ is null then raise exception 'ronda_llena'; end if;
    insert into jugadores(codigo, pos, nombre, hcp) values (cod, pos_, nom, p_hcp);
  elsif not fin then
    update jugadores set nombre = nom, hcp = coalesce(p_hcp, hcp)
      where codigo = cod and pos = pos_;
  end if;
  return json_build_object('codigo', cod, 'pos', pos_);
end $$;

create or replace function agregar_jugador(p_codigo text, p_nombre text, p_hcp int)
returns int language plpgsql security definer set search_path = public as $$
declare
  cod  text := upper(trim(p_codigo));
  pos_ int;
begin
  if not exists (select 1 from rondas where codigo = cod) then
    raise exception 'ronda_no_existe';
  end if;
  if exists (select 1 from rondas where codigo = cod and terminada is not null) then
    raise exception 'ronda_terminada';
  end if;
  perform pg_advisory_xact_lock(hashtext(cod));
  select g into pos_ from generate_series(0, 4) g
    where not exists (select 1 from jugadores j where j.codigo = cod and j.pos = g)
    order by g limit 1;
  if pos_ is null then raise exception 'ronda_llena'; end if;
  insert into jugadores(codigo, pos, nombre, hcp)
    values (cod, pos_, left(trim(coalesce(p_nombre, '')), 30), p_hcp);
  return pos_;
end $$;

create or replace function estado_ronda(p_codigo text)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  cod text := upper(trim(p_codigo));
  r   rondas%rowtype;
begin
  select * into r from rondas where codigo = cod;
  if not found then
    return null;
  end if;
  return json_build_object(
    'codigo', cod,
    'hoyos', r.hoyos, 'tee1', r.tee1, 'tee2', r.tee2,
    'terminada', r.terminada, 'terminada_por', r.terminada_por,
    'jugadores', coalesce((
      select json_agg(json_build_object('pos', pos, 'nombre', nombre, 'hcp', hcp) order by pos)
      from jugadores where codigo = cod), '[]'::json),
    'scores', coalesce((
      select json_agg(json_build_object('pos', pos, 'hoyo', hoyo, 'golpes', golpes))
      from scores where codigo = cod and golpes is not null), '[]'::json),
    'cambios', coalesce((
      select json_agg(x) from (
        select pos, hoyo, anterior, nuevo, editado_por as por, en
        from cambios where codigo = cod order by id desc limit 15) x), '[]'::json)
  );
end $$;

create or replace function guardar_jugador(p_codigo text, p_pos int, p_nombre text, p_hcp int)
returns void language plpgsql security definer set search_path = public as $$
declare cod text := upper(trim(p_codigo));
begin
  if exists (select 1 from rondas where codigo = cod and terminada is not null) then
    raise exception 'ronda_terminada';
  end if;
  update jugadores
     set nombre = left(trim(coalesce(p_nombre, '')), 30), hcp = p_hcp
   where codigo = cod and pos = p_pos;
end $$;

create or replace function quitar_jugador(p_codigo text, p_pos int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from rondas where codigo = upper(trim(p_codigo)) and terminada is not null) then
    raise exception 'ronda_terminada';
  end if;
  delete from jugadores where codigo = upper(trim(p_codigo)) and pos = p_pos;
end $$;

create or replace function guardar_score(
  p_codigo text, p_pos int, p_hoyo int, p_golpes int, p_editor text)
returns void language plpgsql security definer set search_path = public as $$
declare
  cod text := upper(trim(p_codigo));
  ant int;
  hh  int;
begin
  select hoyos into hh from rondas where codigo = cod;
  if hh is null then raise exception 'ronda_no_existe'; end if;
  if exists (select 1 from rondas where codigo = cod and terminada is not null) then
    raise exception 'ronda_terminada';
  end if;
  if p_hoyo not between 1 and hh then raise exception 'hoyo_invalido'; end if;
  if p_golpes is not null and p_golpes not between 1 and 20 then raise exception 'golpes_invalidos'; end if;
  if not exists (select 1 from jugadores where codigo = cod and pos = p_pos) then
    raise exception 'jugador_no_existe';
  end if;
  select golpes into ant from scores where codigo = cod and pos = p_pos and hoyo = p_hoyo;
  if ant is not distinct from p_golpes then return; end if;   -- sin cambios
  insert into scores(codigo, pos, hoyo, golpes, editado_por, editado_en)
    values (cod, p_pos, p_hoyo, p_golpes, left(coalesce(p_editor, 'Alguien'), 30), now())
  on conflict (codigo, pos, hoyo) do update
    set golpes = excluded.golpes, editado_por = excluded.editado_por, editado_en = now();
  insert into cambios(codigo, pos, hoyo, anterior, nuevo, editado_por)
    values (cod, p_pos, p_hoyo, ant, p_golpes, left(coalesce(p_editor, 'Alguien'), 30));
end $$;

create or replace function limpiar_ronda(p_codigo text, p_editor text)
returns void language plpgsql security definer set search_path = public as $$
declare cod text := upper(trim(p_codigo));
begin
  if exists (select 1 from rondas where codigo = cod and terminada is not null) then
    raise exception 'ronda_terminada';
  end if;
  insert into cambios(codigo, pos, hoyo, anterior, nuevo, editado_por)
    select codigo, pos, hoyo, golpes, null, left(coalesce(p_editor, 'Alguien'), 30)
    from scores where codigo = cod and golpes is not null;
  delete from scores where codigo = cod;
end $$;

-- Guardar partida (ronda compartida): la ronda queda terminada y ya no se edita.
create or replace function terminar_ronda(p_codigo text, p_editor text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update rondas
     set terminada = now(), terminada_por = left(coalesce(nullif(trim(p_editor), ''), 'Alguien'), 30)
   where codigo = upper(trim(p_codigo)) and terminada is null;
end $$;

-- Guardar partida (tarjeta individual): se sube completa, ya terminada.
-- p_jugadores = [{"nombre":"JP","hcp":5,"scores":[4,3,2,null,...]}, ...]
create or replace function archivar_partida(
  p_id text, p_hoyos int, p_tee1 text, p_tee2 text, p_jugadores json, p_editor text)
returns text language plpgsql security definer set search_path = public as $$
declare
  c   text;
  j   record;
  sc  record;
  n   int;
  ed  text := left(coalesce(nullif(trim(p_editor), ''), 'Alguien'), 30);
begin
  select codigo into c from rondas where origen = p_id;
  if c is not null then return c; end if;              -- ya estaba guardada
  if p_jugadores is null or json_typeof(p_jugadores) <> 'array'
     or json_array_length(p_jugadores) not between 1 and 5 then
    raise exception 'jugadores_invalidos';
  end if;
  c := _nueva_ronda(p_hoyos, p_tee1, p_tee2);
  update rondas set origen = p_id, terminada = now(), terminada_por = ed where codigo = c;
  for j in select value as v, ordinality - 1 as pos
           from json_array_elements(p_jugadores) with ordinality loop
    insert into jugadores(codigo, pos, nombre, hcp)
      values (c, j.pos, left(trim(coalesce(j.v->>'nombre', '')), 30),
              case when j.v->>'hcp' ~ '^[0-9]{1,2}$' then (j.v->>'hcp')::int end);
    if json_typeof(j.v->'scores') = 'array' then
      for sc in select value as val, ordinality as h
                from json_array_elements(j.v->'scores') with ordinality loop
        if sc.h <= p_hoyos and json_typeof(sc.val) = 'number' then
          n := (sc.val::text)::numeric::int;
          if n between 1 and 20 then
            insert into scores(codigo, pos, hoyo, golpes, editado_por)
              values (c, j.pos, sc.h::int, n, ed);
          end if;
        end if;
      end loop;
    end if;
  end loop;
  return c;
end $$;

-- 4) Permisos: el público solo puede llamar estas funciones.
grant execute on function
  crear_ronda(text, int, int, text, text), unirse_ronda(text, text, int), agregar_jugador(text, text, int),
  estado_ronda(text), guardar_jugador(text, int, text, int), quitar_jugador(text, int),
  guardar_score(text, int, int, int, text), limpiar_ronda(text, text),
  terminar_ronda(text, text), archivar_partida(text, int, text, text, json, text)
to anon;
