-- جدول مؤقت لاستيراد سجل المركبات الحالي (من ملف الإكسل)
-- الخطوات: 1) نفّذ هذا الملف في SQL Editor في Supabase
--          2) من Table Editor افتح legacy_vehicle_import ثم Import data from CSV واختر vehicles_clean.csv
-- كل الأعمدة نصية حتى يقبل الاستيراد الخلايا الفارغة. بعدها نفّذ 002_import_legacy.sql.
create table if not exists public.legacy_vehicle_import (
  legacy_row text,
  impound_no text,
  plate_raw text,
  plate text,
  vin text,
  plate_key text,
  make_model text,
  color text,
  plates_count text,
  model_year text,
  vehicle_class text,
  entry_date text,
  exit_date text,
  exit_branch_raw text,
  site text,
  site_raw text,
  status text,
  bay text,
  impound_reason text,
  department text,
  authority text,
  case_no text,
  officer_name text,
  has_key text,
  is_registered text,
  tow_driver text,
  purchase_by text,
  route_trips text,
  receiver text,
  owner_name text,
  owner_phone text,
  transfer_driver text,
  transfer_date_raw text,
  notes text,
  extra_col text,
  issues text,
  needs_review text,
  imported_at timestamptz default now(),
  primary key (legacy_row)
);
alter table public.legacy_vehicle_import enable row level security;
-- لا توجد سياسات عامة: الجدول لا يُقرأ إلا من الخادم أو من لوحة Supabase.
