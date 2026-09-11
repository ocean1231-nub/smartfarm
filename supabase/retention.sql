-- ============================================================
-- retention.sql : 4단 피라미드 저장 구조
--   실시간(raw, 30일) → 5분 평균(7일 화면용) → 시간별 평균(60일)
--   → 일별 평균(영구 누적)
--
-- 각 단계가 대시보드 탭 하나씩과 1:1 대응:
--   실시간 탭      -> sensor_data (raw)
--   최근 7일 탭    -> sensor_5min
--   최근 2개월 탭  -> sensor_hourly
--   전체 기간 탭   -> sensor_daily
--
-- 실행 전: Supabase 대시보드 > Database > Extensions 에서 pg_cron 켜기.
-- 여러 번 실행해도 안전 (예전 sensor_5min "뷰"가 있으면 자동으로 정리하고
-- 테이블로 교체함).
-- ============================================================

-- 0) 예전 뷰 정리 (enable-public-read.sql 구버전에서 만들었던 것)
drop view if exists public.sensor_5min cascade;

-- ------------------------------------------------------------
-- 공통: 정책 등록용 헬퍼 없음 — 테이블마다 반복해서 명시 작성
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- 1) 5분 평균 테이블  (대시보드 "최근 7일" 탭 소스)
-- ------------------------------------------------------------
create table if not exists public.sensor_5min (
  bucket    timestamptz primary key,
  ph        numeric,
  ec        numeric,
  temp      numeric,
  humidity  numeric,
  samples   int
);
alter table public.sensor_5min enable row level security;
drop policy if exists "Public can read sensor 5min" on public.sensor_5min;
create policy "Public can read sensor 5min"
  on public.sensor_5min for select to anon using (true);

create or replace function public.refresh_sensor_5min()
returns void language plpgsql as $$
begin
  insert into public.sensor_5min (bucket, ph, ec, temp, humidity, samples)
  select date_bin('5 minutes', created_at, timestamptz '2000-01-01'),
         round(avg("PH")::numeric, 2),
         round(avg("EC")::numeric, 2),
         round(avg("온도")::numeric, 1),
         round(avg("습도")::numeric, 1),
         count(*)
  from public.sensor_data
  where created_at >= now() - interval '1 day'   -- 최근 하루치만 다시 계산 (버퍼)
  group by 1
  on conflict (bucket) do update set
    ph = excluded.ph, ec = excluded.ec, temp = excluded.temp,
    humidity = excluded.humidity, samples = excluded.samples;
end $$;

-- ------------------------------------------------------------
-- 2) 시간별 평균 테이블  (대시보드 "최근 2개월" 탭 소스)
-- ------------------------------------------------------------
create table if not exists public.sensor_hourly (
  hour      timestamptz primary key,
  ph        numeric,
  ec        numeric,
  temp      numeric,
  humidity  numeric,
  samples   int
);
alter table public.sensor_hourly enable row level security;
drop policy if exists "Public can read sensor hourly" on public.sensor_hourly;
create policy "Public can read sensor hourly"
  on public.sensor_hourly for select to anon using (true);

create or replace function public.refresh_sensor_hourly()
returns void language plpgsql as $$
begin
  insert into public.sensor_hourly (hour, ph, ec, temp, humidity, samples)
  select date_trunc('hour', created_at),
         round(avg("PH")::numeric, 2),
         round(avg("EC")::numeric, 2),
         round(avg("온도")::numeric, 1),
         round(avg("습도")::numeric, 1),
         count(*)
  from public.sensor_data
  where created_at >= now() - interval '2 days'  -- 최근 이틀치만 다시 계산 (버퍼)
  group by 1
  on conflict (hour) do update set
    ph = excluded.ph, ec = excluded.ec, temp = excluded.temp,
    humidity = excluded.humidity, samples = excluded.samples;
end $$;

-- ------------------------------------------------------------
-- 3) 일별 평균 테이블  (대시보드 "전체 기간" 탭 소스)
-- ------------------------------------------------------------
create table if not exists public.sensor_daily (
  day       date primary key,
  ph        numeric,
  ec        numeric,
  temp      numeric,
  humidity  numeric,
  samples   int
);
alter table public.sensor_daily enable row level security;
drop policy if exists "Public can read sensor daily" on public.sensor_daily;
create policy "Public can read sensor daily"
  on public.sensor_daily for select to anon using (true);

create or replace function public.refresh_sensor_daily()
returns void language plpgsql as $$
begin
  insert into public.sensor_daily (day, ph, ec, temp, humidity, samples)
  select (created_at at time zone 'Asia/Seoul')::date,
         round(avg("PH")::numeric, 2),
         round(avg("EC")::numeric, 2),
         round(avg("온도")::numeric, 1),
         round(avg("습도")::numeric, 1),
         count(*)
  from public.sensor_data
  where created_at >= now() - interval '3 days'  -- 최근 3일치 다시 계산 (버퍼)
  group by 1
  on conflict (day) do update set
    ph = excluded.ph, ec = excluded.ec, temp = excluded.temp,
    humidity = excluded.humidity, samples = excluded.samples;
end $$;

-- ------------------------------------------------------------
-- 4) 보존기간 정리
--    raw 는 30일, sensor_5min 은 14일(화면은 7일만 쓰지만 버퍼 2배),
--    sensor_hourly 는 60일 지나면 삭제 — 그 시점엔 sensor_daily 가
--    이미 (raw 기준으로 독립적으로) 그 날짜를 갖고 있으므로 정보 유실 없음.
--    sensor_daily 는 영구 보관(용량 미미, 안 지움).
-- ------------------------------------------------------------
create or replace function public.prune_sensor_data()
returns void language plpgsql as $$
begin
  -- 안전망: 지우기 전에 세 롤업 모두 한 번 더 강제 실행
  perform public.refresh_sensor_5min();
  perform public.refresh_sensor_hourly();
  perform public.refresh_sensor_daily();

  delete from public.sensor_data  where created_at < now() - interval '30 days';
  delete from public.sensor_5min  where bucket      < now() - interval '14 days';
  delete from public.sensor_hourly where hour        < now() - interval '60 days';
end $$;

-- ------------------------------------------------------------
-- 5) 스케줄 등록 (cron 표현식은 UTC 기준)
--    - 5분 평균 갱신: 5분마다
--    - 시간별 평균 갱신: 30분마다
--    - 일별 평균 갱신: 10분마다
--    - 보존기간 정리: 매일 18:00 UTC = 03:00 KST
-- ------------------------------------------------------------
select cron.unschedule(jobname)
  from cron.job
  where jobname in ('sensor-5min-refresh', 'sensor-hourly-refresh',
                     'sensor-daily-refresh', 'sensor-data-prune');

select cron.schedule('sensor-5min-refresh', '*/5 * * * *',
                     $$select public.refresh_sensor_5min()$$);
select cron.schedule('sensor-hourly-refresh', '*/30 * * * *',
                     $$select public.refresh_sensor_hourly()$$);
select cron.schedule('sensor-daily-refresh', '*/10 * * * *',
                     $$select public.refresh_sensor_daily()$$);
select cron.schedule('sensor-data-prune', '0 18 * * *',
                     $$select public.prune_sensor_data()$$);

-- 지금 바로 한 번 채우기 (주기 기다리지 않고 바로 데이터 뜨게)
select public.refresh_sensor_5min();
select public.refresh_sensor_hourly();
select public.refresh_sensor_daily();

-- PostgREST 스키마 캐시 새로고침
notify pgrst, 'reload schema';

-- 등록된 크론 확인:
--   select jobname, schedule, command from cron.job;
-- 각 테이블 상태 확인:
--   select count(*) from public.sensor_5min;
--   select count(*) from public.sensor_hourly;
--   select count(*) from public.sensor_daily;
--   select count(*) from public.sensor_data;
