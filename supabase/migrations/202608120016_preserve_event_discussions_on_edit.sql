-- Editing an event must never cascade-delete comments through event_sites.
-- Patch the function installed by 015 without duplicating the complete body.
do $$
declare
  definition text;
begin
  select pg_get_functiondef('public.review_event_submission(uuid,text,text,uuid)'::regprocedure)
    into definition;
  definition := regexp_replace(
    definition,
    E'\\n\\s*delete from public\\.event_sites where event_id = resolved_event_id;',
    '',
    'i'
  );
  execute definition;
end;
$$;
