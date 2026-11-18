-- Omogi 편지 서버 (Supabase). SQL Editor 에 통째로 붙여 넣고 실행한다. 여러 번 실행해도 된다.
--
-- 구조
--   omogi 스키마 : 테이블과 실제 일을 하는 함수. API 로 드러나지 않는다 (Exposed schemas 에 넣지 말 것).
--   public 스키마: 앱이 부르는 얇은 함수(omogi_*)만 둔다. 로그인한 사용자만 부를 수 있다.
-- 앱은 테이블을 직접 읽거나 쓸 수 없다. 모든 일은 함수를 거치고, 함수는 auth.uid() 로 부른 사람을 확인한다.
--
-- 규칙 (바꾸려면 omogi.send_letter 안의 숫자를 고친다)
--   배달 시각 = 보낸 때 + 30~180분 (무작위),  누락 확률 = 8%,  한 친구에게 하루 5통
--   누락된 편지는 내용을 저장하지 않는다.  받는 사람이 가져가면 지우고, 안 가져가면 14일 뒤 지운다.
--   편지 내용(envelope)은 앱에서 받는 사람 키로 잠근 것이라 서버에서는 읽을 수 없다.

create schema if not exists omogi;
revoke all on schema omogi from public, anon;
grant usage on schema omogi to authenticated;

-- ───────────── 테이블 ─────────────
create table if not exists omogi.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  code        text not null unique,                                   -- 친구 코드 (8자)
  name        text not null check (char_length(name) between 1 and 20),
  public_key  text not null check (char_length(public_key) between 80 and 100),   -- P-256 공개 키 65바이트의 base64
  created_at  timestamptz not null default now()
);

create table if not exists omogi.friendships (
  a           uuid not null references omogi.profiles (id) on delete cascade,     -- 요청한 쪽 (차단이면 차단한 쪽)
  b           uuid not null references omogi.profiles (id) on delete cascade,     -- 요청받은 쪽
  status      text not null check (status in ('pending', 'accepted', 'blocked')),
  created_at  timestamptz not null default now(),
  primary key (a, b),
  check (a <> b)
);
create unique index if not exists friendships_pair on omogi.friendships (least(a, b), greatest(a, b));

create table if not exists omogi.letters (
  id          uuid primary key default gen_random_uuid(),
  sender      uuid not null references omogi.profiles (id) on delete cascade,
  recipient   uuid not null references omogi.profiles (id) on delete cascade,
  envelope    text,                                                   -- 잠근 편지의 base64. 누락된 편지는 null
  created_at  timestamptz not null default now(),
  deliver_at  timestamptz not null,
  lost        boolean not null
);
create index if not exists letters_recipient on omogi.letters (recipient, deliver_at);
create index if not exists letters_sender on omogi.letters (sender, deliver_at);

-- 하루 한도를 세는 기록 (편지는 받으면 지워지므로 따로 둔다). 내용은 없다.
create table if not exists omogi.send_log (
  sender      uuid not null references omogi.profiles (id) on delete cascade,
  recipient   uuid not null references omogi.profiles (id) on delete cascade,
  at          timestamptz not null default now()
);
create index if not exists send_log_pair on omogi.send_log (sender, recipient, at);

-- 직접 접근은 전부 막는다 (정책을 하나도 만들지 않으므로 함수 말고는 아무도 못 읽는다).
alter table omogi.profiles    enable row level security;
alter table omogi.friendships enable row level security;
alter table omogi.letters     enable row level security;
alter table omogi.send_log    enable row level security;
revoke all on all tables in schema omogi from public, anon, authenticated;

-- ───────────── 함수 (omogi) ─────────────
-- 부른 사람의 ID. 로그인하지 않았으면 멈춘다.
create or replace function omogi.me() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'omogi:not_signed_in'; end if;
  return v;
end $$;

-- 가입 또는 이름·키 갱신. 친구 코드는 처음 한 번만 만든다.
create or replace function omogi.register(p_name text, p_public_key text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := omogi.me();
  v_code text;
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';     -- 헷갈리는 글자(I, L, O, 0, 1)는 뺐다
  v_row omogi.profiles;
begin
  select * into v_row from omogi.profiles where id = v_me;
  if found then
    update omogi.profiles set name = btrim(p_name), public_key = p_public_key where id = v_me returning * into v_row;
  else
    loop
      v_code := '';
      for i in 1..8 loop
        v_code := v_code || substr(v_alphabet, 1 + floor(random() * 31)::int, 1);
      end loop;
      exit when not exists (select 1 from omogi.profiles where code = v_code);
    end loop;
    insert into omogi.profiles (id, code, name, public_key) values (v_me, v_code, btrim(p_name), p_public_key) returning * into v_row;
  end if;
  return json_build_object('id', v_row.id, 'code', v_row.code, 'name', v_row.name);
end $$;

-- 친구 코드로 요청한다. 상대가 이미 나에게 요청해 둔 상태면 바로 친구가 된다.
create or replace function omogi.request_friend(p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := omogi.me();
  v_them omogi.profiles;
  v_f omogi.friendships;
begin
  if not exists (select 1 from omogi.profiles where id = v_me) then raise exception 'omogi:not_registered'; end if;
  select * into v_them from omogi.profiles where code = upper(btrim(p_code));
  if not found or v_them.id = v_me then raise exception 'omogi:no_such_code'; end if;
  select * into v_f from omogi.friendships
   where (a = v_me and b = v_them.id) or (a = v_them.id and b = v_me);
  if found then
    if v_f.status = 'blocked' then raise exception 'omogi:no_such_code'; end if;      -- 차단 사실은 드러내지 않는다
    if v_f.status = 'pending' and v_f.b = v_me then
      update omogi.friendships set status = 'accepted' where a = v_f.a and b = v_f.b;
      return json_build_object('status', 'accepted', 'name', v_them.name);
    end if;
    return json_build_object('status', v_f.status, 'name', v_them.name);
  end if;
  if (select count(*) from omogi.friendships where a = v_me and status = 'pending') >= 20 then
    raise exception 'omogi:too_many_requests';
  end if;
  insert into omogi.friendships (a, b, status) values (v_me, v_them.id, 'pending');
  return json_build_object('status', 'pending', 'name', v_them.name);
end $$;

-- 받은 요청을 수락하거나 거절한다.
create or replace function omogi.respond_friend(p_friend uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := omogi.me();
begin
  if p_accept then
    update omogi.friendships set status = 'accepted' where a = p_friend and b = v_me and status = 'pending';
  else
    delete from omogi.friendships where a = p_friend and b = v_me and status = 'pending';
  end if;
end $$;

-- 친구를 끊는다. p_block 이면 차단해서 다시 요청하지 못하게 하고, 그 사람이 보낸 아직 안 온 편지도 지운다.
create or replace function omogi.remove_friend(p_friend uuid, p_block boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := omogi.me();
begin
  -- 상대가 나를 차단해 둔 줄은 건드리지 않는다.
  delete from omogi.friendships
   where ((a = v_me and b = p_friend) or (a = p_friend and b = v_me))
     and not (status = 'blocked' and a = p_friend);
  if p_block then
    delete from omogi.letters where sender = p_friend and recipient = v_me;
    insert into omogi.friendships (a, b, status) values (v_me, p_friend, 'blocked') on conflict do nothing;
  end if;
end $$;

-- 내 친구와 요청 목록. 공개 키는 서로 친구가 된 뒤에만 준다.
create or replace function omogi.list_friends() returns json
language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object(
           'id', p.id, 'name', p.name, 'status', f.status,
           'incoming', f.status = 'pending' and f.b = omogi.me(),
           'public_key', case when f.status = 'accepted' then p.public_key end) order by p.name), '[]'::json)
    from omogi.friendships f
    join omogi.profiles p on p.id = case when f.a = omogi.me() then f.b else f.a end
   where (f.a = omogi.me() or f.b = omogi.me()) and f.status <> 'blocked'
$$;

-- 편지를 맡긴다. 언제 도착할지, 잃어버릴지는 여기서 정하고 보낸 사람에게 알려 주지 않는다.
create or replace function omogi.send_letter(p_to uuid, p_envelope text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := omogi.me();
  v_lost boolean := random() < 0.08;
  v_id uuid;
begin
  if not exists (select 1 from omogi.friendships
                  where status = 'accepted' and ((a = v_me and b = p_to) or (a = p_to and b = v_me))) then
    raise exception 'omogi:not_friends';
  end if;
  if p_envelope is null or char_length(p_envelope) not between 100 and 2000 then raise exception 'omogi:bad_envelope'; end if;
  if (select count(*) from omogi.send_log
       where sender = v_me and recipient = p_to and at > now() - interval '24 hours') >= 5 then
    raise exception 'omogi:daily_limit';
  end if;
  insert into omogi.letters (sender, recipient, envelope, deliver_at, lost)
  values (v_me, p_to, case when v_lost then null else p_envelope end,
          now() + make_interval(mins => 30 + floor(random() * 151)::int), v_lost)
  returning id into v_id;
  insert into omogi.send_log (sender, recipient) values (v_me, p_to);
  -- 지나가는 김에 청소: 오래 안 찾아간 편지와 묵은 기록
  delete from omogi.letters where deliver_at < now() - interval '14 days';
  delete from omogi.send_log where at < now() - interval '2 days';
  return v_id;
end $$;

-- 나에게 도착한 편지와, 내가 보낸 것 가운데 잃어버린 편지의 ID. 시각이 안 된 편지는 보이지 않는다.
create or replace function omogi.fetch_mail() returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'arrived', (select coalesce(json_agg(json_build_object(
                         'id', l.id, 'from', l.sender, 'from_name', p.name, 'envelope', l.envelope) order by l.deliver_at), '[]'::json)
                  from (select * from omogi.letters
                         where recipient = omogi.me() and not lost and deliver_at <= now()
                         order by deliver_at limit 20) l
                  join omogi.profiles p on p.id = l.sender),
    'lost',    (select coalesce(json_agg(l.id), '[]'::json)
                  from omogi.letters l
                 where l.sender = omogi.me() and l.lost and l.deliver_at <= now()))
$$;

-- 앱이 저장을 마친 편지를 서버에서 지운다.
create or replace function omogi.ack_mail(p_arrived uuid[], p_lost uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := omogi.me();
begin
  delete from omogi.letters where id = any (p_arrived) and recipient = v_me and not lost and deliver_at <= now();
  delete from omogi.letters where id = any (p_lost) and sender = v_me and lost and deliver_at <= now();
end $$;

-- 내 계정과 거기에 딸린 것(친구 관계, 오가는 편지)을 모두 지운다.
create or replace function omogi.delete_account() returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := omogi.me();
begin
  delete from auth.users where id = v_me;
end $$;

revoke execute on all functions in schema omogi from public, anon;
grant execute on all functions in schema omogi to authenticated;

-- ───────────── 앱이 부르는 함수 (public) ─────────────
create or replace function public.omogi_register(p_name text, p_public_key text) returns json
language sql set search_path = '' as $$ select omogi.register(p_name, p_public_key) $$;
create or replace function public.omogi_request_friend(p_code text) returns json
language sql set search_path = '' as $$ select omogi.request_friend(p_code) $$;
create or replace function public.omogi_respond_friend(p_friend uuid, p_accept boolean) returns void
language sql set search_path = '' as $$ select omogi.respond_friend(p_friend, p_accept) $$;
create or replace function public.omogi_remove_friend(p_friend uuid, p_block boolean) returns void
language sql set search_path = '' as $$ select omogi.remove_friend(p_friend, p_block) $$;
create or replace function public.omogi_list_friends() returns json
language sql set search_path = '' as $$ select omogi.list_friends() $$;
create or replace function public.omogi_send_letter(p_to uuid, p_envelope text) returns uuid
language sql set search_path = '' as $$ select omogi.send_letter(p_to, p_envelope) $$;
create or replace function public.omogi_fetch_mail() returns json
language sql set search_path = '' as $$ select omogi.fetch_mail() $$;
create or replace function public.omogi_ack_mail(p_arrived uuid[], p_lost uuid[]) returns void
language sql set search_path = '' as $$ select omogi.ack_mail(p_arrived, p_lost) $$;
create or replace function public.omogi_delete_account() returns void
language sql set search_path = '' as $$ select omogi.delete_account() $$;

do $$
declare f text;
begin
  foreach f in array array[
    'omogi_register(text, text)', 'omogi_request_friend(text)', 'omogi_respond_friend(uuid, boolean)',
    'omogi_remove_friend(uuid, boolean)', 'omogi_list_friends()', 'omogi_send_letter(uuid, text)',
    'omogi_fetch_mail()', 'omogi_ack_mail(uuid[], uuid[])', 'omogi_delete_account()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- 함수를 새로 만든 뒤 API 가 바로 알아보게 한다.
notify pgrst, 'reload schema';
