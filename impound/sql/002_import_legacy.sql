-- =====================================================================
-- استيراد سجل المركبات الحالي (ملف الإكسل) إلى نظام الإيواء
-- قبل التنفيذ:
--   1) نفّذ 001_impound_phase1.sql
--   2) نفّذ legacy_vehicle_import.sql (ينشئ الجدول المؤقت)
--   3) من Table Editor → legacy_vehicle_import → Insert → Import data from CSV
--      واختر vehicles_clean.csv
-- ثم نفّذ هذا الملف. آمن لإعادة التنفيذ (لا يكرر الصفوف المستوردة).
-- =====================================================================
insert into public.imp_vehicles(
  impound_no, plate, plate_key, vin, vin_nonstandard, make_model, color, model_year, vehicle_class,
  officer_name, source_place, site, status, notes, entry_at, exit_at, created_by, reviewed_by, reviewed_at,
  legacy_row, legacy)
select
  coalesce(l.impound_no,''),
  coalesce(nullif(l.plate,''), ''),
  coalesce(nullif(l.plate_key,''), 'LEGACY:'||l.legacy_row),
  coalesce(l.vin,''),
  coalesce(l.vin,'') <> '' and not public.imp_vin_ok(l.vin),
  coalesce(l.make_model,''), coalesce(l.color,''),
  nullif(l.model_year,'')::int, coalesce(l.vehicle_class,''),
  coalesce(l.officer_name,''), coalesce(l.route_trips,''),
  case when l.site in ('khumra','harazat','dhahban','closed') then l.site else 'unassigned' end,
  case when l.status = 'released' then 7 else 2 end,
  coalesce(l.notes,''),
  nullif(l.entry_date,'')::timestamptz, nullif(l.exit_date,'')::timestamptz,
  'excel-import', 'excel-import', now(),
  l.legacy_row::int,
  to_jsonb(l)
from public.legacy_vehicle_import l
where not exists (select 1 from public.imp_vehicles v where v.legacy_row = l.legacy_row::int);

-- تحقق سريع بعد الاستيراد
select s.name, count(*) filter (where public.imp_counted(v.status)) as inside, count(*) filter (where v.status=7) as archived
from public.imp_vehicles v join public.imp_sites s on s.code=v.site
where v.legacy_row is not null group by s.name, s.sort order by s.sort;
