-- =====================================================================
-- نظام إيواء المركبات — المرحلة الأولى: دخول المركبات
-- يُنفَّذ مرة واحدة في Supabase → SQL Editor. آمن لإعادة التنفيذ.
-- لا يغيّر أي جدول قائم (iqrarat والمستخدمين والجلسات كما هي).
-- كل الجداول مغلقة (RLS بلا سياسات)، والوصول فقط عبر الدوال أدناه
-- التي تتحقق من جلسة المستخدم (app_verify) ومن صلاحيته وموقعه.
-- =====================================================================

-- ---------- المواقع ----------
create table if not exists public.imp_sites (
  code   text primary key,
  name   text not null,
  active boolean not null default true,   -- false = لا يُحسب في العدد الفعلي ولا يظهر للاختيار
  sort   int not null default 0
);
insert into public.imp_sites(code,name,active,sort) values
  ('khumra','الخمرة',true,1),
  ('harazat','الحرازات',true,2),
  ('dhahban','ذهبان',true,3),
  ('closed','موقع سابق (البلد/الجزيرة/الرحاب)',false,8),
  ('unassigned','غير محدد',false,9)
on conflict (code) do nothing;

-- ---------- الموظفون وصلاحياتهم ----------
-- username = نفس اسم الدخول في البوابة. sites = المواقع المسموحة (المدير يرى الكل).
create table if not exists public.imp_staff (
  username     text primary key,
  display_name text not null default '',
  role         text not null check (role in ('manager','guard','data_entry','reception','accountant','dhahban')),
  sites        text[] not null default '{}',
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

-- ---------- السائقون ----------
create table if not exists public.imp_drivers (
  id         bigserial primary key,
  kind       text not null check (kind in ('internal','external')),
  name       text not null,
  phone      text not null default '',
  active     boolean not null default true,
  created_by text,
  created_at timestamptz not null default now()
);
create unique index if not exists imp_drivers_ext_phone on public.imp_drivers(phone)
  where kind='external' and phone<>'';

-- ---------- ملف المركبة (كل دخول = ملف مستقل) ----------
-- الحالات: 1 بانتظار المراجعة، 2 مكتملة البيانات، 3 في النقل، 4 طلب إطلاق،
--          5 مدفوعة، 6 إذن منتهٍ، 7 خرجت (أرشيف)
create table if not exists public.imp_vehicles (
  id              bigserial primary key,
  client_ref      uuid unique,                 -- يمنع تكرار الإرسال عند ضعف الشبكة
  impound_no      text not null default '',
  plate           text not null default '',
  plate_key       text not null,               -- اللوحة الموحدة، أو VIN:رقم الهيكل
  vin             text not null default '',
  vin_nonstandard boolean not null default false,
  make_model      text not null default '',
  color           text not null default '',
  model_year      int,
  vehicle_class   text not null default '',
  officer_name    text not null default '',
  source_place    text not null default '',
  driver_id       bigint references public.imp_drivers(id),
  site            text not null references public.imp_sites(code),
  status          smallint not null default 1 check (status between 1 and 7),
  has_belongings  boolean not null default false,
  notes           text not null default '',
  entry_at        timestamptz,
  exit_at         timestamptz,
  created_by      text,
  created_at      timestamptz not null default now(),
  reviewed_by     text,
  reviewed_at     timestamptz,
  updated_by      text,
  updated_at      timestamptz,
  legacy_row      int unique,                  -- رقم الصف في ملف الإكسل القديم
  legacy          jsonb
);
create index if not exists imp_vehicles_plate_key on public.imp_vehicles(plate_key);
create index if not exists imp_vehicles_impound_no on public.imp_vehicles(impound_no) where impound_no<>'';
create index if not exists imp_vehicles_vin on public.imp_vehicles(vin) where vin<>'';
create index if not exists imp_vehicles_site_status on public.imp_vehicles(site,status);

-- ---------- الصور والمرفقات ----------
create table if not exists public.imp_photos (
  id          bigserial primary key,
  vehicle_id  bigint not null references public.imp_vehicles(id),
  movement_id bigint,
  kind        text not null check (kind in ('police_doc','front','back','right','left','vin',
                                            'parking','belongings','transfer_out','transfer_in')),
  path        text not null,                   -- المسار في مخزن impound الخاص
  lat double precision, lng double precision, accuracy real,
  note        text not null default '',
  taken_by    text,
  created_at  timestamptz not null default now()
);
create index if not exists imp_photos_vehicle on public.imp_photos(vehicle_id);

-- ---------- التنقلات بين المواقع ----------
create table if not exists public.imp_movements (
  id          bigserial primary key,
  vehicle_id  bigint not null references public.imp_vehicles(id),
  from_site   text not null references public.imp_sites(code),
  to_site     text not null references public.imp_sites(code),
  driver_id   bigint references public.imp_drivers(id),
  prev_status smallint not null,
  state       text not null default 'in_transit' check (state in ('in_transit','received')),
  sent_by     text, sent_at timestamptz not null default now(),
  received_by text, received_at timestamptz
);
create index if not exists imp_movements_open on public.imp_movements(to_site) where state='in_transit';

-- ---------- سجل التعديلات ----------
create table if not exists public.imp_audit (
  id         bigserial primary key,
  vehicle_id bigint,
  username   text,
  action     text not null,
  changes    jsonb,
  at         timestamptz not null default now()
);
create index if not exists imp_audit_vehicle on public.imp_audit(vehicle_id);

alter table public.imp_sites     enable row level security;
alter table public.imp_staff     enable row level security;
alter table public.imp_drivers   enable row level security;
alter table public.imp_vehicles  enable row level security;
alter table public.imp_photos    enable row level security;
alter table public.imp_movements enable row level security;
alter table public.imp_audit     enable row level security;

-- ---------- مخزن الصور (خاص، يُفتح بروابط مؤقتة من دالة الخادم) ----------
insert into storage.buckets(id,name,public) values ('impound','impound',false)
on conflict (id) do nothing;

-- =====================================================================
-- دوال مساعدة (داخلية)
-- =====================================================================
create or replace function public.imp_norm_plate(p text) returns text
language sql immutable as $$
  select case when btrim(coalesce(p,'')) in ('','0','.','-','بدون لوحات','بدون لوحة','بدون لوحه','لايوجد','لا يوجد') then ''
  else btrim(regexp_replace(
         replace(replace(replace(translate(btrim(p),'أإآية','اااىه'),'هـ','ه'),'  ',' '),'  ',' '),
         '\s+',' ','g')) end
$$;

create or replace function public.imp_norm_vin(p text) returns text
language sql immutable as $$
  select case when length(v) < 5 or v ~ '^0+$' then '' else v end
  from (select upper(regexp_replace(coalesce(p,''),'[\s.\-]','','g')) v) s
$$;

create or replace function public.imp_vin_ok(v text) returns boolean
language sql immutable as $$ select v ~ '^[A-HJ-NPR-Z0-9]{17}$' $$;

-- يتحقق من الجلسة ويعيد سجل الموظف، أو يرفع خطأ مفهوماً للواجهة
create or replace function public.imp_me(p_token text) returns public.imp_staff
language plpgsql security definer set search_path = public as $$
declare v jsonb; s public.imp_staff; tok uuid;
begin
  -- رمز الجلسة في البوابة من نوع uuid؛ أي رمز غير صالح = جلسة منتهية
  begin tok := p_token::uuid; exception when others then raise exception 'SESSION_EXPIRED'; end;
  v := to_jsonb(public.app_verify(tok));
  if v is null or coalesce((v->>'ok')::boolean,false) is not true then
    raise exception 'SESSION_EXPIRED';
  end if;
  select * into s from public.imp_staff where username = lower(v->>'username') and active;
  if not found then raise exception 'NO_ACCESS'; end if;
  if s.display_name = '' then s.display_name := coalesce(v->>'name', s.username); end if;
  return s;
end $$;

create or replace function public.imp_can_site(s public.imp_staff, p_site text) returns boolean
language sql immutable as $$ select s.role='manager' or p_site = any(s.sites) $$;

create or replace function public.imp_need(s public.imp_staff, variadic roles text[]) returns void
language plpgsql immutable as $$
begin
  if not (s.role = 'manager' or s.role = any(roles)) then raise exception 'NOT_ALLOWED'; end if;
end $$;

create or replace function public.imp_add_photos(p_vehicle bigint, p_movement bigint, p_photos jsonb, p_user text)
returns void language sql security definer set search_path = public as $$
  insert into public.imp_photos(vehicle_id,movement_id,kind,path,lat,lng,accuracy,note,taken_by)
  select p_vehicle, p_movement, x->>'kind', x->>'path',
         nullif(x->>'lat','')::float8, nullif(x->>'lng','')::float8, nullif(x->>'accuracy','')::real,
         coalesce(x->>'note',''), p_user
  from jsonb_array_elements(coalesce(p_photos,'[]'::jsonb)) x
  where coalesce(x->>'path','') like 'v/%'
$$;

revoke all on function public.imp_me(text) from public, anon, authenticated;
revoke all on function public.imp_add_photos(bigint,bigint,jsonb,text) from public, anon, authenticated;

-- العدد الفعلي = الحالات 1،2،4،5،6 (المركبة في النقل تُعرض منفصلة)
create or replace function public.imp_counted(st smallint) returns boolean
language sql immutable as $$ select st in (1,2,4,5,6) $$;

-- =====================================================================
-- الدوال العامة (تُستدعى من الواجهة بالمفتاح العام + رمز الجلسة)
-- =====================================================================

create or replace function public.imp_session(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.imp_staff;
begin
  s := public.imp_me(p_token);
  return jsonb_build_object('username',s.username,'name',s.display_name,'role',s.role,
    'sites', case when s.role='manager' then (select coalesce(jsonb_agg(code order by sort),'[]') from imp_sites where active)
                  else to_jsonb(s.sites) end,
    'all_sites', (select jsonb_agg(jsonb_build_object('code',code,'name',name,'active',active) order by sort) from imp_sites));
end $$;

-- ---------- السائقون ----------
create or replace function public.imp_drivers_list(p_token text, p_q text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.imp_staff;
begin
  s := public.imp_me(p_token);
  return (select coalesce(jsonb_agg(to_jsonb(d) order by d.kind, d.name),'[]') from (
    select id,kind,name,phone from imp_drivers
    where active and (p_q = '' or name ilike '%'||p_q||'%' or phone like '%'||p_q||'%')
    order by kind, name limit 300) d);
end $$;

-- سائق من الخارج بنفس الجوال يُعاد سجله (فيقترح النظام اسمه)
create or replace function public.imp_driver_save(p_token text, p_kind text, p_name text, p_phone text, p_id bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.imp_staff; r public.imp_drivers; ph text := regexp_replace(coalesce(p_phone,''),'\D','','g');
begin
  s := public.imp_me(p_token);
  if p_kind = 'internal' or p_id is not null then perform public.imp_need(s,'accountant','data_entry'); end if;
  if btrim(coalesce(p_name,'')) = '' then raise exception 'اسم السائق مطلوب'; end if;
  if p_id is not null then
    update imp_drivers set name=btrim(p_name), phone=ph, kind=p_kind where id=p_id returning * into r;
  else
    if p_kind='external' and ph<>'' then
      select * into r from imp_drivers where kind='external' and phone=ph;
      if found then return to_jsonb(r) || '{"existing":true}'; end if;
    end if;
    insert into imp_drivers(kind,name,phone,created_by) values (p_kind,btrim(p_name),ph,s.username) returning * into r;
  end if;
  return to_jsonb(r);
end $$;

-- ---------- فحص قبل التسجيل ----------
create or replace function public.imp_check(p_token text, p_plate text, p_vin text, p_impound_no text, p_exclude bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.imp_staff; pk text := public.imp_norm_plate(p_plate); vn text := public.imp_norm_vin(p_vin);
        w jsonb := '[]'; r record;
begin
  s := public.imp_me(p_token);
  for r in select v.id, v.site, v.status, st.name sname from imp_vehicles v join imp_sites st on st.code=v.site
           where v.status <> 7 and (v.id is distinct from p_exclude)
             and ((pk<>'' and v.plate_key = pk) or (vn<>'' and v.vin = vn)) limit 5 loop
    w := w || jsonb_build_object('type','active','id',r.id,'site',r.sname,
           'msg','المركبة نفسها مسجلة حالياً داخل '||r.sname||' (ملف '||r.id||')');
  end loop;
  if btrim(coalesce(p_impound_no,'')) <> '' and exists (select 1 from imp_vehicles where impound_no = btrim(p_impound_no) and id is distinct from p_exclude) then
    w := w || jsonb_build_object('type','impound_no','msg','رقم الإيواء '||btrim(p_impound_no)||' مسجل من قبل','block',true);
  end if;
  return jsonb_build_object('warnings',w,'history',
    (select coalesce(jsonb_agg(jsonb_build_object('id',id,'entry_at',entry_at,'exit_at',exit_at,'status',status) order by id desc),'[]')
       from imp_vehicles where pk<>'' and plate_key=pk and id is distinct from p_exclude));
end $$;

-- ---------- تسجيل دخول مركبة (الحارس / موظف ذهبان) ----------
create or replace function public.imp_intake(p_token text, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.imp_staff; v public.imp_vehicles; site text := p_data->>'site';
        pl text := public.imp_norm_plate(p_data->>'plate'); vn text := public.imp_norm_vin(p_data->>'vin');
        ph jsonb := coalesce(p_data->'photos','[]'); k text; ino text := btrim(coalesce(p_data->>'impound_no',''));
begin
  s := public.imp_me(p_token);
  perform public.imp_need(s,'guard','dhahban');
  if not public.imp_can_site(s, site) then raise exception 'ليس لديك صلاحية على هذا الموقع'; end if;

  -- إعادة الإرسال من صندوق الانتظار: نعيد نفس الملف بلا تكرار
  select * into v from imp_vehicles where client_ref = (p_data->>'client_ref')::uuid;
  if found then return jsonb_build_object('id',v.id,'duplicate',true); end if;

  if pl = '' and vn = '' then raise exception 'رقم اللوحة إلزامي، أو رقم الهيكل إذا لم تكن للمركبة لوحة'; end if;
  foreach k in array array['police_doc','front','back','right','left','vin','parking'] loop
    if not exists (select 1 from jsonb_array_elements(ph) x where x->>'kind'=k) then
      raise exception 'صورة ناقصة: %', k;
    end if;
  end loop;
  if exists (select 1 from jsonb_array_elements(ph) x where x->>'kind'='parking'
             and (nullif(x->>'accuracy','') is null or (x->>'accuracy')::real > 10)) then
    raise exception 'صورة المكان تحتاج دقة موقع 10 أمتار أو أفضل';
  end if;
  if ino <> '' and exists (select 1 from imp_vehicles where impound_no = ino) then
    raise exception 'رقم الإيواء % مسجل من قبل', ino;
  end if;

  insert into imp_vehicles(client_ref,impound_no,plate,plate_key,vin,make_model,color,source_place,driver_id,
                           site,status,has_belongings,notes,entry_at,created_by)
  values ((p_data->>'client_ref')::uuid, ino, btrim(coalesce(p_data->>'plate','')),
          case when pl<>'' then pl else 'VIN:'||vn end, vn,
          coalesce(p_data->>'make_model',''), coalesce(p_data->>'color',''), coalesce(p_data->>'source_place',''),
          nullif(p_data->>'driver_id','')::bigint, site, 1,
          exists (select 1 from jsonb_array_elements(ph) x where x->>'kind'='belongings'),
          coalesce(p_data->>'notes',''), coalesce(nullif(p_data->>'taken_at','')::timestamptz, now()), s.username)
  returning * into v;
  perform public.imp_add_photos(v.id, null, ph, s.username);
  insert into imp_audit(vehicle_id,username,action,changes) values (v.id,s.username,'intake',p_data - 'photos');
  return jsonb_build_object('id',v.id);
end $$;

-- ---------- صور مقتنيات إضافية (لا يُحذف منها شيء) ----------
create or replace function public.imp_add_belongings(p_token text, p_vehicle bigint, p_photos jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.imp_staff; v public.imp_vehicles;
begin
  s := public.imp_me(p_token);
  perform public.imp_need(s,'guard','dhahban','data_entry');
  select * into v from imp_vehicles where id=p_vehicle;
  if not found or not public.imp_can_site(s,v.site) then raise exception 'NOT_ALLOWED'; end if;
  perform public.imp_add_photos(v.id, null,
    (select jsonb_agg(x || '{"kind":"belongings"}') from jsonb_array_elements(p_photos) x), s.username);
  update imp_vehicles set has_belongings=true where id=v.id;
  insert into imp_audit(vehicle_id,username,action,changes) values (v.id,s.username,'belongings',jsonb_build_object('count',jsonb_array_length(p_photos)));
  return jsonb_build_object('ok',true);
end $$;

-- ---------- قراءة ملف مركبة ----------
create or replace function public.imp_vehicle(p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.imp_staff; v public.imp_vehicles;
begin
  s := public.imp_me(p_token);
  select * into v from imp_vehicles where id=p_id;
  if not found then raise exception 'الملف غير موجود'; end if;
  if s.role in ('guard','dhahban') and not public.imp_can_site(s,v.site)
     and not exists (select 1 from imp_movements m where m.vehicle_id=v.id and m.state='in_transit' and public.imp_can_site(s,m.to_site)) then
    raise exception 'NOT_ALLOWED';
  end if;
  return to_jsonb(v) - 'legacy' || jsonb_build_object(
    'legacy_notes', case when v.legacy is null then null else jsonb_strip_nulls(jsonb_build_object(
        'سبب الحجز',nullif(v.legacy->>'impound_reason',''),'الجهة',nullif(v.legacy->>'authority',''),
        'القسم',nullif(v.legacy->>'department',''),'رقم القضية',nullif(v.legacy->>'case_no',''),
        'المربع',nullif(v.legacy->>'bay',''),'ملاحظات',nullif(v.legacy->>'notes',''),
        'المالك',nullif(v.legacy->>'owner_name',''),'جوال المالك',nullif(v.legacy->>'owner_phone',''),
        'المفتاح',nullif(v.legacy->>'has_key',''),'سائق الونش',nullif(v.legacy->>'tow_driver',''),
        'ملاحظات الاستيراد',nullif(v.legacy->>'issues',''))) end,
    'site_name',(select name from imp_sites where code=v.site),
    'driver',(select to_jsonb(d) from (select id,kind,name,phone from imp_drivers where id=v.driver_id) d),
    'photos',(select coalesce(jsonb_agg(to_jsonb(ph) - 'vehicle_id' order by ph.id),'[]')
              from imp_photos ph where ph.vehicle_id=v.id
                 -- صور الأرشيف القديم المربوطة بنفس اللوحة تظهر أيضاً في ملف المركبة الحالي
                 or (ph.kind='archive' and v.site<>'archive' and v.plate_key not like 'LEGACY:%'
                     and ph.vehicle_id in (select a.id from imp_vehicles a where a.site='archive' and a.plate_key=v.plate_key))),
    'movements',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'from',f.name,'to',t.name,'to_site',m.to_site,'state',m.state,
               'sent_by',m.sent_by,'sent_at',m.sent_at,'received_by',m.received_by,'received_at',m.received_at,
               'driver',(select name from imp_drivers where id=m.driver_id)) order by m.id),'[]')
              from imp_movements m join imp_sites f on f.code=m.from_site join imp_sites t on t.code=m.to_site where m.vehicle_id=v.id),
    'history',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'entry_at',entry_at,'exit_at',exit_at,'status',status,'site',site) order by id desc),'[]')
              from imp_vehicles where plate_key=v.plate_key and id<>v.id and v.plate_key not like 'LEGACY:%'),
    'audit',(select coalesce(jsonb_agg(jsonb_build_object('username',username,'action',action,'changes',changes,'at',at) order by id),'[]')
              from imp_audit where vehicle_id=v.id));
end $$;

-- ---------- مراجعة مدخل البيانات ----------
create or replace function public.imp_vehicle_save(p_token text, p_id bigint, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.imp_staff; v public.imp_vehicles; n public.imp_vehicles; vn text; pl text; ino text; diff jsonb;
begin
  s := public.imp_me(p_token);
  perform public.imp_need(s,'data_entry');
  select * into v from imp_vehicles where id=p_id for update;
  if not found then raise exception 'الملف غير موجود'; end if;
  if v.status = 7 then raise exception 'الملف مؤرشف'; end if;
  vn := public.imp_norm_vin(p_data->>'vin');
  pl := public.imp_norm_plate(p_data->>'plate');
  ino := btrim(coalesce(p_data->>'impound_no',''));
  if pl='' and vn='' then raise exception 'رقم اللوحة أو رقم الهيكل مطلوب'; end if;
  if vn<>'' and not public.imp_vin_ok(vn) and coalesce((p_data->>'vin_nonstandard')::boolean,false) is not true then
    raise exception 'رقم الهيكل يجب أن يكون 17 خانة بلا الحروف I و O و Q';
  end if;
  if ino<>'' and exists (select 1 from imp_vehicles where impound_no=ino and id<>v.id) then
    raise exception 'رقم الإيواء % مسجل لملف آخر', ino;
  end if;
  update imp_vehicles set
    impound_no=ino, plate=btrim(coalesce(p_data->>'plate','')),
    plate_key=case when pl<>'' then pl when vn<>'' then 'VIN:'||vn else plate_key end,
    vin=vn, vin_nonstandard=coalesce((p_data->>'vin_nonstandard')::boolean,false),
    make_model=coalesce(p_data->>'make_model',''), color=coalesce(p_data->>'color',''),
    model_year=nullif(regexp_replace(coalesce(p_data->>'model_year',''),'\D','','g'),'')::int,
    vehicle_class=coalesce(p_data->>'vehicle_class',''), officer_name=coalesce(p_data->>'officer_name',''),
    source_place=coalesce(p_data->>'source_place',source_place), notes=coalesce(p_data->>'notes',notes),
    driver_id=coalesce(nullif(p_data->>'driver_id','')::bigint, driver_id),
    status=case when status=1 then 2 else status end,
    reviewed_by=case when status=1 then s.username else reviewed_by end,
    reviewed_at=case when status=1 then now() else reviewed_at end,
    updated_by=s.username, updated_at=now()
  where id=v.id returning * into n;
  select jsonb_object_agg(a.key, jsonb_build_array(b.value, a.value)) into diff
  from jsonb_each(to_jsonb(n)) a join jsonb_each(to_jsonb(v)) b using (key)
  where a.value is distinct from b.value and a.key not in ('updated_at','updated_by','reviewed_at','reviewed_by');
  insert into imp_audit(vehicle_id,username,action,changes) values (v.id,s.username,case when v.status=1 then 'review' else 'edit' end,diff);
  return jsonb_build_object('id',v.id,'status',n.status);
end $$;

-- ---------- النقل بين المواقع ----------
create or replace function public.imp_transfer_send(p_token text, p_id bigint, p_to text, p_driver bigint, p_photos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.imp_staff; v public.imp_vehicles; m bigint;
begin
  s := public.imp_me(p_token);
  perform public.imp_need(s,'guard','dhahban');
  select * into v from imp_vehicles where id=p_id for update;
  if not found or not public.imp_can_site(s,v.site) then raise exception 'NOT_ALLOWED'; end if;
  if not public.imp_counted(v.status) then raise exception 'المركبة ليست داخل الموقع حالياً'; end if;
  if p_to = v.site or not exists (select 1 from imp_sites where code=p_to and active) then raise exception 'اختر موقعاً آخر'; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce(p_photos,'[]')) x where x->>'kind'='transfer_out') then
    raise exception 'صوّر المركبة على المصفحة عند خروجها';
  end if;
  insert into imp_movements(vehicle_id,from_site,to_site,driver_id,prev_status,sent_by)
  values (v.id,v.site,p_to,p_driver,v.status,s.username) returning id into m;
  perform public.imp_add_photos(v.id, m, p_photos, s.username);
  update imp_vehicles set status=3, updated_by=s.username, updated_at=now() where id=v.id;
  insert into imp_audit(vehicle_id,username,action,changes) values (v.id,s.username,'transfer_send',jsonb_build_object('from',v.site,'to',p_to,'driver',p_driver));
  return jsonb_build_object('movement_id',m);
end $$;

create or replace function public.imp_incoming(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.imp_staff;
begin
  s := public.imp_me(p_token);
  return (select coalesce(jsonb_agg(jsonb_build_object('movement_id',m.id,'vehicle_id',v.id,'plate',v.plate,'vin',v.vin,
            'impound_no',v.impound_no,'make_model',v.make_model,'color',v.color,'from',f.name,'to',t.name,'to_site',m.to_site,
            'sent_at',m.sent_at,'sent_by',m.sent_by,'driver',(select name from imp_drivers where id=m.driver_id)) order by m.sent_at),'[]')
          from imp_movements m join imp_vehicles v on v.id=m.vehicle_id
          join imp_sites f on f.code=m.from_site join imp_sites t on t.code=m.to_site
          where m.state='in_transit' and public.imp_can_site(s,m.to_site));
end $$;

create or replace function public.imp_transfer_receive(p_token text, p_movement bigint, p_photos jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.imp_staff; m public.imp_movements;
begin
  s := public.imp_me(p_token);
  perform public.imp_need(s,'guard','dhahban');
  select * into m from imp_movements where id=p_movement for update;
  if not found or m.state<>'in_transit' then raise exception 'هذا النقل غير موجود أو تم استلامه'; end if;
  if not public.imp_can_site(s,m.to_site) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce(p_photos,'[]')) x where x->>'kind'='transfer_in'
                 and nullif(x->>'accuracy','') is not null and (x->>'accuracy')::real <= 10) then
    raise exception 'صوّر المركبة في مكانها الجديد بدقة موقع 10 أمتار أو أفضل';
  end if;
  update imp_movements set state='received', received_by=s.username, received_at=now() where id=m.id;
  perform public.imp_add_photos(m.vehicle_id, m.id, p_photos, s.username);
  update imp_vehicles set site=m.to_site, status=m.prev_status, updated_by=s.username, updated_at=now() where id=m.vehicle_id;
  insert into imp_audit(vehicle_id,username,action,changes) values (m.vehicle_id,s.username,'transfer_receive',jsonb_build_object('to',m.to_site));
  return jsonb_build_object('ok',true);
end $$;

-- ---------- العدد الفعلي ولوحة المتابعة المختصرة ----------
create or replace function public.imp_counts(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.imp_staff;
begin
  s := public.imp_me(p_token);
  return jsonb_build_object(
    'sites',(select jsonb_agg(jsonb_build_object('code',st.code,'name',st.name,
        'count',(select count(*) from imp_vehicles v where v.site=st.code and public.imp_counted(v.status)),
        'pending',(select count(*) from imp_vehicles v where v.site=st.code and v.status=1)) order by st.sort)
       from imp_sites st where st.active),
    'in_transit',(select count(*) from imp_movements where state='in_transit'),
    'late_transit',(select count(*) from imp_movements where state='in_transit' and sent_at < now() - interval '1 day'),
    'pending_review',(select count(*) from imp_vehicles where status=1),
    'old_30',(select count(*) from imp_vehicles v join imp_sites st on st.code=v.site
              where st.active and public.imp_counted(v.status) and v.entry_at < now() - interval '30 days'),
    'legacy_inactive',(select count(*) from imp_vehicles v join imp_sites st on st.code=v.site
              where not st.active and public.imp_counted(v.status)));
end $$;

-- ---------- القوائم والبحث ----------
-- p_status: رقم الحالة، أو 0 للكل داخل الموقع، أو -1 للكل بما فيه الأرشيف
create or replace function public.imp_list(p_token text, p_site text default '', p_status int default 0,
                                           p_q text default '', p_limit int default 100, p_offset int default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.imp_staff; q text := btrim(coalesce(p_q,'')); qp text := public.imp_norm_plate(p_q); qv text := public.imp_norm_vin(p_q);
begin
  s := public.imp_me(p_token);
  return (select coalesce(jsonb_agg(r),'[]') from (
    select v.id, v.impound_no, v.plate, v.vin, v.make_model, v.color, v.status, v.site, st.name site_name,
           v.entry_at, v.exit_at, v.officer_name, v.has_belongings, v.legacy_row,
           (v.legacy->>'needs_review') = 'true' as legacy_review
    from imp_vehicles v join imp_sites st on st.code=v.site
    where (p_site = '' or v.site = p_site)
      and (s.role not in ('guard','dhahban') or public.imp_can_site(s,v.site))
      and (case when p_status = 0 then public.imp_counted(v.status) when p_status = -1 then true else v.status = p_status end)
      and (q = '' or v.impound_no = q or (qp<>'' and v.plate_key like '%'||qp||'%') or (qv<>'' and v.vin like '%'||qv||'%')
           or v.officer_name ilike '%'||q||'%' or v.id::text = q)
    order by v.status=1 desc, v.id desc
    limit least(greatest(p_limit,1),300) offset greatest(p_offset,0)) r);
end $$;

-- ---------- إدارة الموظفين (المدير) ----------
create or replace function public.imp_staff_list(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.imp_staff;
begin
  s := public.imp_me(p_token);
  perform public.imp_need(s, variadic '{}'::text[]);
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.role, x.username),'[]') from imp_staff x);
end $$;

create or replace function public.imp_staff_save(p_token text, p_username text, p_name text, p_role text, p_sites text[], p_active boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.imp_staff;
begin
  s := public.imp_me(p_token);
  perform public.imp_need(s, variadic '{}'::text[]);
  if lower(btrim(p_username)) = s.username and (p_role <> 'manager' or not p_active) then
    raise exception 'لا يمكنك إزالة صلاحية المدير عن نفسك';
  end if;
  insert into imp_staff(username,display_name,role,sites,active)
  values (lower(btrim(p_username)),coalesce(p_name,''),p_role,coalesce(p_sites,'{}'),coalesce(p_active,true))
  on conflict (username) do update set display_name=excluded.display_name, role=excluded.role, sites=excluded.sites, active=excluded.active;
  insert into imp_audit(username,action,changes) values (s.username,'staff_save',jsonb_build_object('user',p_username,'role',p_role,'sites',p_sites,'active',p_active));
  return jsonb_build_object('ok',true);
end $$;

-- =====================================================================
-- أول مدير: ضع اسم دخولك في البوابة بدل YOUR_USERNAME ثم نفّذ السطر
-- (بعدها يضيف المدير بقية الموظفين من شاشة «الموظفون»)
-- =====================================================================
-- insert into public.imp_staff(username,display_name,role) values (lower('YOUR_USERNAME'),'المدير','manager')
--   on conflict (username) do update set role='manager', active=true;
