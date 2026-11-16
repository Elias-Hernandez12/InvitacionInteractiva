-- Vuelve a ejecutar este script completo en Supabase > SQL Editor > Run
-- 1) CAMBIA el correo de abajo por el tuyo (solo ese correo podrá administrar)

create extension if not exists pgcrypto;

create table if not exists public.event_tables (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  capacity int not null default 10 check (capacity > 0),
  created_at timestamptz not null default now()
);

create table if not exists public.guests (
  id uuid primary key default gen_random_uuid(),
  token text not null unique default encode(gen_random_bytes(9), 'hex'),
  name text not null,
  table_id uuid references public.event_tables(id) on delete set null,
  status text not null default 'pendiente' check (status in ('pendiente','confirmado','rechazado')),
  companions int not null default 0 check (companions >= 0),
  attendee_names text[] not null default '{}'::text[],
  message text,
  responded_at timestamptz,
  checked_in boolean not null default false,
  checked_in_at timestamptz,
  created_at timestamptz not null default now()
);

-- El pase no tiene un límite propio; el aforo solo se controla por mesa.
alter table public.guests drop constraint if exists guests_seats_check;
alter table public.guests drop column if exists seats;
alter table public.guests add column if not exists attendee_names text[] not null default '{}'::text[];

alter table public.event_tables enable row level security;
alter table public.guests enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable as $$
  select coalesce(auth.jwt() ->> 'email', '') = any (array['elias.eh639@gmail.com'])
$$;

drop policy if exists admin_guests on public.guests;
create policy admin_guests on public.guests for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists admin_tables on public.event_tables;
create policy admin_tables on public.event_tables for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- El invitado solo puede consultar los datos de su pase usando su token.
create or replace function public.get_guest(p_token text) returns json
language sql security definer set search_path = public as $$
  select json_build_object('name', g.name, 'status', g.status, 'companions', g.companions,
                           'attendee_names', g.attendee_names,
                           'table_name', t.name)
  from guests g
  left join event_tables t on t.id = g.table_id
  where g.token = p_token
$$;

-- Asigna un pase a una mesa sin exceder su capacidad con asistentes confirmados.
create or replace function public.assign_guest_table(p_guest uuid, p_table uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_attendees int;
  v_capacity int;
  v_confirmed int;
begin
  if not public.is_admin() then raise exception 'No tienes permiso para asignar mesas.'; end if;

  select case when status = 'confirmado'
              then coalesce(nullif(cardinality(attendee_names), 0), companions + 1)
              else 0
         end
    into v_attendees
    from guests
   where id = p_guest
   for update;
  if not found then raise exception 'No se encontró la invitación.'; end if;

  if p_table is not null then
    select capacity into v_capacity
      from event_tables
     where id = p_table
     for update;
    if not found then raise exception 'No se encontró la mesa seleccionada.'; end if;

    select coalesce(sum(coalesce(nullif(cardinality(attendee_names), 0), companions + 1)), 0)
      into v_confirmed
      from guests
     where table_id = p_table and id <> p_guest and status = 'confirmado';
    if v_confirmed + v_attendees > v_capacity then
      raise exception 'La mesa no tiene capacidad suficiente: % de % lugares ya están ocupados.',
        v_confirmed, v_capacity;
    end if;
  end if;

  update guests set table_id = p_table where id = p_guest;
  return found;
end $$;

-- Guarda nombres sin límite por invitación y valida el aforo de la mesa asignada.
create or replace function public.rsvp_with_names(p_token text, p_status text, p_attendee_names text[])
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_names text[];
  v_table uuid;
  v_capacity int;
  v_confirmed int;
begin
  if p_status is null or p_status not in ('confirmado','rechazado') then return false; end if;

  select table_id into v_table
    from guests
   where token = p_token
   for update;
  if not found then return false; end if;

  v_names := array(
    select btrim(full_name)
      from unnest(coalesce(p_attendee_names, '{}'::text[])) as attendees(full_name)
     where btrim(full_name) <> ''
  );
  if p_status = 'confirmado' and cardinality(v_names) = 0 then
    raise exception 'Escribe el nombre de cada persona que asistirá.';
  end if;
  if p_status = 'confirmado' and v_table is not null then
    select capacity into v_capacity
      from event_tables
     where id = v_table
     for update;
    if not found then raise exception 'No se encontró la mesa asignada.'; end if;

    select coalesce(sum(coalesce(nullif(cardinality(attendee_names), 0), companions + 1)), 0)
      into v_confirmed
      from guests
     where table_id = v_table and token <> p_token and status = 'confirmado';
    if v_confirmed + cardinality(v_names) > v_capacity then
      raise exception 'La mesa asignada no tiene capacidad para todas las personas. Contacta a la organización.';
    end if;
  end if;

  update guests
     set status = p_status,
         companions = case when p_status = 'confirmado' then cardinality(v_names) - 1 else 0 end,
         attendee_names = case when p_status = 'confirmado' then v_names else '{}'::text[] end,
         responded_at = now()
   where token = p_token;
  return found;
end $$;

revoke all on function public.get_guest(text) from public;
revoke all on function public.assign_guest_table(uuid, uuid) from public;
revoke all on function public.rsvp_with_names(text, text, text[]) from public;
drop function if exists public.rsvp(text, text, int, text);
grant execute on function public.get_guest(text) to anon, authenticated;
grant execute on function public.assign_guest_table(uuid, uuid) to authenticated;
grant execute on function public.rsvp_with_names(text, text, text[]) to anon, authenticated;

-- Actualizacion en vivo (Realtime) para el panel
do $$ begin alter publication supabase_realtime add table public.guests; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.event_tables; exception when duplicate_object then null; end $$;
