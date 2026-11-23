-- 005: إظهار صور الأرشيف القديم داخل ملف المركبة الحالي إذا تطابقت اللوحة
-- شغّله مرة واحدة في SQL Editor. لا يغيّر أي بيانات، فقط يحدّث دالة عرض الملف.

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
