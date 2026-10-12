-- =====================================================================
-- Migration v4 – Ticket-Eingang: Kundenkonto automatisch zuordnen
--
-- Voraussetzung: v3 (Kundenkonten) ist eingespielt.
--
-- Ablauf pro Eingang (E-Mail, Aircall, Webform):
--   1. Der Eingangs-Worker authentifiziert sich als Service-Nutzer des Mandanten,
--      der die Integration besitzt (Audience 'internal'), und ruft ticket_intake().
--   2. Die Datenbank sammelt Treffer (Kandidaten) je Methode und bewertet sie:
--        contact_email  exakte Absender-Adresse bei einem Konto   0.95
--        contact_phone  exakte Rufnummer (E.164) bei einem Konto  0.95
--        crm            CRM-Konto-ID aus dem Worker-Lookup        0.92
--        domain         Firmen-Domain (Freemailer ausgeschlossen) 0.60
--      Ist die Absenderidentität NICHT verifiziert (p_sender_verified = false),
--      werden alle Methoden außer 'domain' auf 0.50 gedeckelt.
--   3. Auto-Zuordnung nur, wenn genau EIN Konto die Schwelle erreicht (Standard 0.90,
--      per Policy 'account_matching' einstellbar, nie unter 0.80) und kein anderes Konto
--      einen Treffer >= 0.50 hat. Sonst bleibt das Ticket OHNE Konto und die Kandidaten
--      landen als Vorschläge in der Review-Queue (ticket_account_suggestion).
--   4. Ein interner Nutzer bestätigt per ticket_confirm_account() (optional lernt das
--      System die Absenderdaten als Kontakt).
--
-- Warum so streng? Sobald ein Ticket einem Konto zugeordnet ist, sehen es die externen
-- Nutzer dieses Kontos im Portal. Ein gefälschter Absender darf dort nichts einschleusen.
--
-- Vertrauensgrenze: p_sender_verified setzt ausschließlich der Eingangs-Worker
-- (SPF/DKIM/DMARC bestanden bzw. Telefonanbieter bestätigt die Rufnummer).
-- Öffentliche Webforms sind NIE verifiziert. Eingeloggte Portalnutzer laufen über
-- portal_create_ticket() (v3), nicht über diese Funktion.
-- Die CRM-Abfrage (z. B. Salesforce) macht der Worker; die Datenbank bekommt nur das Ergebnis.
-- =====================================================================
BEGIN;

-- ---------------------------------------------------------------------
-- 1) Kontakte und Domains je Kundenkonto
-- ---------------------------------------------------------------------
CREATE TYPE contact_kind_t AS ENUM ('email', 'phone');

CREATE TABLE account_contact (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL,
  account_id uuid NOT NULL,
  kind       contact_kind_t NOT NULL,
  value      text NOT NULL,                   -- E-Mail: klein geschrieben | Telefon: E.164 (+4921...)
  source     text NOT NULL DEFAULT 'manual' CHECK (source IN ('crm','manual','learned')),
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (account_id, tenant_id) REFERENCES customer_account (id, tenant_id) ON DELETE CASCADE,
  CHECK (   (kind = 'email' AND value = lower(btrim(value)) AND value ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
         OR (kind = 'phone' AND value ~ '^\+[1-9][0-9]{6,14}$')),
  UNIQUE (tenant_id, kind, value, account_id)  -- gleicher Kontakt bei mehreren Konten ist erlaubt (= mehrdeutig)
);
CREATE INDEX account_contact_lookup_idx ON account_contact (tenant_id, kind, value);

CREATE TABLE account_domain (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL,
  account_id uuid NOT NULL,
  domain     text NOT NULL CHECK (domain = lower(domain) AND domain ~ '^[a-z0-9.-]+\.[a-z]{2,}$'),
  source     text NOT NULL DEFAULT 'manual' CHECK (source IN ('crm','manual')),
  FOREIGN KEY (account_id, tenant_id) REFERENCES customer_account (id, tenant_id) ON DELETE CASCADE,
  UNIQUE (tenant_id, domain, account_id)
);
CREATE INDEX account_domain_lookup_idx ON account_domain (tenant_id, domain);

-- Plattformweite Liste privater Mail-Anbieter: Domain-Treffer dort sind wertlos
CREATE TABLE freemail_domain (domain text PRIMARY KEY CHECK (domain = lower(domain)));
INSERT INTO freemail_domain (domain) VALUES
  ('gmail.com'), ('googlemail.com'), ('outlook.com'), ('hotmail.com'), ('live.com'),
  ('yahoo.com'), ('gmx.de'), ('gmx.net'), ('web.de'), ('t-online.de'),
  ('icloud.com'), ('proton.me'), ('protonmail.com'), ('aol.com');

-- ---------------------------------------------------------------------
-- 2) Ticket-Felder für den Eingang
-- ---------------------------------------------------------------------
ALTER TABLE ticket
  ADD COLUMN external_id    text,       -- Message-ID bzw. Call-ID: macht Wiederholungen (Retries) harmlos
  ADD COLUMN sender_email   text,
  ADD COLUMN sender_phone   text,
  ADD COLUMN account_method text CHECK (account_method IN ('portal','contact_email','contact_phone','crm','manual'));

CREATE UNIQUE INDEX ticket_external_uk ON ticket (integration_id, external_id) WHERE external_id IS NOT NULL;

-- Vorschläge für die Review-Queue (und Nachvollziehbarkeit automatischer Entscheidungen)
CREATE TABLE ticket_account_suggestion (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL REFERENCES tenant(id),
  ticket_id  uuid NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
  account_id uuid NOT NULL,
  method     text NOT NULL CHECK (method IN ('contact_email','contact_phone','crm','domain')),
  confidence real NOT NULL,
  reason     text,
  status     text NOT NULL DEFAULT 'open' CHECK (status IN ('open','accepted','rejected')),
  decided_by uuid REFERENCES app_user(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (account_id, tenant_id) REFERENCES customer_account (id, tenant_id) ON DELETE CASCADE,
  UNIQUE (ticket_id, account_id)
);
CREATE INDEX suggestion_open_idx ON ticket_account_suggestion (tenant_id, status);

-- RLS: Alles hier ist nur für interne Nutzer des Eigentümer-Mandanten sichtbar
ALTER TABLE account_contact          ENABLE ROW LEVEL SECURITY;
ALTER TABLE account_contact          FORCE  ROW LEVEL SECURITY;
ALTER TABLE account_domain           ENABLE ROW LEVEL SECURITY;
ALTER TABLE account_domain           FORCE  ROW LEVEL SECURITY;
ALTER TABLE ticket_account_suggestion ENABLE ROW LEVEL SECURITY;
ALTER TABLE ticket_account_suggestion FORCE  ROW LEVEL SECURITY;

CREATE POLICY account_contact_rw ON account_contact FOR ALL
  USING      (tenant_id = current_tenant_id() AND current_audience() = 'internal')
  WITH CHECK (tenant_id = current_tenant_id() AND current_audience() = 'internal');
CREATE POLICY account_domain_rw ON account_domain FOR ALL
  USING      (tenant_id = current_tenant_id() AND current_audience() = 'internal')
  WITH CHECK (tenant_id = current_tenant_id() AND current_audience() = 'internal');
CREATE POLICY suggestion_rw ON ticket_account_suggestion FOR ALL
  USING      (tenant_id = current_tenant_id() AND current_audience() = 'internal')
  WITH CHECK (tenant_id = current_tenant_id() AND current_audience() = 'internal');

-- ---------------------------------------------------------------------
-- 3) Kandidaten bestimmen (rein lesend, mit RLS des Aufrufers)
-- ---------------------------------------------------------------------
CREATE FUNCTION resolve_account_candidates(
  p_email    text,
  p_phone    text,
  p_crm_ref  text,
  p_verified boolean
) RETURNS TABLE (account_id uuid, method text, confidence real)
LANGUAGE sql STABLE AS
$$
  WITH cand AS (
    SELECT ac.account_id AS acc, 'contact_email'::text AS method, 0.95::real AS base, true AS needs_verified
    FROM account_contact ac
    JOIN customer_account ca ON ca.id = ac.account_id AND ca.status = 'active'
    WHERE ac.tenant_id = current_tenant_id() AND ac.kind = 'email'
      AND p_email IS NOT NULL AND ac.value = lower(btrim(p_email))
    UNION ALL
    SELECT ac.account_id, 'contact_phone', 0.95::real, true
    FROM account_contact ac
    JOIN customer_account ca ON ca.id = ac.account_id AND ca.status = 'active'
    WHERE ac.tenant_id = current_tenant_id() AND ac.kind = 'phone'
      AND p_phone IS NOT NULL AND ac.value = btrim(p_phone)
    UNION ALL
    SELECT ca.id, 'crm', 0.92::real, true
    FROM customer_account ca
    WHERE ca.tenant_id = current_tenant_id() AND ca.status = 'active'
      AND p_crm_ref IS NOT NULL AND ca.external_ref = p_crm_ref
    UNION ALL
    SELECT ad.account_id, 'domain', 0.60::real, false
    FROM account_domain ad
    JOIN customer_account ca ON ca.id = ad.account_id AND ca.status = 'active'
    WHERE ad.tenant_id = current_tenant_id() AND p_email IS NOT NULL
      AND ad.domain = split_part(lower(btrim(p_email)), '@', 2)
      AND NOT EXISTS (SELECT 1 FROM freemail_domain f WHERE f.domain = ad.domain)
  )
  SELECT c.acc,
         c.method,
         (CASE WHEN c.needs_verified AND NOT coalesce(p_verified, false)
               THEN least(c.base, 0.50::real) ELSE c.base END)::real
  FROM cand c
$$;

-- ---------------------------------------------------------------------
-- 4) Ticket-Eingang (SECURITY INVOKER: RLS des Service-Nutzers gilt)
-- ---------------------------------------------------------------------
CREATE FUNCTION ticket_intake(
  p_integration      uuid,
  p_external_id      text,                     -- Message-ID / Call-ID
  p_subject          text,
  p_body             text    DEFAULT NULL,
  p_sender_email     text    DEFAULT NULL,
  p_sender_phone     text    DEFAULT NULL,     -- E.164
  p_sender_verified  boolean DEFAULT false,    -- NUR vom Worker gesetzt
  p_crm_account_ref  text    DEFAULT NULL      -- Ergebnis des CRM-Lookups (customer_account.external_ref)
) RETURNS TABLE (ticket_id uuid, account_id uuid, account_state text, is_duplicate boolean)
LANGUAGE plpgsql VOLATILE AS
$$
#variable_conflict use_column
DECLARE
  v_tenant   uuid := current_tenant_id();
  v_inst     uuid;
  v_kind     integration_kind_t;
  v_source   text;
  v_min      real;
  v_accs     uuid[];
  v_confs    real[];
  v_methods  text[];
  v_n        int;
  v_account  uuid;
  v_method   text;
  v_id       uuid;
  v_state    text;
  i          int;
BEGIN
  IF v_tenant IS NULL OR current_audience() IS DISTINCT FROM 'internal' THEN
    RAISE EXCEPTION 'intake requires an internal service context' USING ERRCODE = '42501';
  END IF;

  -- Integration muss dem aktiven Mandanten gehören (RLS) und aktiv sein
  SELECT i2.instance_id, i2.kind INTO v_inst, v_kind
  FROM integration i2 WHERE i2.id = p_integration AND i2.status = 'active';
  IF v_inst IS NULL THEN
    RAISE EXCEPTION 'integration not available' USING ERRCODE = '42501';
  END IF;
  IF NOT instance_active(v_inst) THEN
    RAISE EXCEPTION 'instance not active' USING ERRCODE = '42501';
  END IF;

  v_source := CASE v_kind WHEN 'mail' THEN 'email' WHEN 'aircall' THEN 'aircall' WHEN 'webform' THEN 'webform' END;
  IF v_source IS NULL THEN
    RAISE EXCEPTION 'integration kind not supported' USING ERRCODE = '22023';
  END IF;
  IF coalesce(btrim(p_subject), '') = '' THEN
    RAISE EXCEPTION 'subject required' USING ERRCODE = '22023';
  END IF;

  p_sender_email := nullif(lower(btrim(p_sender_email)), '');
  p_sender_phone := nullif(btrim(p_sender_phone), '');

  -- Schwelle aus Policy, aber nie unter 0.80 (Domain-Treffer und ungeprüfte Absender bleiben manuell)
  v_min := greatest(least(
             coalesce((SELECT (pol.value ->> 'auto_confirm_min')::real
                       FROM policy pol
                       WHERE pol.tenant_id = v_tenant AND pol.key = 'account_matching'),
                      0.90::real),
             1.00::real), 0.80::real);

  -- Beste Konfidenz je Konto, absteigend sortiert
  SELECT array_agg(g.acc    ORDER BY g.conf DESC, g.acc),
         array_agg(g.conf   ORDER BY g.conf DESC, g.acc),
         array_agg(g.method ORDER BY g.conf DESC, g.acc)
    INTO v_accs, v_confs, v_methods
  FROM (
    SELECT c.account_id AS acc,
           max(c.confidence) AS conf,
           (array_agg(c.method ORDER BY c.confidence DESC, c.method))[1] AS method
    FROM resolve_account_candidates(p_sender_email, p_sender_phone, p_crm_account_ref, p_sender_verified) c
    GROUP BY c.account_id
  ) g;

  v_n := coalesce(cardinality(v_accs), 0);

  -- Auto-Zuordnung: genau ein klarer Gewinner, kein ernsthafter Konkurrent
  IF v_n >= 1 AND v_confs[1] >= v_min AND (v_n = 1 OR v_confs[2] < 0.50::real) THEN
    v_account := v_accs[1];
    v_method  := v_methods[1];
  END IF;

  INSERT INTO ticket (instance_id, integration_id, account_id, account_method, source, subject, body,
                      external_id, sender_email, sender_phone)
  VALUES (v_inst, p_integration, v_account, v_method, v_source, left(p_subject, 300), left(p_body, 20000),
          p_external_id, left(p_sender_email, 320), left(p_sender_phone, 32))
  ON CONFLICT (integration_id, external_id) WHERE external_id IS NOT NULL DO NOTHING
  RETURNING id INTO v_id;

  -- Wiederholung (Retry oder paralleler Aufruf): bestehendes Ticket zurückgeben
  IF v_id IS NULL THEN
    SELECT t.id, t.account_id INTO v_id, v_account
    FROM ticket t WHERE t.integration_id = p_integration AND t.external_id = p_external_id;
    v_state := CASE
                 WHEN v_account IS NOT NULL THEN 'confirmed'
                 WHEN EXISTS (SELECT 1 FROM ticket_account_suggestion s
                              WHERE s.ticket_id = v_id AND s.status = 'open') THEN 'suggested'
                 ELSE 'unassigned' END;
    RETURN QUERY SELECT v_id, v_account, v_state, true;
    RETURN;
  END IF;

  -- Top-3-Kandidaten als Vorschläge (die automatisch gewählte Zuordnung als 'accepted')
  FOR i IN 1 .. least(v_n, 3) LOOP
    INSERT INTO ticket_account_suggestion (tenant_id, ticket_id, account_id, method, confidence, reason, status)
    VALUES (v_tenant, v_id, v_accs[i], v_methods[i], v_confs[i],
            'Treffer über ' || v_methods[i]
              || CASE WHEN p_sender_verified THEN '' ELSE ' (Absender nicht verifiziert)' END,
            CASE WHEN v_account IS NOT DISTINCT FROM v_accs[i] THEN 'accepted' ELSE 'open' END);
  END LOOP;

  v_state := CASE WHEN v_account IS NOT NULL THEN 'confirmed'
                  WHEN v_n > 0 THEN 'suggested'
                  ELSE 'unassigned' END;

  INSERT INTO audit_event (actor_id, tenant_id, instance_id, action, detail)
  VALUES (current_user_id(), v_tenant, v_inst, 'ticket.intake',
          jsonb_build_object('ticket_id', v_id, 'source', v_source,
                             'account_state', v_state, 'method', v_method));   -- keine Personendaten im Audit

  RETURN QUERY SELECT v_id, v_account, v_state, false;
END $$;

-- ---------------------------------------------------------------------
-- 5) Vorschlag bestätigen (interner Nutzer), optional Kontakt lernen
-- ---------------------------------------------------------------------
CREATE FUNCTION ticket_confirm_account(p_ticket uuid, p_account uuid, p_learn boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql VOLATILE AS    -- SECURITY INVOKER
$$
DECLARE
  v_tenant uuid := current_tenant_id();
  v_email  text;
  v_phone  text;
  n        int;
BEGIN
  IF v_tenant IS NULL OR current_audience() IS DISTINCT FROM 'internal' THEN
    RAISE EXCEPTION 'only internal users may assign accounts' USING ERRCODE = '42501';
  END IF;

  SELECT t.sender_email, t.sender_phone INTO v_email, v_phone FROM ticket t WHERE t.id = p_ticket;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ticket not found' USING ERRCODE = '42501';
  END IF;

  -- Konto muss im eigenen Mandanten existieren (RLS blendet fremde Konten aus)
  PERFORM 1 FROM customer_account ca WHERE ca.id = p_account AND ca.status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'account not found' USING ERRCODE = '42501';
  END IF;

  UPDATE ticket SET account_id = p_account, account_method = 'manual' WHERE id = p_ticket;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    RAISE EXCEPTION 'ticket cannot be changed' USING ERRCODE = '42501';
  END IF;

  UPDATE ticket_account_suggestion
     SET status     = CASE WHEN account_id = p_account THEN 'accepted' ELSE 'rejected' END,
         decided_by = current_user_id()
   WHERE ticket_id = p_ticket AND status = 'open';

  IF p_learn THEN
    IF v_email IS NOT NULL AND v_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
      INSERT INTO account_contact (tenant_id, account_id, kind, value, source)
      VALUES (v_tenant, p_account, 'email', lower(btrim(v_email)), 'learned')
      ON CONFLICT DO NOTHING;
    END IF;
    IF v_phone IS NOT NULL AND v_phone ~ '^\+[1-9][0-9]{6,14}$' THEN
      INSERT INTO account_contact (tenant_id, account_id, kind, value, source)
      VALUES (v_tenant, p_account, 'phone', v_phone, 'learned')
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  INSERT INTO audit_event (actor_id, tenant_id, action, detail)
  VALUES (current_user_id(), v_tenant, 'ticket.account_confirm',
          jsonb_build_object('ticket_id', p_ticket, 'account_id', p_account, 'learned', p_learn));
END $$;

-- ---------------------------------------------------------------------
-- 6) Rechte
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE
  ON account_contact, account_domain, ticket_account_suggestion TO app_runtime;
GRANT SELECT ON freemail_domain TO app_runtime;

REVOKE ALL ON FUNCTION resolve_account_candidates(text, text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION ticket_intake(uuid, text, text, text, text, text, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ticket_confirm_account(uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION resolve_account_candidates(text, text, text, boolean) TO app_runtime;
GRANT EXECUTE ON FUNCTION ticket_intake(uuid, text, text, text, text, text, boolean, text) TO app_runtime;
GRANT EXECUTE ON FUNCTION ticket_confirm_account(uuid, uuid, boolean) TO app_runtime;

COMMIT;
