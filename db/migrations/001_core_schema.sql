-- =====================================================================
-- Plattform-Kernschema: Tenant, Theme, App, Freigabe (Grant), Instanz,
-- Rollen, Policy, Wissen, Audit + Beispiel-Datenobjekt (Ticket)
-- PostgreSQL 14+ | Mandantentrennung über Row-Level-Security (RLS)
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS citext;

-- ---------- Enums ----------------------------------------------------
CREATE TYPE audience_t        AS ENUM ('internal', 'external', 'public');
CREATE TYPE branding_mode_t   AS ENUM ('host', 'provider');
CREATE TYPE version_policy_t  AS ENUM ('auto', 'pinned');
CREATE TYPE status_t          AS ENUM ('draft', 'active', 'suspended', 'archived');
CREATE TYPE grant_status_t    AS ENUM ('pending', 'active', 'revoked', 'expired');
CREATE TYPE provider_access_t AS ENUM ('none', 'aggregated', 'full');
CREATE TYPE knowledge_status_t AS ENUM ('draft', 'reviewed', 'outdated');
CREATE TYPE visibility_t      AS ENUM ('internal', 'public');

-- ---------- Session-Kontext (wird pro Request/Transaktion gesetzt) ---
-- Backend setzt nach Authentifizierung per SET LOCAL:
--   app.user_id, app.tenant_id (aktiver Tenant), app.audience
CREATE FUNCTION current_user_id() RETURNS uuid
  LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$;

CREATE FUNCTION current_tenant_id() RETURNS uuid
  LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('app.tenant_id', true), '')::uuid $$;

CREATE FUNCTION current_audience() RETURNS audience_t
  LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('app.audience', true), '')::audience_t $$;

-- ---------- Tenant & Theme -------------------------------------------
CREATE TABLE tenant (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text NOT NULL,
  slug             text NOT NULL UNIQUE,
  status           status_t NOT NULL DEFAULT 'active',
  identity_pool_id text,                       -- SSO/OIDC-Konfiguration intern
  domains          text[] NOT NULL DEFAULT '{}',
  default_theme_id uuid,                       -- FK unten (zirkulär)
  premium_flags    jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- z. B. {"full_white_label":false,"custom_domain":null,
  --        "sender_domain":null,"store_app":false,"hide_powered_by":false}
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE theme (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_tenant_id uuid REFERENCES tenant(id) ON DELETE CASCADE,  -- NULL = Plattform-Theme
  name            text NOT NULL,
  tokens          jsonb NOT NULL,              -- Farben, Fonts, Radien, Abstände
  assets          jsonb NOT NULL DEFAULT '{}'::jsonb, -- Logo hell/dunkel, Favicon, Bilder
  version         int  NOT NULL DEFAULT 1,
  status          status_t NOT NULL DEFAULT 'draft'
);
-- Genau ein aktives Plattform-Theme (Login vor Authentifizierung)
CREATE UNIQUE INDEX one_active_platform_theme
  ON theme ((true)) WHERE owner_tenant_id IS NULL AND status = 'active';

ALTER TABLE tenant
  ADD CONSTRAINT tenant_default_theme_fk
  FOREIGN KEY (default_theme_id) REFERENCES theme(id) DEFERRABLE INITIALLY DEFERRED;

-- ---------- Nutzer & Mitgliedschaft ----------------------------------
CREATE TABLE app_user (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email      citext NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE membership (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id   uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  tenant_id uuid NOT NULL REFERENCES tenant(id)   ON DELETE CASCADE,
  audience  audience_t NOT NULL CHECK (audience IN ('internal','external')),
  status    status_t NOT NULL DEFAULT 'active',
  UNIQUE (user_id, tenant_id)
);
CREATE INDEX membership_tenant_idx ON membership(tenant_id);

-- ---------- App (Use Case) & Rollen ----------------------------------
CREATE TABLE app (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_tenant_id   uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  name              text NOT NULL,
  audience          audience_t NOT NULL DEFAULT 'internal',
  version           int NOT NULL DEFAULT 1,
  status            status_t NOT NULL DEFAULT 'draft',
  theme_override_id uuid REFERENCES theme(id),
  config            jsonb NOT NULL DEFAULT '{}'::jsonb  -- Views, Workflows als JSON
);
CREATE INDEX app_owner_idx ON app(owner_tenant_id);

-- Rollen werden vom App-Anbieter definiert
CREATE TABLE app_role (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id      uuid NOT NULL REFERENCES app(id) ON DELETE CASCADE,
  key         text NOT NULL,
  name        text NOT NULL,
  permissions jsonb NOT NULL DEFAULT '{}'::jsonb, -- pro Maske/Aktion/Feld
  UNIQUE (app_id, key)
);

-- ---------- Freigabe (Grant) & Instanz (Datenraum) -------------------
CREATE TABLE app_grant (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_tenant_id   uuid NOT NULL REFERENCES tenant(id),
  recipient_tenant_id  uuid NOT NULL REFERENCES tenant(id),
  app_id               uuid NOT NULL REFERENCES app(id),
  branding_mode        branding_mode_t NOT NULL DEFAULT 'provider',
  version_policy       version_policy_t NOT NULL DEFAULT 'auto',
  pinned_version       int,
  provider_data_access provider_access_t NOT NULL DEFAULT 'none',
  valid_from           timestamptz NOT NULL DEFAULT now(),
  valid_to             timestamptz,
  status               grant_status_t NOT NULL DEFAULT 'pending',
  approved_by_provider uuid REFERENCES app_user(id),
  approved_by_recipient uuid REFERENCES app_user(id),
  CHECK (provider_tenant_id <> recipient_tenant_id),
  CHECK (version_policy = 'auto' OR pinned_version IS NOT NULL),
  -- Vier-Augen-Prinzip: aktiv nur mit beiden Zustimmungen
  CHECK (status <> 'active'
         OR (approved_by_provider IS NOT NULL AND approved_by_recipient IS NOT NULL))
);
CREATE INDEX grant_provider_idx  ON app_grant(provider_tenant_id);
CREATE INDEX grant_recipient_idx ON app_grant(recipient_tenant_id);

-- Welche Rollen der Anbieter für diese Freigabe überhaupt anbietet
CREATE TABLE grant_role (
  grant_id uuid NOT NULL REFERENCES app_grant(id) ON DELETE CASCADE,
  role_id  uuid NOT NULL REFERENCES app_role(id)  ON DELETE CASCADE,
  PRIMARY KEY (grant_id, role_id)
);

-- Datenraum: tenant_id = DATENEIGENTÜMER (bei Freigabe = Empfänger)
CREATE TABLE app_instance (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_id    uuid NOT NULL REFERENCES app(id),
  grant_id  uuid UNIQUE REFERENCES app_grant(id),  -- NULL = eigene App des Tenants
  tenant_id uuid NOT NULL REFERENCES tenant(id),
  status    status_t NOT NULL DEFAULT 'active'
);
CREATE INDEX instance_tenant_idx ON app_instance(tenant_id);

-- Empfänger weist Rollen den eigenen Nutzern zu (delegierte Administration)
CREATE TABLE role_assignment (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id   uuid NOT NULL REFERENCES app_instance(id) ON DELETE CASCADE,
  membership_id uuid NOT NULL REFERENCES membership(id)   ON DELETE CASCADE,
  role_id       uuid NOT NULL REFERENCES app_role(id),
  valid_to      timestamptz,                  -- befristete Rechte
  assigned_by   uuid REFERENCES app_user(id),
  UNIQUE (instance_id, membership_id, role_id)
);

-- ---------- Policy (Leitplanken pro Tenant) --------------------------
CREATE TABLE policy (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  key       text NOT NULL,   -- z. B. 'third_party_apps_branding', 'external_publish_requires_4eyes'
  value     jsonb NOT NULL,
  UNIQUE (tenant_id, key)
);

-- ---------- Wissen ----------------------------------------------------
CREATE TABLE knowledge_source (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_tenant_id uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  title           text NOT NULL,
  status          knowledge_status_t NOT NULL DEFAULT 'draft',
  version         int NOT NULL DEFAULT 1,
  reviewer_id     uuid REFERENCES app_user(id),
  valid_until     date,
  audience        audience_t NOT NULL DEFAULT 'internal'
);

-- Die KI greift NUR über Links zu. Bei Freigaben: grant_id gesetzt.
CREATE TABLE knowledge_link (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES knowledge_source(id) ON DELETE CASCADE,
  app_id    uuid NOT NULL REFERENCES app(id) ON DELETE CASCADE,
  grant_id  uuid REFERENCES app_grant(id) ON DELETE CASCADE,
  UNIQUE NULLS NOT DISTINCT (source_id, app_id, grant_id)   -- PG15+
);

-- ---------- Audit -----------------------------------------------------
CREATE TABLE audit_event (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  actor_id    uuid,
  tenant_id   uuid,
  instance_id uuid,
  action      text NOT NULL,        -- 'grant.approve', 'ai.answer', 'ticket.read' ...
  detail      jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX audit_tenant_at_idx ON audit_event(tenant_id, at DESC);

-- ---------- Beispiel-Datenobjekt: Ticket ----------------------------
CREATE TABLE ticket (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  instance_id uuid NOT NULL REFERENCES app_instance(id),
  source      text NOT NULL CHECK (source IN ('email','aircall','webform')),
  subject     text NOT NULL,
  body        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ticket_tenant_instance_idx ON ticket(tenant_id, instance_id);

CREATE TABLE ticket_comment (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id   uuid NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  instance_id uuid NOT NULL REFERENCES app_instance(id),
  visibility  visibility_t NOT NULL DEFAULT 'internal',
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- RLS-Hilfsfunktionen (SECURITY DEFINER vermeidet Rekursion/Overhead)
-- =====================================================================

-- Darf der aktive Tenant (als Anbieter) die Daten dieser Instanz sehen?
CREATE FUNCTION provider_has_full_access(p_instance uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
$$
  SELECT EXISTS (
    SELECT 1
    FROM app_instance i
    JOIN app_grant g ON g.id = i.grant_id
    WHERE i.id = p_instance
      AND g.provider_tenant_id = current_tenant_id()
      AND g.provider_data_access = 'full'
      AND g.status = 'active'
      AND (g.valid_to IS NULL OR g.valid_to > now())
  )
$$;

-- Ist die Instanz für den aktiven Tenant aktiv und (bei Grant) gültig?
CREATE FUNCTION instance_usable(p_instance uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
$$
  SELECT EXISTS (
    SELECT 1
    FROM app_instance i
    LEFT JOIN app_grant g ON g.id = i.grant_id
    WHERE i.id = p_instance
      AND i.tenant_id = current_tenant_id()
      AND i.status = 'active'
      AND (g.id IS NULL
           OR (g.status = 'active' AND (g.valid_to IS NULL OR g.valid_to > now())))
  )
$$;

-- =====================================================================
-- RLS aktivieren (FORCE: gilt auch für den Tabellen-Owner)
-- =====================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'tenant','theme','membership','app','app_role','app_grant','grant_role',
    'app_instance','role_assignment','policy','knowledge_source',
    'knowledge_link','audit_event','ticket','ticket_comment'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY',  t);
  END LOOP;
END $$;

-- ---------- Policies --------------------------------------------------

-- tenant: nur der aktive Tenant
CREATE POLICY tenant_rw ON tenant
  USING (id = current_tenant_id()) WITH CHECK (id = current_tenant_id());

-- theme: Plattform-Theme für alle lesbar, Tenant-Themes nur vom Eigentümer.
-- Für Provider-Branding: Theme des Anbieters ist lesbar, wenn eine aktive Freigabe existiert.
CREATE POLICY theme_read ON theme FOR SELECT USING (
  owner_tenant_id IS NULL
  OR owner_tenant_id = current_tenant_id()
  OR EXISTS (SELECT 1 FROM app_grant g
             WHERE g.provider_tenant_id = theme.owner_tenant_id
               AND g.recipient_tenant_id = current_tenant_id()
               AND g.status = 'active')
);
CREATE POLICY theme_write ON theme FOR ALL
  USING (owner_tenant_id = current_tenant_id())
  WITH CHECK (owner_tenant_id = current_tenant_id());

-- membership: eigener Tenant ODER eigene Mitgliedschaften (Org-Switcher)
CREATE POLICY membership_read ON membership FOR SELECT
  USING (tenant_id = current_tenant_id() OR user_id = current_user_id());
CREATE POLICY membership_write ON membership FOR ALL
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

-- app: Eigentümer ODER Empfänger einer aktiven Freigabe (lesend)
CREATE POLICY app_read ON app FOR SELECT USING (
  owner_tenant_id = current_tenant_id()
  OR EXISTS (SELECT 1 FROM app_grant g
             WHERE g.app_id = app.id
               AND g.recipient_tenant_id = current_tenant_id()
               AND g.status = 'active')
);
CREATE POLICY app_write ON app FOR ALL
  USING (owner_tenant_id = current_tenant_id())
  WITH CHECK (owner_tenant_id = current_tenant_id());

-- app_role: sichtbar wie die App; ändern nur der Anbieter
CREATE POLICY app_role_read ON app_role FOR SELECT
  USING (EXISTS (SELECT 1 FROM app a WHERE a.id = app_role.app_id));
CREATE POLICY app_role_write ON app_role FOR ALL
  USING (EXISTS (SELECT 1 FROM app a
                 WHERE a.id = app_role.app_id AND a.owner_tenant_id = current_tenant_id()))
  WITH CHECK (EXISTS (SELECT 1 FROM app a
                 WHERE a.id = app_role.app_id AND a.owner_tenant_id = current_tenant_id()));

-- app_grant: beide Seiten lesen; Anbieter legt an; beide dürfen ihre Zustimmung setzen
CREATE POLICY grant_read ON app_grant FOR SELECT
  USING (provider_tenant_id = current_tenant_id() OR recipient_tenant_id = current_tenant_id());
CREATE POLICY grant_insert ON app_grant FOR INSERT
  WITH CHECK (provider_tenant_id = current_tenant_id());
CREATE POLICY grant_update ON app_grant FOR UPDATE
  USING (provider_tenant_id = current_tenant_id() OR recipient_tenant_id = current_tenant_id());
-- Hinweis: Welche Spalte wer ändern darf (z. B. nur Empfänger setzt approved_by_recipient),
-- per Column-GRANTs oder in der Service-Schicht erzwingen.

CREATE POLICY grant_role_read ON grant_role FOR SELECT USING (
  EXISTS (SELECT 1 FROM app_grant g WHERE g.id = grant_role.grant_id));
CREATE POLICY grant_role_write ON grant_role FOR ALL
  USING (EXISTS (SELECT 1 FROM app_grant g
                 WHERE g.id = grant_role.grant_id AND g.provider_tenant_id = current_tenant_id()))
  WITH CHECK (EXISTS (SELECT 1 FROM app_grant g
                 WHERE g.id = grant_role.grant_id AND g.provider_tenant_id = current_tenant_id()));

-- app_instance: Dateneigentümer; Anbieter sieht nur die Instanz-Metadaten
CREATE POLICY instance_read ON app_instance FOR SELECT USING (
  tenant_id = current_tenant_id()
  OR EXISTS (SELECT 1 FROM app_grant g
             WHERE g.id = app_instance.grant_id
               AND g.provider_tenant_id = current_tenant_id())
);
CREATE POLICY instance_write ON app_instance FOR ALL
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

-- role_assignment: nur der Empfänger (Instanz-Eigentümer)
CREATE POLICY role_assignment_rw ON role_assignment FOR ALL
  USING (EXISTS (SELECT 1 FROM app_instance i
                 WHERE i.id = role_assignment.instance_id
                   AND i.tenant_id = current_tenant_id()))
  WITH CHECK (EXISTS (SELECT 1 FROM app_instance i
                 WHERE i.id = role_assignment.instance_id
                   AND i.tenant_id = current_tenant_id()));

-- policy: nur eigener Tenant
CREATE POLICY policy_rw ON policy
  USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id());

-- knowledge_source: nur Eigentümer. Externe sehen nur extern freigegebene Quellen.
CREATE POLICY knowledge_rw ON knowledge_source FOR ALL
  USING (owner_tenant_id = current_tenant_id()
         AND (current_audience() = 'internal' OR audience IN ('external','public')))
  WITH CHECK (owner_tenant_id = current_tenant_id());

-- knowledge_link: sichtbar, wenn die zugehörige Quelle sichtbar ist
CREATE POLICY knowledge_link_read ON knowledge_link FOR SELECT USING (
  EXISTS (SELECT 1 FROM knowledge_source s WHERE s.id = knowledge_link.source_id));
CREATE POLICY knowledge_link_write ON knowledge_link FOR ALL
  USING (EXISTS (SELECT 1 FROM knowledge_source s WHERE s.id = knowledge_link.source_id))
  WITH CHECK (EXISTS (SELECT 1 FROM knowledge_source s WHERE s.id = knowledge_link.source_id));

-- audit_event: nur eigener Tenant lesen, jeder darf schreiben (append-only)
CREATE POLICY audit_read   ON audit_event FOR SELECT USING (tenant_id = current_tenant_id());
CREATE POLICY audit_insert ON audit_event FOR INSERT WITH CHECK (true);

-- ticket: Dateneigentümer (Instanz gültig) ODER Anbieter mit provider_data_access='full'
CREATE POLICY ticket_owner ON ticket FOR ALL
  USING (tenant_id = current_tenant_id() AND instance_usable(instance_id))
  WITH CHECK (tenant_id = current_tenant_id() AND instance_usable(instance_id));
CREATE POLICY ticket_provider ON ticket FOR SELECT
  USING (provider_has_full_access(instance_id));

-- ticket_comment: Externe sehen NIE interne Kommentare
CREATE POLICY comment_owner ON ticket_comment FOR ALL
  USING (tenant_id = current_tenant_id()
         AND instance_usable(instance_id)
         AND (visibility = 'public' OR current_audience() = 'internal'))
  WITH CHECK (tenant_id = current_tenant_id() AND instance_usable(instance_id));
CREATE POLICY comment_provider ON ticket_comment FOR SELECT
  USING (visibility = 'public' AND provider_has_full_access(instance_id));

-- =====================================================================
-- Laufzeit-Rolle (KEIN Superuser, KEIN BYPASSRLS, nicht Tabellen-Owner)
-- =====================================================================
CREATE ROLE app_runtime NOLOGIN;
GRANT USAGE ON SCHEMA public TO app_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_runtime;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_runtime;
REVOKE UPDATE, DELETE ON audit_event FROM app_runtime;   -- append-only

-- =====================================================================
-- Nutzung im Backend (pro Request, innerhalb einer Transaktion):
--
--   BEGIN;
--   SET LOCAL ROLE app_runtime;
--   SELECT set_config('app.user_id',   '<user-uuid>',   true);
--   SELECT set_config('app.tenant_id', '<tenant-uuid>', true);
--   SELECT set_config('app.audience',  'internal',      true);
--   -- ... Abfragen ...
--   COMMIT;
--
-- Wichtig: Kontext aus dem verifizierten Token ableiten, nie aus Client-Eingaben.
-- Bei Connection-Pooling immer set_config(..., true) (transaktionslokal) verwenden.
-- =====================================================================
