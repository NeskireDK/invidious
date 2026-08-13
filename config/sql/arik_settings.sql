-- Table: public.arik_settings

-- DROP TABLE public.arik_settings;

CREATE TABLE IF NOT EXISTS public.arik_settings
(
  key text NOT NULL,
  value jsonb NOT NULL,
  updated timestamp with time zone,
  CONSTRAINT arik_settings_key_key PRIMARY KEY (key)
);

GRANT ALL ON TABLE public.arik_settings TO current_user;
