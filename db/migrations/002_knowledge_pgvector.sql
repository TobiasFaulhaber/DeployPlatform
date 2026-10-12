-- =====================================================================
-- Knowledge-Hub-Modul (pgvector) – Erweiterung von platform_core_schema.sql
-- Voraussetzung: Kernschema ist eingespielt | PostgreSQL 15+ | pgvector 0.7+
-- (pgvector 0.8+ empfohlen: iterative Index-Scans bei gefilterter Suche)
--
-- Prinzipien:
--   * Die KI/Suche greift NUR über knowledge_link auf Wissen zu.
--   * Nur Quellen mit status='reviewed' und gültigem valid_until werden geliefert.
--   * Audience-Filter (intern/extern) wird in der Suchfunktion erzwungen (fail-closed).
--   * Anbieter-Wissen in einer Freigabe muss extern/öffentlich freigegeben sein.
--   * Chunks sind für Anwendungen NICHT direkt lesbar, nur über knowledge_search().
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS vector;

-- ---------- Erweiterung der Wissensquelle (Sprung ins Originaldokument) --
ALTER TABLE knowledge_source
  ADD COLUMN IF NOT EXISTS origin_type text,   -- 'upload','url','confluence','sharepoint','zendesk'
  ADD COLUMN IF NOT EXISTS origin_uri  text;   -- Link/Ablageort des Originals

-- ---------- Chunks mit Embeddings ------------------------------------
-- Dimension 1536 als Beispiel. Anderes Embedding-Modell = andere Dimension:
-- vector(N) hier ändern (ab ~2000 Dimensionen: halfvec verwenden).
CREATE TABLE knowledge_chunk (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id       uuid NOT NULL REFERENCES knowledge_source(id) ON DELETE CASCADE,
  tenant_id       uuid NOT NULL REFERENCES tenant(id),       -- = Eigentümer der Quelle (per Trigger)
  source_version  int  NOT NULL,
  chunk_index     int  NOT NULL,
  content         text NOT NULL,
  token_count     int,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,        -- Seite, Überschrift, Anker für "Sprung zum Original"
  embedding       vector(1536) NOT NULL,
  embedding_model text NOT NULL,                              -- Modelle nie mischen
  is_current      boolean NOT NULL DEFAULT false,             -- erst nach Aktivierung sichtbar
  tsv             tsvector GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED,
  UNIQUE (source_id, source_version, chunk_index)
);
-- 'simple' ist sprachneutral (DE/EN gemischt). Bei einsprachigen Korpora
-- 'german' bzw. 'english' verwenden.

CREATE INDEX knowledge_chunk_hnsw ON knowledge_chunk
  USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64)
  WHERE is_current;
CREATE INDEX knowledge_chunk_tsv_idx ON knowledge_chunk USING gin (tsv) WHERE is_current;
CREATE INDEX knowledge_chunk_source_idx ON knowledge_chunk (source_id, source_version);

-- tenant_id wird immer aus der Quelle abgeleitet, nie vom Client übernommen
CREATE FUNCTION knowledge_chunk_set_tenant() RETURNS trigger
  LANGUAGE plpgsql AS
$$
BEGIN
  SELECT owner_tenant_id INTO NEW.tenant_id
  FROM knowledge_source WHERE id = NEW.source_id;
  IF NEW.tenant_id IS NULL THEN
    RAISE EXCEPTION 'unknown or inaccessible knowledge source' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER knowledge_chunk_tenant_trg
  BEFORE INSERT ON knowledge_chunk
  FOR EACH ROW EXECUTE FUNCTION knowledge_chunk_set_tenant();

-- ---------- Ingestion-Jobs (Parsen -> Chunking -> Embedding) ---------
CREATE TABLE knowledge_ingest_job (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id      uuid NOT NULL REFERENCES knowledge_source(id) ON DELETE CASCADE,
  tenant_id      uuid NOT NULL REFERENCES tenant(id),
  source_version int  NOT NULL,
  status         text NOT NULL DEFAULT 'queued'
                 CHECK (status IN ('queued','running','done','failed')),
  attempts       int  NOT NULL DEFAULT 0,
  error          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  finished_at    timestamptz
);
CREATE INDEX ingest_queue_idx ON knowledge_ingest_job (status, created_at);

-- ---------- Abfrage-Log (Grundlage für Lückenanalyse) ----------------
CREATE TABLE knowledge_query_log (
  id          uuid PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id),
  instance_id uuid NOT NULL REFERENCES app_instance(id),
  user_id     uuid REFERENCES app_user(id),
  query_text  text,                 -- personenbezogene Daten möglich: Aufbewahrungsfrist festlegen
  hit_count   int  NOT NULL,
  top_score   real
);
CREATE INDEX query_log_tenant_at_idx ON knowledge_query_log (tenant_id, at DESC);

-- ---------- Feedback ("Antwort hilfreich?") --------------------------
CREATE TABLE knowledge_feedback (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  at        timestamptz NOT NULL DEFAULT now(),
  query_id  uuid NOT NULL REFERENCES knowledge_query_log(id) ON DELETE CASCADE,
  chunk_id  uuid REFERENCES knowledge_chunk(id) ON DELETE SET NULL,
  tenant_id uuid NOT NULL REFERENCES tenant(id),
  user_id   uuid NOT NULL REFERENCES app_user(id),
  helpful   boolean NOT NULL,
  note      text
);

-- ---------- RLS -------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['knowledge_chunk','knowledge_ingest_job',
                           'knowledge_query_log','knowledge_feedback'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY',  t);
  END LOOP;
END $$;

-- Verwaltung nur durch den Eigentümer-Tenant im internen Kontext.
-- Externe Nutzer können Chunks NIE direkt lesen.
CREATE POLICY chunk_rw ON knowledge_chunk FOR ALL
  USING      (tenant_id = current_tenant_id() AND current_audience() = 'internal')
  WITH CHECK (tenant_id = current_tenant_id() AND current_audience() = 'internal');

CREATE POLICY ingest_rw ON knowledge_ingest_job FOR ALL
  USING      (tenant_id = current_tenant_id() AND current_audience() = 'internal')
  WITH CHECK (tenant_id = current_tenant_id() AND current_audience() = 'internal');

-- Log und Feedback: nur intern lesbar; Schreiben ausschließlich über Funktionen
CREATE POLICY query_log_read ON knowledge_query_log FOR SELECT
  USING (tenant_id = current_tenant_id() AND current_audience() = 'internal');
CREATE POLICY feedback_read ON knowledge_feedback FOR SELECT
  USING (tenant_id = current_tenant_id() AND current_audience() = 'internal');

-- ---------- Version aktivieren (atomar, mit RLS des Aufrufers) -------
-- Worker schreibt neue Chunks mit is_current=false, danach Aktivierung:
-- alte Version verschwindet und neue wird sichtbar in EINER Transaktion.
CREATE FUNCTION knowledge_activate_version(p_source uuid, p_version int)
RETURNS int
LANGUAGE plpgsql AS
$$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n
  FROM knowledge_chunk WHERE source_id = p_source AND source_version = p_version;
  IF n = 0 THEN
    RAISE EXCEPTION 'no chunks for source % version %', p_source, p_version;
  END IF;

  UPDATE knowledge_chunk
     SET is_current = (source_version = p_version)
   WHERE source_id = p_source AND (is_current OR source_version = p_version);

  DELETE FROM knowledge_chunk
   WHERE source_id = p_source AND source_version <> p_version;

  UPDATE knowledge_source SET version = p_version WHERE id = p_source;
  RETURN n;
END $$;

-- ---------- Hybrid-Suche (Vektor + Volltext, Reciprocal Rank Fusion) --
-- SECURITY DEFINER, weil Anbieter-Wissen für Empfänger per RLS nicht lesbar ist.
-- Deshalb sind ALLE Zugriffsregeln hier im Code erzwungen (Owner: app_definer, s. u.).
CREATE FUNCTION knowledge_search(
  p_instance        uuid,
  p_query_embedding vector(1536),
  p_embedding_model text,
  p_query_text      text DEFAULT NULL,   -- optional: aktiviert Volltext-Anteil + Lückenanalyse
  p_limit           int  DEFAULT 8,
  p_min_score       real DEFAULT 0.55    -- Qualitätsschwelle (Kosinus-Ähnlichkeit)
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
  v_tenant   uuid := current_tenant_id();
  v_app      uuid;
  v_grant    uuid;
  v_provider uuid;
  v_auds     audience_t[];
  v_qid      uuid := gen_random_uuid();
  v_hits     int  := 0;
  v_top      real := 0;
  rec        record;
BEGIN
  -- 1) Kontext und Instanz prüfen (fail-closed)
  IF v_tenant IS NULL OR current_user_id() IS NULL THEN
    RAISE EXCEPTION 'missing session context' USING ERRCODE = '42501';
  END IF;
  IF NOT instance_usable(p_instance) THEN
    RAISE EXCEPTION 'instance not accessible' USING ERRCODE = '42501';
  END IF;

  -- 2) Nutzer braucht mindestens eine gültige Rolle in der Instanz.
  --    (Feingranulare Rechte wie "darf Wissen abfragen" aus app_role.permissions
  --     werden in der Service-Schicht geprüft.)
  IF NOT EXISTS (
    SELECT 1
    FROM role_assignment ra
    JOIN membership m ON m.id = ra.membership_id
    WHERE ra.instance_id = p_instance
      AND m.user_id = current_user_id()
      AND m.tenant_id = v_tenant
      AND m.status = 'active'
      AND (ra.valid_to IS NULL OR ra.valid_to > now())
  ) THEN
    RAISE EXCEPTION 'no role in instance' USING ERRCODE = '42501';
  END IF;

  SELECT i.app_id, i.grant_id, g.provider_tenant_id
    INTO v_app, v_grant, v_provider
  FROM app_instance i
  LEFT JOIN app_grant g ON g.id = i.grant_id
  WHERE i.id = p_instance;

  -- 3) Audience: nur interne Sessions sehen internes Wissen; alles andere = extern
  v_auds := CASE WHEN current_audience() = 'internal'
                 THEN ARRAY['internal','external','public']::audience_t[]
                 ELSE ARRAY['external','public']::audience_t[] END;

  p_limit := least(greatest(p_limit, 1), 20);

  -- 4) pgvector-Tuning (ignorieren, falls Version die Parameter nicht kennt)
  BEGIN
    PERFORM set_config('hnsw.iterative_scan', 'relaxed_order', true);
    PERFORM set_config('hnsw.ef_search', '100', true);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- 5) Suche
  FOR rec IN
    WITH allowed AS (
      SELECT s.id, s.title, s.version, s.origin_uri
      FROM knowledge_link l
      JOIN knowledge_source s ON s.id = l.source_id
      WHERE l.app_id = v_app
        AND l.grant_id IS NOT DISTINCT FROM v_grant      -- eigene App: NULL, Freigabe: grant_id
        AND s.status = 'reviewed'
        AND (s.valid_until IS NULL OR s.valid_until >= current_date)
        AND (
              -- eigenes Wissen des aktiven Tenants, gefiltert nach Audience
              (s.owner_tenant_id = v_tenant AND s.audience = ANY (v_auds))
              -- Anbieter-Wissen nur, wenn extern/öffentlich freigegeben UND per Link der Freigabe zugeordnet
           OR (v_grant IS NOT NULL AND s.owner_tenant_id = v_provider
               AND s.audience IN ('external','public'))
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
      AND (1 - (c.embedding <=> p_query_embedding)) >= p_min_score   -- Qualitätsschwelle
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

  -- 6) Protokoll: Lückenanalyse (0 Treffer) und Audit. Keine Treffer = Übergabe an Mensch.
  INSERT INTO knowledge_query_log (id, tenant_id, instance_id, user_id, query_text, hit_count, top_score)
  VALUES (v_qid, v_tenant, p_instance, current_user_id(), p_query_text, v_hits, nullif(v_top, 0));

  INSERT INTO audit_event (actor_id, tenant_id, instance_id, action, detail)
  VALUES (current_user_id(), v_tenant, p_instance, 'knowledge.search',
          jsonb_build_object('query_id', v_qid, 'hits', v_hits, 'top_score', v_top));
END $$;

-- ---------- Feedback abgeben (auch für externe Nutzer) ----------------
CREATE FUNCTION knowledge_submit_feedback(
  p_query uuid, p_chunk uuid, p_helpful boolean, p_note text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp AS
$$
DECLARE v_id uuid;
BEGIN
  -- Nur zu eigenen Abfragen im eigenen Tenant
  PERFORM 1 FROM knowledge_query_log q
   WHERE q.id = p_query
     AND q.tenant_id = current_tenant_id()
     AND q.user_id   = current_user_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown query' USING ERRCODE = '42501';
  END IF;

  INSERT INTO knowledge_feedback (query_id, chunk_id, tenant_id, user_id, helpful, note)
  VALUES (p_query, p_chunk, current_tenant_id(), current_user_id(), p_helpful, left(p_note, 2000))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------- Auswertungen (Rechte des Aufrufers => RLS greift) ---------
-- Lückenanalyse: Was wurde gefragt, aber nicht (gut) beantwortet?
CREATE VIEW knowledge_gap_report WITH (security_invoker = true) AS
SELECT tenant_id,
       instance_id,
       lower(trim(query_text))   AS question,
       count(*)                  AS asked,
       max(at)                   AS last_asked,
       avg(top_score)            AS avg_top_score
FROM knowledge_query_log
WHERE query_text IS NOT NULL
  AND (hit_count = 0 OR top_score < 0.65)
GROUP BY tenant_id, instance_id, lower(trim(query_text));

-- Qualität je Quelle aus Nutzerfeedback
CREATE VIEW knowledge_source_quality WITH (security_invoker = true) AS
SELECT s.id AS source_id,
       s.title,
       count(*) FILTER (WHERE f.helpful)     AS helpful,
       count(*) FILTER (WHERE NOT f.helpful) AS not_helpful
FROM knowledge_feedback f
JOIN knowledge_chunk  c ON c.id = f.chunk_id
JOIN knowledge_source s ON s.id = c.source_id
GROUP BY s.id, s.title;

-- ---------- Rollen & Rechte -------------------------------------------
-- app_definer: Besitzer der SECURITY-DEFINER-Funktionen. Braucht BYPASSRLS,
-- da die Funktionen Anbieter-Wissen lesen, das der Empfänger per RLS nicht sieht.
-- (CREATE ROLE ... BYPASSRLS erfordert Superuser; Zugriffsregeln stecken im Funktionscode!)
CREATE ROLE app_definer NOLOGIN BYPASSRLS;
GRANT USAGE ON SCHEMA public TO app_definer;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_definer;
GRANT INSERT ON knowledge_query_log, knowledge_feedback, audit_event TO app_definer;
GRANT USAGE ON SEQUENCE audit_event_id_seq TO app_definer;

ALTER FUNCTION knowledge_search(uuid, vector, text, text, int, real) OWNER TO app_definer;
ALTER FUNCTION knowledge_submit_feedback(uuid, uuid, boolean, text)  OWNER TO app_definer;
-- Optional: Hilfsfunktionen des Kernschemas ebenfalls härten
ALTER FUNCTION instance_usable(uuid)           OWNER TO app_definer;
ALTER FUNCTION provider_has_full_access(uuid)  OWNER TO app_definer;

REVOKE ALL ON FUNCTION knowledge_search(uuid, vector, text, text, int, real) FROM PUBLIC;
REVOKE ALL ON FUNCTION knowledge_submit_feedback(uuid, uuid, boolean, text)  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION knowledge_search(uuid, vector, text, text, int, real) TO app_runtime;
GRANT EXECUTE ON FUNCTION knowledge_submit_feedback(uuid, uuid, boolean, text)  TO app_runtime;
GRANT EXECUTE ON FUNCTION knowledge_activate_version(uuid, int)                 TO app_runtime;

GRANT SELECT, INSERT, UPDATE, DELETE ON knowledge_chunk, knowledge_ingest_job TO app_runtime;
GRANT SELECT ON knowledge_query_log, knowledge_feedback,
                knowledge_gap_report, knowledge_source_quality TO app_runtime;

-- =====================================================================
-- Ablauf im Betrieb
--
-- Ingestion (Worker, interner Kontext des Eigentümer-Tenants):
--   1. knowledge_source: neue version anlegen/hochzählen, Job in knowledge_ingest_job einstellen
--   2. Parsen -> Chunking (z. B. 300-500 Tokens, 10-15 % Überlappung) -> Embeddings
--   3. INSERT INTO knowledge_chunk (... is_current = false ...)
--   4. SELECT knowledge_activate_version(<source>, <version>);
--
-- Abfrage (Laufzeit, Kontext aus verifiziertem Token):
--   BEGIN;
--   SET LOCAL ROLE app_runtime;
--   SELECT set_config('app.user_id',   '<user>',   true);
--   SELECT set_config('app.tenant_id', '<tenant>', true);
--   SELECT set_config('app.audience',  'external', true);
--   SELECT * FROM knowledge_search('<instance>', '<embedding>'::vector,
--                                  'embedding-model-v1', 'Wie storniere ich?', 6, 0.55);
--   COMMIT;
--   0 Zeilen  => keine ausreichende Trefferqualität => Übergabe an einen Menschen.
--
-- Pflege:
--   * Quellen mit status='outdated' oder abgelaufenem valid_until verschwinden automatisch.
--   * Aufbewahrungsfrist für knowledge_query_log festlegen (DSGVO), z. B. per Cron-Job.
-- =====================================================================
