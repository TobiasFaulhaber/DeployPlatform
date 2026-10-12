-- =====================================================================
-- Migration v2 – Wissen hängt an der App, Transaktionen folgen der Integration
--
-- Voraussetzung: platform_core_schema.sql und platform_knowledge_pgvector.sql
-- sind eingespielt. Die betroffenen Tabellen (knowledge_source, ticket) müssen
-- leer sein, sonst vorher Daten migrieren (neue NOT-NULL-Spalten).
--
-- Neues Modell:
--   1. APP-NATIVES WISSEN  (scope='app')
--      Gehört dem Publisher der App, hängt direkt an der App und wird mit ihr
--      ausgeliefert: Veröffentlichung der App = Veröffentlichung des Wissens.
--   2. MANDANTENSPEZIFISCHES WISSEN (scope='tenant')
--      Gehört dem Mandanten, dem die App-Instanz gehört. Der Publisher sieht es nie.
--   3. TRANSAKTIONEN (Tickets, Kommentare, ...)
--      Gehören dem Eigentümer der INTEGRATION (Postfach, Aircall, Webform, API),
--      über die sie entstehen – nicht automatisch dem Instanz-Eigentümer und
--      nicht dem Publisher.
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- 0) Härtung des Kernschemas
-- ---------------------------------------------------------------------
-- app_user war ohne RLS: jeder Mandant hätte alle E-Mail-Adressen lesen können.
-- Login/Registrierung läuft über einen separaten Identity-Service (eigene DB-Rolle).
ALTER TABLE app_user ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_user FORCE  ROW LEVEL SECURITY;
CREATE POLICY app_user_read ON app_user FOR SELECT USING (
  id = current_user_id()
  OR (current_audience() = 'internal' AND EXISTS (
        SELECT 1 FROM membership m
        WHERE m.user_id = app_user.id AND m.tenant_id = current_tenant_id()))
);
REVOKE INSERT, UPDATE, DELETE ON app_user FROM app_runtime;

-- Mitgliedschaften: Externe sehen nur die eigene, Schreiben nur intern
DROP POLICY membership_read  ON membership;
DROP POLICY membership_write ON membership;
CREATE POLICY membership_read ON membership FOR SELECT USING (
  user_id = current_user_id()                                   -- Org-Switcher
  OR (tenant_id = current_tenant_id() AND current_audience() = 'internal')
);
CREATE POLICY membership_write ON membership FOR ALL
  USING      (tenant_id = current_tenant_id() AND current_audience() = 'internal')
  WITH CHECK (tenant_id = current_tenant_id() AND current_audience() = 'internal');

-- ---------------------------------------------------------------------
-- 1) Zugriff des Anbieters auf Transaktionsdaten entfällt
--    (Zugriff folgt künftig ausschließlich dem Integrations-Eigentümer)
-- ---------------------------------------------------------------------
DROP POLICY ticket_owner     ON ticket;
DROP POLICY ticket_provider  ON ticket;
DROP POLICY comment_owner    ON ticket_comment;
DROP POLICY comment_provider ON ticket_comment;
DROP FUNCTION provider_has_full_access(uuid);
ALTER TABLE app_grant DROP COLUMN provider_data_access;
DROP TYPE provider_access_t;

-- ---------------------------------------------------------------------
-- 2) Wissens-Scopes: 'app' (nativ) und 'tenant' (mandantenspezifisch)
-- ---------------------------------------------------------------------
CREATE TYPE knowledge_scope_t AS ENUM ('app', 'tenant');

ALTER TABLE knowledge_source
  ADD COLUMN scope       knowledge_scope_t NOT NULL,
  ADD COLUMN app_id      uuid REFERENCES app(id)          ON DELETE CASCADE,
  ADD COLUMN instance_id uuid REFERENCES app_instance(id) ON DELETE CASCADE,
  ADD CONSTRAINT knowledge_scope_chk CHECK (
       (scope = 'app'    AND app_id      IS NOT NULL AND instance_id IS NULL)
    OR (scope = 'tenant' AND instance_id IS NOT NULL AND app_id      IS NULL));

CREATE INDEX knowledge_source_app_idx      ON knowledge_source (app_id)      WHERE scope = 'app';
CREATE INDEX knowledge_source_instance_idx ON knowledge_source (instance_id) WHERE scope = 'tenant';

-- Eigentümer wird immer abgeleitet, nie vom Client übernommen:
--   scope 'app'    -> Eigentümer der App (Publisher)
--   scope 'tenant' -> Eigentümer der Instanz (Mandant)
-- Läuft mit den Rechten des Aufrufers: nicht sichtbare App/Instanz => Fehler.
CREATE FUNCTION knowledge_source_set_owner() RETURNS trigger
  LANGUAGE plpgsql AS
$$
BEGIN
  IF NEW.scope = 'app' THEN
    SELECT a.owner_tenant_id INTO NEW.owner_tenant_id
    FROM app a WHERE a.id = NEW.app_id;
  ELSE
    SELECT i.tenant_id INTO NEW.owner_tenant_id
    FROM app_instance i WHERE i.id = NEW.instance_id;
  END IF;
  IF NEW.owner_tenant_id IS NULL THEN
    RAISE EXCEPTION 'unknown or inaccessible app/instance' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER knowledge_source_owner_trg
  BEFORE INSERT OR UPDATE OF scope, app_id, instance_id ON knowledge_source
  FOR EACH ROW EXECUTE FUNCTION knowledge_source_set_owner();

-- Schreiben nur intern durch den Eigentümer; Externe sehen nur extern freigegebenes
DROP POLICY knowledge_rw ON knowledge_source;
CREATE POLICY knowledge_read ON knowledge_source FOR SELECT USING (
  owner_tenant_id = current_tenant_id()
  AND (current_audience() = 'internal' OR audience IN ('external','public'))
);
CREATE POLICY knowledge_write ON knowledge_source FOR ALL
  USING      (owner_tenant_id = current_tenant_id() AND current_audience() = 'internal')
  WITH CHECK (owner_tenant_id = current_tenant_id() AND current_audience() = 'internal');

-- ---------------------------------------------------------------------
-- 3) Suche: Wissen kommt mit der App bzw. gehört dem Instanz-Mandanten
--    (gleiche Signatur wie bisher => Owner und Rechte bleiben erhalten)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION knowledge_search(
  p_instance        uuid,
  p_query_embedding vector(1536),
  p_embedding_model text,
  p_query_text      text DEFAULT NULL,
  p_limit           int  DEFAULT 8,
  p_min_score       real DEFAULT 0.55
) RETURNS TABLE (
  query_id       uuid,
  chunk_id       uuid,
  source_id      uuid,
  source_title   text,
  source_version int,
  origin_uri     text,
  chunk_metadata jsonb,
  content        text,
  score          real,
  rank_score     real
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp AS
$$
#variable_conflict use_column
DECLARE
  v_tenant     uuid := current_tenant_id();
  v_app        uuid;
  v_deployable boolean;
  v_auds       audience_t[];
  v_qid        uuid := gen_random_uuid();
  v_hits       int  := 0;
  v_top        real := 0;
  rec          record;
BEGIN
  -- 1) Kontext und Instanz (fail-closed)
  IF v_tenant IS NULL OR current_user_id() IS NULL THEN
    RAISE EXCEPTION 'missing session context' USING ERRCODE = '42501';
  END IF;
  IF NOT instance_usable(p_instance) THEN
    RAISE EXCEPTION 'instance not accessible' USING ERRCODE = '42501';
  END IF;

  -- 2) Nutzer braucht eine gültige Rolle in der Instanz
  IF NOT EXISTS (
    SELECT 1
    FROM role_assignment ra
    JOIN membership m ON m.id = ra.membership_id
    WHERE ra.instance_id = p_instance
      AND m.user_id   = current_user_id()
      AND m.tenant_id = v_tenant
      AND m.status    = 'active'
      AND (ra.valid_to IS NULL OR ra.valid_to > now())
  ) THEN
    RAISE EXCEPTION 'no role in instance' USING ERRCODE = '42501';
  END IF;

  -- 3) App-Wissen wird nur ausgeliefert, wenn die App veröffentlicht ist.
  --    Ausnahme: Der Publisher sieht es in seiner eigenen Instanz als Vorschau.
  SELECT i.app_id,
         (a.status = 'active' OR (i.grant_id IS NULL AND a.owner_tenant_id = v_tenant))
    INTO v_app, v_deployable
  FROM app_instance i
  JOIN app a ON a.id = i.app_id
  WHERE i.id = p_instance;

  -- 4) Audience: nur interne Sessions sehen internes Wissen, sonst fail-closed = extern
  v_auds := CASE WHEN current_audience() = 'internal'
                 THEN ARRAY['internal','external','public']::audience_t[]
                 ELSE ARRAY['external','public']::audience_t[] END;

  p_limit := least(greatest(p_limit, 1), 20);

  BEGIN
    PERFORM set_config('hnsw.iterative_scan', 'relaxed_order', true);
    PERFORM set_config('hnsw.ef_search', '100', true);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- 5) Suche
  FOR rec IN
    WITH allowed AS (
      SELECT s.id, s.title, s.version, s.origin_uri
      FROM knowledge_source s
      WHERE s.status = 'reviewed'
        AND (s.valid_until IS NULL OR s.valid_until >= current_date)
        AND s.audience = ANY (v_auds)
        AND (
              -- (a) App-natives Wissen: kommt mit der App, Eigentümer = Publisher
              (s.scope = 'app' AND s.app_id = v_app AND v_deployable)
              -- (b) Mandantenspezifisches Wissen genau dieser Instanz, Eigentümer = Instanz-Mandant
           OR (s.scope = 'tenant' AND s.instance_id = p_instance AND s.owner_tenant_id = v_tenant)
        )
    ),
    vec AS (
      SELECT c.id, row_number() OVER (ORDER BY c.embedding <=> p_query_embedding) AS rn
      FROM knowledge_chunk c
      WHERE c.is_current
        AND c.embedding_model = p_embedding_model
        AND c.source_id IN (SELECT id FROM allowed)
      ORDER BY c.embedding <=> p_query_embedding
      LIMIT 50
    ),
    fts AS (
      SELECT c.id,
             row_number() OVER (ORDER BY ts_rank_cd(c.tsv, q.tsq) DESC) AS rn
      FROM knowledge_chunk c,
           (SELECT websearch_to_tsquery('simple', p_query_text) AS tsq) q
      WHERE p_query_text IS NOT NULL
        AND c.is_current
        AND c.source_id IN (SELECT id FROM allowed)
        AND c.tsv @@ q.tsq
      ORDER BY ts_rank_cd(c.tsv, q.tsq) DESC
      LIMIT 50
    ),
    fused AS (
      SELECT coalesce(v.id, f.id) AS id,
             coalesce(1.0 / (60 + v.rn), 0) + coalesce(1.0 / (60 + f.rn), 0) AS rrf
      FROM vec v FULL JOIN fts f ON f.id = v.id
    )
    SELECT c.id AS chunk_id, a.id AS source_id, a.title, a.version, a.origin_uri,
           c.metadata, c.content,
           (1 - (c.embedding <=> p_query_embedding))::real AS score,
           fused.rrf::real AS rank_score
    FROM fused
    JOIN knowledge_chunk c ON c.id = fused.id
    JOIN allowed a         ON a.id = c.source_id
    WHERE c.embedding_model = p_embedding_model
      AND (1 - (c.embedding <=> p_query_embedding)) >= p_min_score
    ORDER BY fused.rrf DESC
    LIMIT p_limit
  LOOP
    v_hits := v_hits + 1;
    v_top  := greatest(v_top, rec.score);
    query_id       := v_qid;
    chunk_id       := rec.chunk_id;
    source_id      := rec.source_id;
    source_title   := rec.title;
    source_version := rec.version;
    origin_uri     := rec.origin_uri;
    chunk_metadata := rec.metadata;
    content        := rec.content;
    score          := rec.score;
    rank_score     := rec.rank_score;
    RETURN NEXT;
  END LOOP;

  -- 6) Protokoll (Lückenanalyse, Audit)
  INSERT INTO knowledge_query_log (id, tenant_id, instance_id, user_id, query_text, hit_count, top_score)
  VALUES (v_qid, v_tenant, p_instance, current_user_id(), p_query_text, v_hits, nullif(v_top, 0));

  INSERT INTO audit_event (actor_id, tenant_id, instance_id, action, detail)
  VALUES (current_user_id(), v_tenant, p_instance, 'knowledge.search',
          jsonb_build_object('query_id', v_qid, 'hits', v_hits, 'top_score', v_top));
END $$;

-- Wissen hängt jetzt direkt an App bzw. Instanz; die Link-Tabelle entfällt.
-- (Gleiches Wissen in mehreren Apps = pro App eine eigene Quelle.)
DROP TABLE knowledge_link;

-- ---------------------------------------------------------------------
-- 4) App veröffentlichen = Wissen der App wird mit veröffentlicht
--    Gate: Kein Wissen im Status 'draft' darf an der App hängen.
-- ---------------------------------------------------------------------
CREATE FUNCTION app_publish(p_app uuid) RETURNS void
  LANGUAGE plpgsql AS    -- SECURITY INVOKER: RLS des Aufrufers gilt
$$
BEGIN
  PERFORM 1 FROM app
   WHERE id = p_app
     AND owner_tenant_id = current_tenant_id()
     AND current_audience() = 'internal';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'app not found or not owned' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (SELECT 1 FROM knowledge_source
             WHERE scope = 'app' AND app_id = p_app AND status = 'draft') THEN
    RAISE EXCEPTION 'unreviewed app knowledge blocks publishing' USING ERRCODE = '55000';
  END IF;

  UPDATE app SET status = 'active' WHERE id = p_app;
END $$;

-- ---------------------------------------------------------------------
-- 5) Integrationen: Eigentümer von Postfach/Ticket-Schnittstelle bestimmt
--    über die Daten, die darüber entstehen
-- ---------------------------------------------------------------------
CREATE TYPE integration_kind_t AS ENUM ('mail', 'aircall', 'webform', 'api');

CREATE TABLE integration (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_tenant_id uuid NOT NULL REFERENCES tenant(id),
  instance_id     uuid NOT NULL REFERENCES app_instance(id) ON DELETE CASCADE,
  kind            integration_kind_t NOT NULL,
  name            text NOT NULL,
  status          status_t NOT NULL DEFAULT 'active',
  config          jsonb NOT NULL DEFAULT '{}'::jsonb,   -- nur Verweise auf Secrets, nie Klartext
  UNIQUE (id, instance_id)
);
CREATE INDEX integration_owner_idx ON integration (owner_tenant_id);

ALTER TABLE integration ENABLE ROW LEVEL SECURITY;
ALTER TABLE integration FORCE  ROW LEVEL SECURITY;

-- Hilfsfunktionen (SECURITY DEFINER, Owner s. u.)
-- Instanz gehört dem aktiven Tenant ODER der aktive Tenant ist Anbieter der Freigabe
CREATE FUNCTION instance_related(p_instance uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
$$
  SELECT EXISTS (
    SELECT 1
    FROM app_instance i
    LEFT JOIN app_grant g ON g.id = i.grant_id
    WHERE i.id = p_instance
      AND (i.tenant_id = current_tenant_id() OR g.provider_tenant_id = current_tenant_id())
  )
$$;

-- Instanz ist aktiv und (bei Freigabe) die Freigabe gültig. Unabhängig vom Aufrufer.
CREATE FUNCTION instance_active(p_instance uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
$$
  SELECT EXISTS (
    SELECT 1
    FROM app_instance i
    LEFT JOIN app_grant g ON g.id = i.grant_id
    WHERE i.id = p_instance
      AND i.status = 'active'
      AND (g.id IS NULL
           OR (g.status = 'active' AND (g.valid_to IS NULL OR g.valid_to > now())))
  )
$$;

-- Sichtbar/änderbar nur für den Eigentümer; anlegen nur in Instanzen, zu denen der
-- Tenant gehört (als Instanz-Eigentümer oder als Anbieter der Freigabe) und die aktiv sind.
CREATE POLICY integration_rw ON integration FOR ALL
  USING (owner_tenant_id = current_tenant_id())
  WITH CHECK (owner_tenant_id = current_tenant_id()
              AND instance_related(instance_id)
              AND instance_active(instance_id));

-- ---------------------------------------------------------------------
-- 6) Tickets und Kommentare folgen der Integration
-- ---------------------------------------------------------------------
ALTER TABLE ticket ADD COLUMN integration_id uuid NOT NULL;
ALTER TABLE ticket ADD CONSTRAINT ticket_integration_fk
  FOREIGN KEY (integration_id, instance_id) REFERENCES integration (id, instance_id);

-- tenant_id kommt IMMER aus der Integration. Läuft mit Rechten des Aufrufers:
-- fremde Integrationen sind nicht sichtbar => Fehler statt Einschleusen.
CREATE FUNCTION ticket_set_owner() RETURNS trigger
  LANGUAGE plpgsql AS
$$
BEGIN
  SELECT i.owner_tenant_id INTO NEW.tenant_id
  FROM integration i
  WHERE i.id = NEW.integration_id AND i.instance_id = NEW.instance_id;
  IF NEW.tenant_id IS NULL THEN
    RAISE EXCEPTION 'unknown or inaccessible integration' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER ticket_owner_trg
  BEFORE INSERT ON ticket
  FOR EACH ROW EXECUTE FUNCTION ticket_set_owner();

CREATE FUNCTION ticket_comment_set_owner() RETURNS trigger
  LANGUAGE plpgsql AS
$$
BEGIN
  SELECT t.tenant_id, t.instance_id INTO NEW.tenant_id, NEW.instance_id
  FROM ticket t WHERE t.id = NEW.ticket_id;
  IF NEW.tenant_id IS NULL THEN
    RAISE EXCEPTION 'unknown or inaccessible ticket' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER ticket_comment_owner_trg
  BEFORE INSERT ON ticket_comment
  FOR EACH ROW EXECUTE FUNCTION ticket_comment_set_owner();

-- Lesen: Der Eigentümer der Integration behält seine Daten immer (Export, Aufbewahrung),
--        auch nach Widerruf einer Freigabe.
-- Schreiben: nur solange die Instanz aktiv und die Freigabe gültig ist.
CREATE POLICY ticket_select ON ticket FOR SELECT
  USING (tenant_id = current_tenant_id());
CREATE POLICY ticket_insert ON ticket FOR INSERT
  WITH CHECK (tenant_id = current_tenant_id() AND instance_active(instance_id));
CREATE POLICY ticket_update ON ticket FOR UPDATE
  USING      (tenant_id = current_tenant_id() AND instance_active(instance_id))
  WITH CHECK (tenant_id = current_tenant_id() AND instance_active(instance_id));
CREATE POLICY ticket_delete ON ticket FOR DELETE
  USING (tenant_id = current_tenant_id() AND instance_active(instance_id));

-- Kommentare: Externe sehen und schreiben nur öffentliche Kommentare
CREATE POLICY comment_select ON ticket_comment FOR SELECT USING (
  tenant_id = current_tenant_id()
  AND (visibility = 'public' OR current_audience() = 'internal'));
CREATE POLICY comment_insert ON ticket_comment FOR INSERT WITH CHECK (
  tenant_id = current_tenant_id()
  AND instance_active(instance_id)
  AND (visibility = 'public' OR current_audience() = 'internal'));
CREATE POLICY comment_update ON ticket_comment FOR UPDATE
  USING (tenant_id = current_tenant_id() AND instance_active(instance_id)
         AND (visibility = 'public' OR current_audience() = 'internal'))
  WITH CHECK (tenant_id = current_tenant_id() AND instance_active(instance_id)
         AND (visibility = 'public' OR current_audience() = 'internal'));
CREATE POLICY comment_delete ON ticket_comment FOR DELETE USING (
  tenant_id = current_tenant_id() AND instance_active(instance_id)
  AND (visibility = 'public' OR current_audience() = 'internal'));

-- ---------------------------------------------------------------------
-- 7) Rechte und Funktions-Eigentümer
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON integration TO app_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_definer;

ALTER FUNCTION instance_related(uuid) OWNER TO app_definer;
ALTER FUNCTION instance_active(uuid)  OWNER TO app_definer;

GRANT EXECUTE ON FUNCTION app_publish(uuid) TO app_runtime;

COMMIT;
