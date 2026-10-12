-- =====================================================================
-- Migration v3 – Kundenkonten: Externe Nutzer sehen nur "ihre" Datensätze
--
-- Voraussetzung: platform_core_schema.sql, platform_knowledge_pgvector.sql und
-- platform_v2_migration.sql sind eingespielt; Tabelle ticket ist noch leer
-- oder alle Tickets dürfen zunächst ohne Konto (account_id NULL) bleiben.
--
-- Modell:
--   * customer_account = Endkunde/Firma INNERHALB eines Mandanten
--     (z. B. "Alpha GmbH" als Kunde von Mandant A; external_ref = CRM-ID).
--   * Externe Nutzer werden über membership_account einem oder mehreren
--     Kundenkonten zugeordnet. Die Zuordnung kommt immer aus der Datenbank,
--     nie aus dem Token (kein veralteter Claim, keine Manipulation).
--   * Ticket.account_id wird beim Eingang gesetzt (CRM-Lookup, Absender-Domain,
--     Portal-Nutzer) oder später von einem internen Nutzer zugewiesen.
--   * Externe sehen Tickets (und deren öffentliche Kommentare) NUR ihrer Konten.
--     Tickets ohne Konto sind für Externe unsichtbar.
--   * Externe legen Tickets nur über portal_create_ticket() an, nie per INSERT.
--   * Mandantengrenze wird per zusammengesetztem Fremdschlüssel erzwungen:
--     ein Ticket kann nie einem Konto eines anderen Mandanten zugeordnet werden.
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- 1) Kundenkonten und Zuordnung der Mitgliedschaften
-- ---------------------------------------------------------------------
CREATE TABLE customer_account (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  name         text NOT NULL,
  external_ref text,                                   -- z. B. Salesforce-Account-ID
  status       status_t NOT NULL DEFAULT 'active',
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, tenant_id)                               -- Ziel für zusammengesetzte FKs
);
CREATE UNIQUE INDEX customer_account_ref_uk
  ON customer_account (tenant_id, external_ref) WHERE external_ref IS NOT NULL;

ALTER TABLE membership ADD CONSTRAINT membership_id_tenant_uk UNIQUE (id, tenant_id);

-- Eine Mitgliedschaft kann mehreren Konten angehören (z. B. Berater, Konzernstrukturen).
-- Beide Fremdschlüssel enthalten tenant_id: Mitgliedschaft und Konto müssen im selben Mandanten liegen.
CREATE TABLE membership_account (
  membership_id uuid NOT NULL,
  account_id    uuid NOT NULL,
  tenant_id     uuid NOT NULL,
  PRIMARY KEY (membership_id, account_id),
  FOREIGN KEY (membership_id, tenant_id) REFERENCES membership (id, tenant_id) ON DELETE CASCADE,
  FOREIGN KEY (account_id,    tenant_id) REFERENCES customer_account (id, tenant_id) ON DELETE CASCADE
);
CREATE INDEX membership_account_account_idx ON membership_account (account_id);

ALTER TABLE customer_account   ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_account   FORCE  ROW LEVEL SECURITY;
ALTER TABLE membership_account ENABLE ROW LEVEL SECURITY;
ALTER TABLE membership_account FORCE  ROW LEVEL SECURITY;

-- Konten des aktuellen Nutzers im aktiven Mandanten (aus der Datenbank, nicht aus dem Token)
CREATE FUNCTION current_account_ids() RETURNS uuid[]
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
$$
  SELECT coalesce(array_agg(ma.account_id), ARRAY[]::uuid[])
  FROM membership_account ma
  JOIN membership m        ON m.id  = ma.membership_id
  JOIN customer_account ca ON ca.id = ma.account_id
  WHERE m.user_id   = current_user_id()
    AND m.tenant_id = current_tenant_id()
    AND m.status    = 'active'
    AND ca.status   = 'active'
$$;

-- Externe sehen nur die eigenen Konten, Verwaltung nur intern
CREATE POLICY customer_account_read ON customer_account FOR SELECT USING (
  tenant_id = current_tenant_id()
  AND (current_audience() = 'internal'
       OR id IN (SELECT unnest(current_account_ids())))
);
CREATE POLICY customer_account_write ON customer_account FOR ALL
  USING      (tenant_id = current_tenant_id() AND current_audience() = 'internal')
  WITH CHECK (tenant_id = current_tenant_id() AND current_audience() = 'internal');

CREATE POLICY membership_account_read ON membership_account FOR SELECT USING (
  tenant_id = current_tenant_id()
  AND (current_audience() = 'internal'
       OR membership_id IN (SELECT id FROM membership WHERE user_id = current_user_id()))
);
CREATE POLICY membership_account_write ON membership_account FOR ALL
  USING      (tenant_id = current_tenant_id() AND current_audience() = 'internal')
  WITH CHECK (tenant_id = current_tenant_id() AND current_audience() = 'internal');

-- ---------------------------------------------------------------------
-- 2) Integrationen: Konfiguration (Secret-Verweise) nur für interne Nutzer
-- ---------------------------------------------------------------------
DROP POLICY integration_rw ON integration;
CREATE POLICY integration_rw ON integration FOR ALL
  USING (owner_tenant_id = current_tenant_id() AND current_audience() = 'internal')
  WITH CHECK (owner_tenant_id = current_tenant_id()
              AND current_audience() = 'internal'
              AND instance_related(instance_id)
              AND instance_active(instance_id));

-- ---------------------------------------------------------------------
-- 3) Tickets: Konto-Zuordnung und Account-Scoping
-- ---------------------------------------------------------------------
ALTER TABLE ticket ADD COLUMN account_id uuid;      -- NULL = (noch) keinem Kundenkonto zugeordnet
ALTER TABLE ticket ADD CONSTRAINT ticket_account_fk
  FOREIGN KEY (account_id, tenant_id) REFERENCES customer_account (id, tenant_id);
CREATE INDEX ticket_account_idx ON ticket (tenant_id, account_id);

DROP POLICY ticket_select ON ticket;
DROP POLICY ticket_insert ON ticket;
DROP POLICY ticket_update ON ticket;
DROP POLICY ticket_delete ON ticket;

-- Lesen: intern alle Tickets des Eigentümers, extern nur Tickets der eigenen Konten.
CREATE POLICY ticket_select ON ticket FOR SELECT USING (
  tenant_id = current_tenant_id()
  AND (current_audience() = 'internal'
       OR account_id IN (SELECT unnest(current_account_ids())))
);
-- Schreiben: nur intern und nur solange die Instanz aktiv ist.
-- Externe erzeugen Tickets ausschließlich über portal_create_ticket().
CREATE POLICY ticket_insert ON ticket FOR INSERT WITH CHECK (
  tenant_id = current_tenant_id() AND current_audience() = 'internal' AND instance_active(instance_id));
CREATE POLICY ticket_update ON ticket FOR UPDATE
  USING      (tenant_id = current_tenant_id() AND current_audience() = 'internal' AND instance_active(instance_id))
  WITH CHECK (tenant_id = current_tenant_id() AND current_audience() = 'internal' AND instance_active(instance_id));
CREATE POLICY ticket_delete ON ticket FOR DELETE USING (
  tenant_id = current_tenant_id() AND current_audience() = 'internal' AND instance_active(instance_id));

-- Kommentare erben die Sichtbarkeit des Tickets: Das EXISTS läuft mit den Rechten des
-- Aufrufers, d. h. nur Kommentare an Tickets, die er selbst sehen darf.
DROP POLICY comment_select ON ticket_comment;
DROP POLICY comment_insert ON ticket_comment;
DROP POLICY comment_update ON ticket_comment;
DROP POLICY comment_delete ON ticket_comment;

CREATE POLICY comment_select ON ticket_comment FOR SELECT USING (
  tenant_id = current_tenant_id()
  AND (visibility = 'public' OR current_audience() = 'internal')
  AND EXISTS (SELECT 1 FROM ticket t WHERE t.id = ticket_comment.ticket_id));
CREATE POLICY comment_insert ON ticket_comment FOR INSERT WITH CHECK (
  tenant_id = current_tenant_id()
  AND instance_active(instance_id)
  AND (visibility = 'public' OR current_audience() = 'internal')
  AND EXISTS (SELECT 1 FROM ticket t WHERE t.id = ticket_comment.ticket_id));
CREATE POLICY comment_update ON ticket_comment FOR UPDATE
  USING (tenant_id = current_tenant_id() AND instance_active(instance_id)
         AND (visibility = 'public' OR current_audience() = 'internal')
         AND EXISTS (SELECT 1 FROM ticket t WHERE t.id = ticket_comment.ticket_id))
  WITH CHECK (tenant_id = current_tenant_id() AND instance_active(instance_id)
         AND (visibility = 'public' OR current_audience() = 'internal')
         AND EXISTS (SELECT 1 FROM ticket t WHERE t.id = ticket_comment.ticket_id));
CREATE POLICY comment_delete ON ticket_comment FOR DELETE USING (
  tenant_id = current_tenant_id() AND instance_active(instance_id)
  AND (visibility = 'public' OR current_audience() = 'internal')
  AND EXISTS (SELECT 1 FROM ticket t WHERE t.id = ticket_comment.ticket_id));

-- ---------------------------------------------------------------------
-- 4) Ticket aus dem Kundenportal anlegen (einziger Weg für externe Nutzer)
--    Konto wird aus den Konten des Nutzers bestimmt, nie ungeprüft übernommen.
-- ---------------------------------------------------------------------
CREATE FUNCTION portal_create_ticket(
  p_integration uuid,              -- Webform-Integration des Mandanten
  p_subject     text,
  p_body        text DEFAULT NULL,
  p_account     uuid DEFAULT NULL  -- nur nötig, wenn der Nutzer mehrere Konten hat
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp AS
$$
DECLARE
  v_tenant   uuid := current_tenant_id();
  v_user     uuid := current_user_id();
  v_inst     uuid;
  v_kind     integration_kind_t;
  v_accounts uuid[];
  v_account  uuid;
  v_id       uuid;
BEGIN
  IF v_tenant IS NULL OR v_user IS NULL THEN
    RAISE EXCEPTION 'missing session context' USING ERRCODE = '42501';
  END IF;
  IF coalesce(btrim(p_subject), '') = '' THEN
    RAISE EXCEPTION 'subject required' USING ERRCODE = '22023';
  END IF;

  -- Integration muss dem aktiven Mandanten gehören, aktiv und vom Typ Webform sein
  SELECT i.instance_id, i.kind INTO v_inst, v_kind
  FROM integration i
  WHERE i.id = p_integration AND i.owner_tenant_id = v_tenant AND i.status = 'active';
  IF v_inst IS NULL OR v_kind <> 'webform' THEN
    RAISE EXCEPTION 'integration not available' USING ERRCODE = '42501';
  END IF;
  IF NOT instance_active(v_inst) THEN
    RAISE EXCEPTION 'instance not active' USING ERRCODE = '42501';
  END IF;

  -- Nutzer braucht eine gültige Rolle in der Instanz
  IF NOT EXISTS (
    SELECT 1
    FROM role_assignment ra
    JOIN membership m ON m.id = ra.membership_id
    WHERE ra.instance_id = v_inst
      AND m.user_id = v_user AND m.tenant_id = v_tenant AND m.status = 'active'
      AND (ra.valid_to IS NULL OR ra.valid_to > now())
  ) THEN
    RAISE EXCEPTION 'no role in instance' USING ERRCODE = '42501';
  END IF;

  -- Konto bestimmen
  IF current_audience() = 'internal' THEN
    v_account := p_account;                       -- intern: beliebiges Konto des Mandanten (FK prüft) oder NULL
  ELSE
    v_accounts := current_account_ids();
    IF cardinality(v_accounts) = 0 THEN
      RAISE EXCEPTION 'no customer account' USING ERRCODE = '42501';
    ELSIF p_account IS NOT NULL THEN
      IF NOT (p_account = ANY (v_accounts)) THEN
        RAISE EXCEPTION 'account not permitted' USING ERRCODE = '42501';
      END IF;
      v_account := p_account;
    ELSIF cardinality(v_accounts) = 1 THEN
      v_account := v_accounts[1];
    ELSE
      RAISE EXCEPTION 'customer account required' USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO ticket (instance_id, integration_id, account_id, source, subject, body)
  VALUES (v_inst, p_integration, v_account, 'webform', left(p_subject, 300), left(p_body, 20000))
  RETURNING id INTO v_id;

  INSERT INTO audit_event (actor_id, tenant_id, instance_id, action, detail)
  VALUES (v_user, v_tenant, v_inst, 'ticket.portal_create',
          jsonb_build_object('ticket_id', v_id, 'account_id', v_account));

  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- 5) Rechte und Funktions-Eigentümer
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON customer_account, membership_account TO app_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_definer;
GRANT INSERT ON ticket TO app_definer;

ALTER FUNCTION current_account_ids() OWNER TO app_definer;
ALTER FUNCTION portal_create_ticket(uuid, text, text, uuid) OWNER TO app_definer;

REVOKE ALL ON FUNCTION portal_create_ticket(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION portal_create_ticket(uuid, text, text, uuid) TO app_runtime;

COMMIT;
