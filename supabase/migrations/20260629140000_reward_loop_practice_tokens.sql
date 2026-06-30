-- Glitchyard reward loop: Practice Tokens currency + the Rookie Camp set.
-- (Already applied to the live project via the management API; this file keeps the repo migrations in sync
--  so a fresh project / CI build reproduces the same schema.)

-- Practice Tokens — a per-character currency earned in the Glitchyard, spent at the home Practice Vendor.
ALTER TABLE public.characters ADD COLUMN IF NOT EXISTS practice_tokens integer NOT NULL DEFAULT 0;

-- Allow the new vendor-only 'rookie_camp' set on inventory items (the sport sets stay valid).
ALTER TABLE public.inventory DROP CONSTRAINT IF EXISTS inventory_set_check;
ALTER TABLE public.inventory ADD CONSTRAINT inventory_set_check
  CHECK (set_id IS NULL OR set_id = ANY (ARRAY['baseball'::text, 'football'::text, 'volleyball'::text, 'soccer'::text, 'rookie_camp'::text]));
