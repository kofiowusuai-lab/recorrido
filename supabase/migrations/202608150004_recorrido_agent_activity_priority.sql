begin;

create materialized view public.recorrido_outreach_agent_activity_priority as
with source_rows as (
  select
    r.workspace_id,
    r.promoted_lead_id as lead_id,
    r.id as import_row_id,
    case
      when coalesce(r.raw_payload->>'active_listings', '') ~ '^[0-9]+$'
        then (r.raw_payload->>'active_listings')::integer
      else null
    end as active_listing_count,
    case
      when coalesce(r.raw_payload->>'harvested_at', '') ~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}'
        then (r.raw_payload->>'harvested_at')::timestamptz
      else null
    end as source_harvested_at,
    nullif(btrim(r.raw_payload->>'country'), '') as source_country,
    nullif(btrim(r.raw_payload->>'department'), '') as source_department,
    nullif(btrim(r.raw_payload->>'city'), '') as source_city,
    (
      (case when upper(coalesce(r.raw_payload->>'contactable_whatsapp', '')) = 'Y' then 1 else 0 end) +
      (case when upper(coalesce(r.raw_payload->>'contactable_phone', '')) = 'Y' then 1 else 0 end) +
      (case when upper(coalesce(r.raw_payload->>'contactable_email', '')) = 'Y' then 1 else 0 end)
    ) as contact_coverage_count,
    row_number() over (
      partition by r.workspace_id, r.promoted_lead_id
      order by
        case
          when coalesce(r.raw_payload->>'active_listings', '') ~ '^[0-9]+$'
            then (r.raw_payload->>'active_listings')::integer
          else null
        end desc nulls last,
        case
          when coalesce(r.raw_payload->>'harvested_at', '') ~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}'
            then (r.raw_payload->>'harvested_at')::timestamptz
          else null
        end desc nulls last,
        (
          (case when upper(coalesce(r.raw_payload->>'contactable_whatsapp', '')) = 'Y' then 1 else 0 end) +
          (case when upper(coalesce(r.raw_payload->>'contactable_phone', '')) = 'Y' then 1 else 0 end) +
          (case when upper(coalesce(r.raw_payload->>'contactable_email', '')) = 'Y' then 1 else 0 end)
        ) desc,
        r.id
    ) as evidence_rank
  from public.recorrido_outreach_import_rows r
  where r.promotion_state = 'promoted'
    and r.promoted_lead_id is not null
),
source_stats as (
  select
    workspace_id,
    lead_id,
    count(*)::integer as source_evidence_count,
    count(distinct active_listing_count)::integer as distinct_activity_values
  from source_rows
  group by workspace_id, lead_id
),
selected as (
  select
    l.workspace_id,
    l.id as lead_id,
    l.display_name,
    l.lead_kind,
    coalesce(s.source_country, nullif(btrim(l.country), ''), 'unknown') as country,
    coalesce(s.source_department, 'unknown') as department,
    coalesce(s.source_city, nullif(btrim(l.market), ''), 'unknown') as city,
    s.active_listing_count,
    s.source_harvested_at,
    s.contact_coverage_count,
    st.source_evidence_count,
    st.distinct_activity_values,
    st.distinct_activity_values > 1 as activity_conflicted,
    s.import_row_id as ranking_evidence_row_id
  from public.recorrido_outreach_leads l
  join source_rows s
    on s.workspace_id = l.workspace_id
   and s.lead_id = l.id
   and s.evidence_rank = 1
  join source_stats st
    on st.workspace_id = l.workspace_id
   and st.lead_id = l.id
  where l.lifecycle_status = 'staged'
),
ranked as (
  select
    selected.*,
    row_number() over (
      partition by workspace_id
      order by active_listing_count desc nulls last,
               source_harvested_at desc nulls last,
               contact_coverage_count desc,
               lead_id
    ) as global_activity_rank,
    row_number() over (
      partition by workspace_id, country, department, city
      order by active_listing_count desc nulls last,
               source_harvested_at desc nulls last,
               contact_coverage_count desc,
               lead_id
    ) as regional_activity_rank
  from selected
)
select
  workspace_id,
  lead_id,
  display_name,
  lead_kind,
  country,
  department,
  city,
  active_listing_count,
  source_harvested_at,
  contact_coverage_count,
  source_evidence_count,
  distinct_activity_values,
  activity_conflicted,
  global_activity_rank,
  regional_activity_rank,
  ranking_evidence_row_id,
  'most_active_by_region'::text as ranking_label,
  now() as ranked_at
from ranked
with no data;

create unique index recorrido_agent_activity_priority_identity_idx
  on public.recorrido_outreach_agent_activity_priority(workspace_id, lead_id);
create index recorrido_agent_activity_priority_global_idx
  on public.recorrido_outreach_agent_activity_priority(workspace_id, global_activity_rank);
create index recorrido_agent_activity_priority_region_idx
  on public.recorrido_outreach_agent_activity_priority(
    workspace_id, country, department, city, regional_activity_rank
  );

revoke all on public.recorrido_outreach_agent_activity_priority from public, anon, authenticated;
grant select on public.recorrido_outreach_agent_activity_priority to service_role;

refresh materialized view public.recorrido_outreach_agent_activity_priority;

comment on materialized view public.recorrido_outreach_agent_activity_priority is
  'Private, non-authorizing lead priority surface. Ranks agents by source-reported active listings, then source harvest time and contact coverage. It does not enroll, assign, authorize, or send outreach.';

commit;
