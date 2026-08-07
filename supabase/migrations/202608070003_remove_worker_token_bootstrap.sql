-- Remove the one-time bootstrap RPC after hosted Supabase confirmed that
-- legacy database JWT signing material is unavailable on this project.
drop function if exists public.recorrido_bootstrap_worker_tokens();
