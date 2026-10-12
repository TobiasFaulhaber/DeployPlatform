-- =====================================================================
-- RLS-Testsuite für die Plattform (reines SQL, kein pgTAP nötig)
--
-- Ausführen (als Superuser, gegen eine FRISCHE, leere Test-Datenbank):
--   createdb plattform_test
--   psql plattform_test -v ON_ERROR_STOP=1 \
--        -f platform_core_schema.sql \
--        -f platform_knowledge_pgvector.sql \
--        -f platform_v2_migration.sql \
--        -f platform_v3_customer_accounts.sql \
--        -f platform_v4_ticket_intake.sql \
--        -f platform_rls_test_suite.sql
--
-- Hinweise:
--   * Rollen (app_runtime, app_definer) sind clusterweit: bei erneutem Lauf
--     DB droppen UND die Rollen löschen (DROP ROLE app_runtime, app_definer).
--   * Alles läuft in EINER Transaktion und wird am Ende zurückgerollt.
--   * Endet mit Fehler (Exit-Code <> 0), wenn mindestens ein Test fehlschlägt.
--
-- Testpersonen:
--   Mandant A  = Kunde/Empfänger   u_a_int (intern), u_a_ext (extern, Konto Alpha), u_a_norole (intern, ohne Rolle)
--                                  Abschnitt 5 ergänzt u_a_ext2 (extern, Konto Beta) und u_a_ext0 (extern, ohne Konto)
--   Mandant B  = Anbieter/Publisher der App "Ticketing"   u_b_int
--   Mandant C  = zweiter, unbeteiligter Kunde             u_c_int
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;

-- ---------- Test-Framework -------------------------------------------
CREATE SCHEMA test;
CREATE TABLE test.result (name text, ok boolean, detail text);
GRANT USAGE ON SCHEMA test TO app_runtime;
GRANT INSERT, SELECT ON test.result TO app_runtime;

-- deterministische UUIDs aus lesbaren Namen
CREATE FUNCTION test.id(p_name text) RETURNS uuid
  LANGUAGE sql IMMUTABLE AS $$ SELECT md5(p_name)::uuid $$;

-- Einheitsvektor: Dimension i = 1, sonst 0 (gleiche Dimension = Score 1.0, verschieden = 0.0)
CREATE FUNCTION test.vec(i int) RETURNS vector
  LANGUAGE sql IMMUTABLE AS
$$ SELECT ('[' || array_to_string(ARRAY(SELECT (g = i)::int FROM generate_series(1, 1536) g), ',') || ']')::vector $$;

CREATE FUNCTION test.record(p_name text, p_ok boolean, p_detail text DEFAULT NULL) RETURNS void
  LANGUAGE plpgsql AS
$$
BEGIN
  INSERT INTO test.result VALUES (p_name, coalesce(p_ok, false), p_detail);
  RAISE NOTICE '[%] % %', CASE WHEN coalesce(p_ok, false) THEN 'PASS' ELSE 'FAIL' END,
               p_name, coalesce('– ' || p_detail, '');
END $$;

-- Sitzungskontext wie im Backend: DB-Rolle app_runtime + verifizierter Token-Kontext
CREATE FUNCTION test.as_user(p_user text, p_tenant text, p_aud text) RETURNS void
  LANGUAGE plpgsql AS
$$
BEGIN
  RESET ROLE;
  PERFORM set_config('app.user_id',   test.id(p_user)::text,   true);
  PERFORM set_config('app.tenant_id', test.id(p_tenant)::text, true);
  PERFORM set_config('app.audience',  coalesce(p_aud, ''),     true);
  SET LOCAL ROLE app_runtime;
END $$;

-- Sitzung ohne jeden Kontext (fail-closed-Tests)
CREATE FUNCTION test.as_none() RETURNS void
  LANGUAGE plpgsql AS
$$
BEGIN
  RESET ROLE;
  PERFORM set_config('app.user_id',   '', true);
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM set_config('app.audience',  '', true);
  SET LOCAL ROLE app_runtime;
END $$;

CREATE FUNCTION test.as_super() RETURNS void
  LANGUAGE plpgsql AS
$$
BEGIN
  RESET ROLE;
  PERFORM set_config('app.user_id',   '', true);
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM set_config('app.audience',  '', true);
END $$;

CREATE FUNCTION test.ok(p_name text, p_cond boolean, p_detail text DEFAULT NULL) RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN PERFORM test.record(p_name, p_cond, p_detail); END $$;

-- Anzahl Zeilen einer Abfrage (mit RLS des aktuellen Kontexts)
CREATE FUNCTION test.count_is(p_name text, p_expected bigint, p_sql text) RETURNS void
  LANGUAGE plpgsql AS
$$
DECLARE n bigint;
BEGIN
  EXECUTE format('SELECT count(*) FROM (%s) q', p_sql) INTO n;
  PERFORM test.record(p_name, n = p_expected, format('erwartet %s, erhalten %s', p_expected, n));
EXCEPTION WHEN OTHERS THEN
  PERFORM test.record(p_name, false, 'unerwarteter Fehler ' || SQLSTATE || ': ' || SQLERRM);
END $$;

-- Anweisung muss mit einem bestimmten SQLSTATE scheitern
-- (42501 = RLS-/Rechte-Verstoß, 55000 = Zustandsverstoß, 23514 = CHECK)
CREATE FUNCTION test.throws(p_name text, p_sql text, p_state text) RETURNS void
  LANGUAGE plpgsql AS
$$
BEGIN
  BEGIN
    EXECUTE p_sql;
    PERFORM test.record(p_name, false, 'kein Fehler, erwartet SQLSTATE ' || p_state);
  EXCEPTION WHEN OTHERS THEN
    PERFORM test.record(p_name, SQLSTATE = p_state, 'SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
  END;
END $$;

-- Anweisung muss erfolgreich laufen
CREATE FUNCTION test.runs(p_name text, p_sql text) RETURNS void
  LANGUAGE plpgsql AS
$$
BEGIN
  BEGIN
    EXECUTE p_sql;
    PERFORM test.record(p_name, true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM test.record(p_name, false, 'Fehler ' || SQLSTATE || ': ' || SQLERRM);
  END;
END $$;

-- UPDATE/DELETE: erwartete Anzahl betroffener Zeilen (RLS filtert still => 0)
CREATE FUNCTION test.affects(p_name text, p_expected bigint, p_sql text) RETURNS void
  LANGUAGE plpgsql AS
$$
DECLARE n bigint;
BEGIN
  EXECUTE p_sql;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM test.record(p_name, n = p_expected, format('erwartet %s, betroffen %s', p_expected, n));
EXCEPTION WHEN OTHERS THEN
  PERFORM test.record(p_name, false, 'unerwarteter Fehler ' || SQLSTATE || ': ' || SQLERRM);
END $$;

-- Suchabfrage als SQL-Text (Modell 'm1', Mindest-Score 0.55)
CREATE FUNCTION test.search_sql(p_instance text, p_vec int) RETURNS text
  LANGUAGE sql AS
$$ SELECT format('SELECT * FROM knowledge_search(%L::uuid, test.vec(%s), %L, NULL, 8, 0.55)',
                 test.id(p_instance), p_vec, 'm1') $$;

-- Ticket-Eingang als SQL-Text (Reihenfolge wie ticket_intake)
CREATE FUNCTION test.intake_sql(p_integration text, p_ext text, p_subject text, p_email text,
                                p_phone text, p_verified boolean, p_crm text) RETURNS text
  LANGUAGE sql AS
$$ SELECT format('SELECT * FROM ticket_intake(%L::uuid, %L, %L, NULL, %L, %L, %L::boolean, %L)',
                 test.id(p_integration), p_ext, p_subject, p_email, p_phone, p_verified, p_crm) $$;

-- Erwartung: erster Aufruf liefert genau diesen Zustand (confirmed/suggested/unassigned) und dieses Konto
CREATE FUNCTION test.intake_is(p_name text, p_state text, p_account text, p_integration text, p_ext text,
                               p_subject text, p_email text, p_phone text, p_verified boolean, p_crm text) RETURNS void
  LANGUAGE sql AS
$$ SELECT test.count_is(p_name, 1,
     format('SELECT 1 FROM (%s) r WHERE r.account_state = %L AND r.account_id IS NOT DISTINCT FROM %L::uuid AND NOT r.is_duplicate',
            test.intake_sql(p_integration, p_ext, p_subject, p_email, p_phone, p_verified, p_crm),
            p_state,
            CASE WHEN p_account IS NULL THEN NULL ELSE test.id(p_account) END)) $$;

-- ---------- Fixtures (als Superuser, RLS umgangen) -------------------
INSERT INTO tenant (id, name, slug) VALUES
  (test.id('tenant_a'), 'A Kunde',    'a'),
  (test.id('tenant_b'), 'B Anbieter', 'b'),
  (test.id('tenant_c'), 'C Kunde',    'c');

INSERT INTO app_user (id, email) VALUES
  (test.id('u_a_int'),    'agent@a.test'),
  (test.id('u_a_ext'),    'kunde@a.test'),
  (test.id('u_a_norole'), 'norole@a.test'),
  (test.id('u_b_int'),    'admin@b.test'),
  (test.id('u_c_int'),    'agent@c.test');

INSERT INTO membership (id, user_id, tenant_id, audience) VALUES
  (test.id('m_a_int'),    test.id('u_a_int'),    test.id('tenant_a'), 'internal'),
  (test.id('m_a_ext'),    test.id('u_a_ext'),    test.id('tenant_a'), 'external'),
  (test.id('m_a_norole'), test.id('u_a_norole'), test.id('tenant_a'), 'internal'),
  (test.id('m_b_int'),    test.id('u_b_int'),    test.id('tenant_b'), 'internal'),
  (test.id('m_c_int'),    test.id('u_c_int'),    test.id('tenant_c'), 'internal');

-- App des Anbieters B: zunächst im ENTWURF (nicht veröffentlicht)
INSERT INTO app (id, owner_tenant_id, name, audience, status) VALUES
  (test.id('app_b'), test.id('tenant_b'), 'Ticketing', 'internal', 'draft');

INSERT INTO app_role (id, app_id, key, name) VALUES
  (test.id('role_agent'), test.id('app_b'), 'agent', 'Agent');

-- B stellt die App A und C bereit (beide Freigaben aktiv, Vier-Augen erfüllt)
INSERT INTO app_grant (id, provider_tenant_id, recipient_tenant_id, app_id, branding_mode, status,
                       approved_by_provider, approved_by_recipient) VALUES
  (test.id('grant_ba'), test.id('tenant_b'), test.id('tenant_a'), test.id('app_b'), 'host',     'active',
   test.id('u_b_int'), test.id('u_a_int')),
  (test.id('grant_bc'), test.id('tenant_b'), test.id('tenant_c'), test.id('app_b'), 'provider', 'active',
   test.id('u_b_int'), test.id('u_c_int'));

INSERT INTO grant_role (grant_id, role_id) VALUES
  (test.id('grant_ba'), test.id('role_agent')),
  (test.id('grant_bc'), test.id('role_agent'));

-- Instanzen: tenant_id = Dateneigentümer. inst_b_own = eigene Vorschau-Instanz des Publishers
INSERT INTO app_instance (id, app_id, grant_id, tenant_id) VALUES
  (test.id('inst_ab'),    test.id('app_b'), test.id('grant_ba'), test.id('tenant_a')),
  (test.id('inst_bc'),    test.id('app_b'), test.id('grant_bc'), test.id('tenant_c')),
  (test.id('inst_b_own'), test.id('app_b'), NULL,                test.id('tenant_b'));

INSERT INTO role_assignment (instance_id, membership_id, role_id) VALUES
  (test.id('inst_ab'),    test.id('m_a_int'), test.id('role_agent')),
  (test.id('inst_ab'),    test.id('m_a_ext'), test.id('role_agent')),
  (test.id('inst_bc'),    test.id('m_c_int'), test.id('role_agent')),
  (test.id('inst_b_own'), test.id('m_b_int'), test.id('role_agent'));
-- u_a_norole hat bewusst KEINE Rolle

-- Wissen: owner_tenant_id wird per Trigger aus App bzw. Instanz abgeleitet
INSERT INTO knowledge_source (id, scope, app_id, instance_id, title, status, audience, valid_until, origin_uri) VALUES
  -- App-natives Wissen von B (Publisher)
  (test.id('k_native_pub'),     'app', test.id('app_b'), NULL, 'Rückgabe-Richtlinie', 'reviewed', 'external', NULL,               'https://b.test/returns'),
  (test.id('k_native_agent'),   'app', test.id('app_b'), NULL, 'Agent-Playbook',      'reviewed', 'internal', NULL,               NULL),
  (test.id('k_native_draft'),   'app', test.id('app_b'), NULL, 'Entwurf FAQ',         'draft',    'external', NULL,               NULL),
  (test.id('k_native_old'),     'app', test.id('app_b'), NULL, 'Veraltet',            'outdated', 'external', NULL,               NULL),
  (test.id('k_native_expired'), 'app', test.id('app_b'), NULL, 'Abgelaufen',          'reviewed', 'external', current_date - 1,   NULL),
  -- Mandantenspezifisches Wissen
  (test.id('k_a_int'),          'tenant', NULL, test.id('inst_ab'), 'A interne Preisliste', 'reviewed', 'internal', NULL, NULL),
  (test.id('k_a_ext'),          'tenant', NULL, test.id('inst_ab'), 'A Kundeninfo',         'reviewed', 'external', NULL, NULL),
  (test.id('k_c_int'),          'tenant', NULL, test.id('inst_bc'), 'C interne Notiz',      'reviewed', 'internal', NULL, NULL);

INSERT INTO knowledge_chunk (source_id, source_version, chunk_index, content, embedding, embedding_model, is_current) VALUES
  (test.id('k_native_pub'),     1, 0, 'Rückgaben sind 30 Tage möglich.',        test.vec(1), 'm1', true),
  (test.id('k_native_agent'),   1, 0, 'Eskalation ab Priorität 1 an Teamlead.', test.vec(2), 'm1', true),
  (test.id('k_native_draft'),   1, 0, 'Noch nicht geprüfte FAQ.',               test.vec(3), 'm1', true),
  (test.id('k_native_old'),     1, 0, 'Veraltete Regel.',                       test.vec(4), 'm1', true),
  (test.id('k_native_expired'), 1, 0, 'Abgelaufene Aktion.',                    test.vec(5), 'm1', true),
  (test.id('k_a_int'),          1, 0, 'Interne Rabattstaffel von A.',           test.vec(6), 'm1', true),
  (test.id('k_a_ext'),          1, 0, 'Öffnungszeiten von A.',                  test.vec(7), 'm1', true),
  (test.id('k_c_int'),          1, 0, 'Interne Notiz von C.',                   test.vec(8), 'm1', true);

-- Integrationen: A besitzt sein Postfach, B betreibt ein eigenes Postfach in A's Instanz, C hat ein Webform
INSERT INTO integration (id, owner_tenant_id, instance_id, kind, name) VALUES
  (test.id('int_a_mail'), test.id('tenant_a'), test.id('inst_ab'), 'mail',    'support@a.test'),
  (test.id('int_b_mail'), test.id('tenant_b'), test.id('inst_ab'), 'mail',    'helpdesk@b.test'),
  (test.id('int_c_form'), test.id('tenant_c'), test.id('inst_bc'), 'webform', 'Kontaktformular C');

-- Kundenkonten (Endkunden innerhalb eines Mandanten); u_a_ext gehört zum Konto Alpha
INSERT INTO customer_account (id, tenant_id, name, external_ref) VALUES
  (test.id('acct_a1'), test.id('tenant_a'), 'Alpha GmbH', 'SF-001'),
  (test.id('acct_a2'), test.id('tenant_a'), 'Beta AG',    'SF-002'),
  (test.id('acct_c1'), test.id('tenant_c'), 'C Endkunde', 'SF-900');

INSERT INTO membership_account (membership_id, account_id, tenant_id) VALUES
  (test.id('m_a_ext'), test.id('acct_a1'), test.id('tenant_a'));

-- Tickets: tenant_id wird per Trigger aus der Integration abgeleitet
INSERT INTO ticket (id, instance_id, integration_id, account_id, source, subject) VALUES
  (test.id('t_a1'), test.id('inst_ab'), test.id('int_a_mail'), test.id('acct_a1'), 'email',   'A Ticket'),
  (test.id('t_b1'), test.id('inst_ab'), test.id('int_b_mail'), NULL,               'email',   'B-hosted ticket'),
  (test.id('t_c1'), test.id('inst_bc'), test.id('int_c_form'), NULL,               'webform', 'C Ticket');

INSERT INTO ticket_comment (ticket_id, visibility, body) VALUES
  (test.id('t_a1'), 'public',   'A-öffentlich'),
  (test.id('t_a1'), 'internal', 'A-intern');

-- =====================================================================
-- Abschnitt 0: Identität und Mitgliedschaften
-- =====================================================================
DO $$
BEGIN
  RAISE NOTICE '--- 0. Identität und Mitgliedschaften ---';

  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('0.1 Interner Nutzer sieht die Nutzer des eigenen Mandanten', 3, 'SELECT 1 FROM app_user');
  PERFORM test.count_is('0.2 Nutzer anderer Mandanten (B) sind unsichtbar', 0,
                        'SELECT 1 FROM app_user WHERE email LIKE ''%@b.test''');
  PERFORM test.count_is('0.3 Interner Nutzer sieht alle Mitgliedschaften des Mandanten', 3, 'SELECT 1 FROM membership');

  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('0.4 Externer sieht nur sich selbst, keine internen Kollegen', 1, 'SELECT 1 FROM app_user');
  PERFORM test.count_is('0.5 Externer sieht nur die eigene Mitgliedschaft', 1, 'SELECT 1 FROM membership');
  PERFORM test.affects('0.6 Externer kann die eigene Mitgliedschaft nicht auf intern hochstufen', 0,
    format('UPDATE membership SET audience = ''internal'' WHERE user_id = %L', test.id('u_a_ext')));

  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.count_is('0.7 Anbieter sieht die Nutzer seiner Kunden nicht', 0,
                        'SELECT 1 FROM app_user WHERE email LIKE ''%@a.test'' OR email LIKE ''%@c.test''');
END $$;

-- =====================================================================
-- Abschnitt 1: App-natives Wissen wird mit der App veröffentlicht
-- =====================================================================
DO $$
BEGIN
  RAISE NOTICE '--- 1. App-natives Wissen (kommt mit der App, Eigentümer = Publisher) ---';

  -- Ausgangslage: App ist im Entwurf
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('1.1 App im Entwurf: Empfänger bekommt noch kein App-Wissen', 0, test.search_sql('inst_ab', 1));

  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.count_is('1.2 Publisher sieht sein App-Wissen als Vorschau in der eigenen Instanz', 1, test.search_sql('inst_b_own', 1));
  PERFORM test.count_is('1.3 Wissen im Entwurf wird nie ausgeliefert, auch nicht dem Publisher', 0, test.search_sql('inst_b_own', 3));

  -- Veröffentlichung
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.throws('1.4 Empfänger darf die App des Anbieters nicht veröffentlichen',
                      format('SELECT app_publish(%L)', test.id('app_b')), '42501');

  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.throws('1.5 Veröffentlichung wird blockiert, solange App-Wissen im Entwurf ist',
                      format('SELECT app_publish(%L)', test.id('app_b')), '55000');
  PERFORM test.affects('1.6 Publisher gibt das Wissen nach Prüfung frei', 1,
    format('UPDATE knowledge_source SET status = ''reviewed'' WHERE id = %L', test.id('k_native_draft')));
  PERFORM test.runs('1.7 Publisher veröffentlicht die App',
                    format('SELECT app_publish(%L)', test.id('app_b')));

  -- Nach der Veröffentlichung: Wissen ist beim Empfänger live
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('1.8 Nach Veröffentlichung: Empfänger (intern) erhält das App-Wissen', 1, test.search_sql('inst_ab', 1));
  PERFORM test.count_is('1.9 Zuvor freigegebener Entwurf wird jetzt mit ausgeliefert', 1, test.search_sql('inst_ab', 3));
  PERFORM test.count_is('1.10 Treffer nennt Quelle und Original-Link des Publishers', 1,
    format('SELECT * FROM (%s) s WHERE s.source_title = %L AND s.origin_uri = %L',
           test.search_sql('inst_ab', 1), 'Rückgabe-Richtlinie', 'https://b.test/returns'));
  PERFORM test.count_is('1.11 Internes App-Wissen (Agent-Playbook) erreicht interne Nutzer des Empfängers', 1, test.search_sql('inst_ab', 2));
  PERFORM test.count_is('1.12 Veraltetes Wissen wird nicht ausgeliefert', 0, test.search_sql('inst_ab', 4));
  PERFORM test.count_is('1.13 Abgelaufenes Wissen wird nicht ausgeliefert', 0, test.search_sql('inst_ab', 5));
  PERFORM test.count_is('1.14 Nicht passende Frage liefert 0 Treffer (Übergabe an Mensch)', 0, test.search_sql('inst_ab', 100));

  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('1.15 Externer Nutzer erhält extern freigegebenes App-Wissen', 1, test.search_sql('inst_ab', 1));
  PERFORM test.count_is('1.16 Externer Nutzer erhält kein internes App-Wissen', 0, test.search_sql('inst_ab', 2));

  PERFORM test.as_user('u_c_int', 'tenant_c', 'internal');
  PERFORM test.count_is('1.17 Auch der zweite Empfänger (C) bekommt das App-Wissen', 1, test.search_sql('inst_bc', 1));

  -- Wissen gehört dem Publisher: Empfänger kann es weder lesen noch ergänzen
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('1.18 Empfänger kann App-Wissen nicht direkt lesen', 0,
                        'SELECT 1 FROM knowledge_source WHERE scope = ''app''');
  PERFORM test.count_is('1.19 Empfänger sieht keine Chunks fremder Mandanten', 0,
                        'SELECT 1 FROM knowledge_chunk WHERE tenant_id <> current_tenant_id()');
  PERFORM test.throws('1.20 Empfänger kann kein App-Wissen in die Anbieter-App einschleusen',
    format('INSERT INTO knowledge_source (scope, app_id, title, status, audience) VALUES (''app'', %L, ''Fake'', ''reviewed'', ''external'')',
           test.id('app_b')), '42501');

  -- Zurückziehen: App archivieren => Wissen verschwindet beim Empfänger, nicht in der Vorschau
  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.affects('1.21 Publisher zieht die App zurück', 1,
    format('UPDATE app SET status = ''archived'' WHERE id = %L', test.id('app_b')));
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('1.22 Zurückgezogene App: Wissen verschwindet beim Empfänger', 0, test.search_sql('inst_ab', 1));
  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.count_is('1.23 Publisher behält die Vorschau in der eigenen Instanz', 1, test.search_sql('inst_b_own', 1));
  PERFORM test.runs('1.24 Erneut veröffentlichen', format('SELECT app_publish(%L)', test.id('app_b')));
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('1.25 Nach erneuter Veröffentlichung ist das Wissen wieder da', 1, test.search_sql('inst_ab', 1));
END $$;

-- =====================================================================
-- Abschnitt 2: Mandantenspezifisches Wissen (Eigentümer = Instanz-Mandant)
-- =====================================================================
DO $$
BEGIN
  RAISE NOTICE '--- 2. Mandantenspezifisches Wissen ---';

  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('2.1 Mandant A findet sein internes Wissen', 1, test.search_sql('inst_ab', 6));

  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('2.2 Externer Nutzer von A findet kein internes Mandantenwissen', 0, test.search_sql('inst_ab', 6));
  PERFORM test.count_is('2.3 Externer Nutzer von A findet extern freigegebenes Mandantenwissen', 1, test.search_sql('inst_ab', 7));

  -- Anbieter B sieht das Wissen seiner Kunden nie
  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.count_is('2.4 Publisher sieht Mandantenwissen nicht in der Datenbank', 0,
                        'SELECT 1 FROM knowledge_source WHERE scope = ''tenant''');
  PERFORM test.count_is('2.5 Publisher findet Mandantenwissen nicht über die eigene Instanz', 0, test.search_sql('inst_b_own', 6));
  PERFORM test.throws('2.6 Publisher darf die Instanz seines Kunden nicht durchsuchen', test.search_sql('inst_ab', 6), '42501');
  PERFORM test.throws('2.7 Publisher kann kein Mandantenwissen in die Instanz seines Kunden einschleusen',
    format('INSERT INTO knowledge_source (scope, instance_id, title, status, audience) VALUES (''tenant'', %L, ''Fake'', ''reviewed'', ''external'')',
           test.id('inst_ab')), '42501');

  -- Zweiter Kunde C ist isoliert
  PERFORM test.as_user('u_c_int', 'tenant_c', 'internal');
  PERFORM test.count_is('2.8 Kunde C findet das Mandantenwissen von A nicht', 0, test.search_sql('inst_bc', 6));
  PERFORM test.count_is('2.9 Kunde C findet sein eigenes Mandantenwissen', 1, test.search_sql('inst_bc', 8));
  PERFORM test.throws('2.10 Kunde C darf die Instanz von A nicht durchsuchen', test.search_sql('inst_ab', 6), '42501');

  -- A pflegt eigenes Wissen ohne Zutun des Publishers
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.runs('2.11 Mandant A legt eigenes Wissen in seiner Instanz an',
    format('INSERT INTO knowledge_source (id, scope, instance_id, title, status, audience) VALUES (%L, ''tenant'', %L, ''A neu'', ''reviewed'', ''internal'')',
           test.id('k_a_new'), test.id('inst_ab')));
  PERFORM test.runs('2.12 Mandant A fügt Chunks hinzu',
    format('INSERT INTO knowledge_chunk (source_id, source_version, chunk_index, content, embedding, embedding_model, is_current) VALUES (%L, 1, 0, ''Neues Wissen von A.'', test.vec(9), ''m1'', true)',
           test.id('k_a_new')));
  PERFORM test.count_is('2.13 Neues Mandantenwissen ist sofort durchsuchbar', 1, test.search_sql('inst_ab', 9));

  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.count_is('2.14 Publisher sieht das neue Mandantenwissen nicht', 0, test.search_sql('inst_b_own', 9));

  -- Externe dürfen kein Wissen schreiben
  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.throws('2.15 Externer Nutzer kann kein Wissen anlegen',
    format('INSERT INTO knowledge_source (scope, instance_id, title, status, audience) VALUES (''tenant'', %L, ''Fake'', ''reviewed'', ''external'')',
           test.id('inst_ab')), '42501');
  PERFORM test.count_is('2.16 Externer Nutzer kann Chunks nie direkt lesen', 0, 'SELECT 1 FROM knowledge_chunk');
END $$;

-- =====================================================================
-- Abschnitt 3: Transaktionen folgen der Integration
-- =====================================================================
DO $$
BEGIN
  RAISE NOTICE '--- 3. Integrationen und Transaktionen ---';

  -- Wer die Integration besitzt, besitzt die Tickets
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('3.1 A sieht genau die Tickets seiner eigenen Integration', 1, 'SELECT 1 FROM ticket');
  PERFORM test.count_is('3.2 A sieht das Ticket aus B''s Postfach nicht (obwohl in A''s Instanz)', 0,
                        'SELECT 1 FROM ticket WHERE subject = ''B-hosted ticket''');
  PERFORM test.count_is('3.3 A sieht nur die eigene Integration', 1, 'SELECT 1 FROM integration');

  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.count_is('3.4 B sieht genau die Tickets seiner eigenen Integration', 1, 'SELECT 1 FROM ticket');
  PERFORM test.count_is('3.5 Anbieter hat KEINEN impliziten Zugriff auf Tickets des Kunden', 0,
                        'SELECT 1 FROM ticket WHERE subject = ''A Ticket''');
  PERFORM test.count_is('3.6 B sieht nur die eigene Integration', 1, 'SELECT 1 FROM integration');

  PERFORM test.as_user('u_c_int', 'tenant_c', 'internal');
  PERFORM test.count_is('3.7 Unbeteiligter Kunde C sieht nur seine eigenen Tickets', 1, 'SELECT 1 FROM ticket');

  -- Tickets entstehen nur über eigene Integrationen; der Eigentümer wird abgeleitet
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.runs('3.8 A legt Ticket über die eigene Integration an (tenant_id im Request gefälscht)',
    format('INSERT INTO ticket (tenant_id, instance_id, integration_id, source, subject) VALUES (%L, %L, %L, ''email'', ''Fälschung'')',
           test.id('tenant_b'), test.id('inst_ab'), test.id('int_a_mail')));
  PERFORM test.ok('3.9 tenant_id stammt aus der Integration, nicht aus der Eingabe',
    (SELECT tenant_id FROM ticket WHERE subject = 'Fälschung') = test.id('tenant_a'));
  PERFORM test.throws('3.10 A kann kein Ticket über die Integration von B anlegen',
    format('INSERT INTO ticket (instance_id, integration_id, source, subject) VALUES (%L, %L, ''email'', ''Einschleusen'')',
           test.id('inst_ab'), test.id('int_b_mail')), '42501');

  -- Integrationen registrieren
  PERFORM test.throws('3.11 A kann keine Integration im Namen von B registrieren',
    format('INSERT INTO integration (owner_tenant_id, instance_id, kind, name) VALUES (%L, %L, ''mail'', ''x@b.test'')',
           test.id('tenant_b'), test.id('inst_ab')), '42501');
  PERFORM test.throws('3.12 A kann keine Integration in der Instanz eines fremden Kunden (C) registrieren',
    format('INSERT INTO integration (owner_tenant_id, instance_id, kind, name) VALUES (%L, %L, ''mail'', ''x@a.test'')',
           test.id('tenant_a'), test.id('inst_bc')), '42501');

  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.runs('3.13 Anbieter B darf eine eigene Integration in der Instanz seines Kunden betreiben',
    format('INSERT INTO integration (owner_tenant_id, instance_id, kind, name) VALUES (%L, %L, ''aircall'', ''Hotline B'')',
           test.id('tenant_b'), test.id('inst_ab')));

  -- Kommentare: intern/öffentlich
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('3.14 Interner Nutzer sieht öffentliche und interne Kommentare', 2, 'SELECT 1 FROM ticket_comment');

  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('3.15 Externer Nutzer sieht nur öffentliche Kommentare', 1, 'SELECT 1 FROM ticket_comment');
  PERFORM test.throws('3.16 Externer Nutzer kann keinen internen Kommentar schreiben',
    format('INSERT INTO ticket_comment (ticket_id, visibility, body) VALUES (%L, ''internal'', ''x'')', test.id('t_a1')), '42501');
  PERFORM test.runs('3.17 Externer Nutzer kann einen öffentlichen Kommentar schreiben',
    format('INSERT INTO ticket_comment (ticket_id, visibility, body) VALUES (%L, ''public'', ''Rückfrage vom Kunden'')', test.id('t_a1')));

  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.count_is('3.18 Anbieter sieht keine Kommentare der Kunden-Tickets', 0, 'SELECT 1 FROM ticket_comment');
END $$;

-- =====================================================================
-- Abschnitt 4: Fail-closed, Protokoll, Feedback
-- =====================================================================
DO $$
DECLARE v_q uuid; v_c uuid;
BEGIN
  RAISE NOTICE '--- 4. Fail-closed, Protokoll und Feedback ---';

  PERFORM test.as_none();
  PERFORM test.count_is('4.1 Ohne Kontext: keine Tickets sichtbar', 0, 'SELECT 1 FROM ticket');
  PERFORM test.count_is('4.2 Ohne Kontext: keine Wissensquellen sichtbar', 0, 'SELECT 1 FROM knowledge_source');
  PERFORM test.count_is('4.3 Ohne Kontext: keine Nutzer sichtbar', 0, 'SELECT 1 FROM app_user');
  PERFORM test.throws('4.4 Ohne Kontext: Wissenssuche wird verweigert', test.search_sql('inst_ab', 1), '42501');

  -- Audience fehlt => wie extern behandelt
  PERFORM test.as_user('u_a_int', 'tenant_a', NULL);
  PERFORM test.count_is('4.5 Fehlende Audience: internes Wissen bleibt verborgen', 0, test.search_sql('inst_ab', 2));
  PERFORM test.count_is('4.6 Fehlende Audience: extern freigegebenes Wissen bleibt erreichbar', 1, test.search_sql('inst_ab', 1));

  -- Nutzer ohne Rolle in der Instanz
  PERFORM test.as_user('u_a_norole', 'tenant_a', 'internal');
  PERFORM test.throws('4.7 Nutzer ohne Rolle in der Instanz kann nicht suchen', test.search_sql('inst_ab', 1), '42501');

  -- Abfrage-Log und Lückenanalyse
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('4.8 Unbeantwortete Frage (0 Treffer)', 0,
    format('SELECT * FROM knowledge_search(%L::uuid, test.vec(100), ''m1'', ''Wie kündige ich?'', 8, 0.55)', test.id('inst_ab')));
  PERFORM test.count_is('4.9 Lückenanalyse zeigt die unbeantwortete Frage', 1,
    'SELECT 1 FROM knowledge_gap_report WHERE question = ''wie kündige ich?''');
  PERFORM test.count_is('4.10 Abfrage-Log enthält nur Einträge des eigenen Mandanten', 0,
    'SELECT 1 FROM knowledge_query_log WHERE tenant_id <> current_tenant_id()');
  PERFORM test.ok('4.11 Interner Nutzer sieht Abfrage-Log des eigenen Mandanten',
    (SELECT count(*) FROM knowledge_query_log) > 0);

  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('4.12 Externer Nutzer kann das Abfrage-Log nicht lesen', 0, 'SELECT 1 FROM knowledge_query_log');

  -- Feedback
  SELECT s.query_id, s.chunk_id INTO v_q, v_c
  FROM knowledge_search(test.id('inst_ab'), test.vec(1), 'm1', 'rückgabe', 8, 0.55) s LIMIT 1;
  PERFORM test.ok('4.13 Suche liefert eine query_id für Feedback', v_q IS NOT NULL);
  PERFORM test.runs('4.14 Externer Nutzer gibt Feedback zur eigenen Abfrage',
    format('SELECT knowledge_submit_feedback(%L, %L, true, ''hilfreich'')', v_q, v_c));

  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.throws('4.15 Feedback zu einer fremden Abfrage wird verweigert',
    format('SELECT knowledge_submit_feedback(%L, %L, false, NULL)', v_q, v_c), '42501');
  PERFORM test.count_is('4.16 Interner Nutzer sieht das eingegangene Feedback', 1, 'SELECT 1 FROM knowledge_feedback');

  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('4.17 Externer Nutzer kann Feedback anderer nicht lesen', 0, 'SELECT 1 FROM knowledge_feedback');
END $$;

-- =====================================================================
-- Abschnitt 5: Kundenkonten – Externe sehen nur "ihre" Datensätze
-- =====================================================================
DO $$
BEGIN
  RAISE NOTICE '--- 5. Kundenkonten (Account-Scoping für externe Nutzer) ---';

  -- Zusätzliche Fixtures (Superuser)
  PERFORM test.as_super();
  INSERT INTO app_user (id, email) VALUES
    (test.id('u_a_ext2'), 'kunde2@a.test'),
    (test.id('u_a_ext0'), 'kunde0@a.test');
  INSERT INTO membership (id, user_id, tenant_id, audience) VALUES
    (test.id('m_a_ext2'), test.id('u_a_ext2'), test.id('tenant_a'), 'external'),
    (test.id('m_a_ext0'), test.id('u_a_ext0'), test.id('tenant_a'), 'external');
  INSERT INTO membership_account (membership_id, account_id, tenant_id) VALUES
    (test.id('m_a_ext2'), test.id('acct_a2'), test.id('tenant_a'));     -- ext0 hat bewusst kein Konto
  INSERT INTO role_assignment (instance_id, membership_id, role_id) VALUES
    (test.id('inst_ab'), test.id('m_a_ext2'), test.id('role_agent')),
    (test.id('inst_ab'), test.id('m_a_ext0'), test.id('role_agent'));
  INSERT INTO integration (id, owner_tenant_id, instance_id, kind, name) VALUES
    (test.id('int_a_form'), test.id('tenant_a'), test.id('inst_ab'), 'webform', 'Kundenportal A');
  INSERT INTO ticket (id, instance_id, integration_id, account_id, source, subject) VALUES
    (test.id('t_a2'), test.id('inst_ab'), test.id('int_a_mail'), test.id('acct_a2'), 'email', 'Ticket Beta'),
    (test.id('t_a3'), test.id('inst_ab'), test.id('int_a_mail'), NULL,               'email', 'Ticket ohne Konto');
  INSERT INTO ticket_comment (ticket_id, visibility, body) VALUES
    (test.id('t_a2'), 'public', 'Beta-öffentlich');

  -- Lesen: Ticket-Sichtbarkeit nach Konto
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('5.1 Interner Nutzer sieht alle Tickets des Mandanten (mit und ohne Konto)', 4, 'SELECT 1 FROM ticket');
  PERFORM test.count_is('5.2 Interner Nutzer sieht alle Kommentare (öffentlich und intern)', 4, 'SELECT 1 FROM ticket_comment');
  PERFORM test.count_is('5.3 Interner Nutzer sieht alle Kundenkonten des Mandanten, aber keine fremden', 2, 'SELECT 1 FROM customer_account');

  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('5.4 Externer (Konto Alpha) sieht nur Tickets des eigenen Kontos', 1, 'SELECT 1 FROM ticket');
  PERFORM test.count_is('5.5 ... nicht das Ticket des anderen Kontos (Beta)', 0, 'SELECT 1 FROM ticket WHERE subject = ''Ticket Beta''');
  PERFORM test.count_is('5.6 ... und keine Tickets ohne Konto-Zuordnung', 0, 'SELECT 1 FROM ticket WHERE subject = ''Ticket ohne Konto''');
  PERFORM test.count_is('5.7 Externer sieht nur öffentliche Kommentare der eigenen Tickets', 2, 'SELECT 1 FROM ticket_comment');
  PERFORM test.count_is('5.8 Externer sieht nur das eigene Kundenkonto', 1, 'SELECT 1 FROM customer_account');
  PERFORM test.count_is('5.9 Externer kann Integrationen (Konfiguration) nicht lesen', 0, 'SELECT 1 FROM integration');

  PERFORM test.as_user('u_a_ext2', 'tenant_a', 'external');
  PERFORM test.count_is('5.10 Externer (Konto Beta) sieht nur das Ticket seines Kontos', 1, 'SELECT 1 FROM ticket');
  PERFORM test.count_is('5.11 ... und dessen öffentlichen Kommentar', 1, 'SELECT 1 FROM ticket_comment');

  PERFORM test.as_user('u_a_ext0', 'tenant_a', 'external');
  PERFORM test.count_is('5.12 Externer ohne Konto sieht keine Tickets', 0, 'SELECT 1 FROM ticket');
  PERFORM test.count_is('5.13 Externer ohne Konto sieht keine Kommentare', 0, 'SELECT 1 FROM ticket_comment');

  -- Schreiben: Externe nur über das Portal
  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.throws('5.14 Externer kann kein Ticket per direktem INSERT anlegen',
    format('INSERT INTO ticket (instance_id, integration_id, account_id, source, subject) VALUES (%L, %L, %L, ''webform'', ''direkt'')',
           test.id('inst_ab'), test.id('int_a_form'), test.id('acct_a1')), '42501');
  PERFORM test.affects('5.15 Externer kann Tickets nicht ändern', 0,
    format('UPDATE ticket SET subject = ''manipuliert'' WHERE id = %L', test.id('t_a1')));
  PERFORM test.affects('5.16 Externer kann Tickets nicht löschen', 0,
    format('DELETE FROM ticket WHERE id = %L', test.id('t_a1')));
  PERFORM test.throws('5.17 Externer kann sich nicht selbst einem anderen Konto zuordnen',
    format('INSERT INTO membership_account (membership_id, account_id, tenant_id) VALUES (%L, %L, %L)',
           test.id('m_a_ext'), test.id('acct_a2'), test.id('tenant_a')), '42501');
  PERFORM test.throws('5.18 Externer kann keine Kundenkonten anlegen',
    format('INSERT INTO customer_account (tenant_id, name) VALUES (%L, ''Fake AG'')', test.id('tenant_a')), '42501');

  PERFORM test.runs('5.19 Externer legt Ticket über das Portal an (Konto wird automatisch bestimmt)',
    format('SELECT portal_create_ticket(%L, %L, %L)', test.id('int_a_form'), 'Mein Problem', 'Beschreibung'));
  PERFORM test.count_is('5.20 Portal-Ticket trägt das Konto des Nutzers', 1,
    format('SELECT 1 FROM ticket WHERE subject = ''Mein Problem'' AND account_id = %L', test.id('acct_a1')));
  PERFORM test.throws('5.21 Portal: Ticket für ein fremdes Konto wird verweigert',
    format('SELECT portal_create_ticket(%L, %L, NULL, %L)', test.id('int_a_form'), 'Fremdes Konto', test.id('acct_a2')), '42501');
  PERFORM test.throws('5.22 Portal: nur Webform-Integrationen sind zulässig (Postfach nicht)',
    format('SELECT portal_create_ticket(%L, %L)', test.id('int_a_mail'), 'Über Postfach'), '42501');
  PERFORM test.throws('5.23 Portal: Integration eines anderen Mandanten wird verweigert',
    format('SELECT portal_create_ticket(%L, %L)', test.id('int_c_form'), 'Fremder Mandant'), '42501');

  PERFORM test.as_user('u_a_ext0', 'tenant_a', 'external');
  PERFORM test.throws('5.24 Portal: Externer ohne Kundenkonto kann kein Ticket anlegen',
    format('SELECT portal_create_ticket(%L, %L)', test.id('int_a_form'), 'Ohne Konto'), '42501');

  PERFORM test.as_user('u_a_ext2', 'tenant_a', 'external');
  PERFORM test.runs('5.25 Anderer Externer (Konto Beta) legt Portal-Ticket an',
    format('SELECT portal_create_ticket(%L, %L)', test.id('int_a_form'), 'Beta Anfrage'));
  PERFORM test.count_is('5.26 Konto Beta sieht jetzt zwei Tickets', 2, 'SELECT 1 FROM ticket');

  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('5.27 Konto Alpha sieht weiterhin nur die eigenen zwei Tickets (kein Durchgriff)', 2, 'SELECT 1 FROM ticket');

  -- Interne Zuordnung und Mandantengrenze
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.throws('5.28 Ticket kann keinem Konto eines anderen Mandanten zugeordnet werden',
    format('UPDATE ticket SET account_id = %L WHERE subject = ''Ticket ohne Konto''', test.id('acct_c1')), '23503');
  PERFORM test.throws('5.29 Mitgliedschaft kann keinem Konto eines anderen Mandanten zugeordnet werden',
    format('INSERT INTO membership_account (membership_id, account_id, tenant_id) VALUES (%L, %L, %L)',
           test.id('m_a_ext'), test.id('acct_c1'), test.id('tenant_a')), '23503');
  PERFORM test.affects('5.30 Interner Nutzer ordnet ein bisher unzugeordnetes Ticket dem Konto Beta zu', 1,
    format('UPDATE ticket SET account_id = %L WHERE subject = ''Ticket ohne Konto''', test.id('acct_a2')));

  PERFORM test.as_user('u_a_ext2', 'tenant_a', 'external');
  PERFORM test.count_is('5.31 Konto Beta sieht das neu zugeordnete Ticket sofort', 3, 'SELECT 1 FROM ticket');
  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('5.32 Konto Alpha sieht das Ticket weiterhin nicht', 2, 'SELECT 1 FROM ticket');

  -- Andere Mandanten sehen nichts
  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.count_is('5.33 Anbieter sieht keine Kundenkonten seiner Kunden', 0, 'SELECT 1 FROM customer_account');
  PERFORM test.as_user('u_c_int', 'tenant_c', 'internal');
  PERFORM test.count_is('5.34 Kunde C sieht nur das eigene Kundenkonto', 1, 'SELECT 1 FROM customer_account');
END $$;

-- =====================================================================
-- Abschnitt 6: Ticket-Eingang – automatische Konto-Zuordnung
-- =====================================================================
DO $$
DECLARE v_t uuid; v_unassigned uuid; v_amb uuid;
BEGIN
  RAISE NOTICE '--- 6. Ticket-Eingang: automatische Konto-Zuordnung ---';

  -- Fixtures (Superuser): Kontakte, Domains, Hotline-Integration
  PERFORM test.as_super();
  INSERT INTO account_contact (tenant_id, account_id, kind, value, source) VALUES
    (test.id('tenant_a'), test.id('acct_a1'), 'email', 'anna@alpha.test',   'crm'),
    (test.id('tenant_a'), test.id('acct_a1'), 'phone', '+4921112345',       'crm'),
    (test.id('tenant_a'), test.id('acct_a2'), 'email', 'ben@beta.test',     'crm'),
    (test.id('tenant_a'), test.id('acct_a1'), 'email', 'shared@multi.test', 'manual'),
    (test.id('tenant_a'), test.id('acct_a2'), 'email', 'shared@multi.test', 'manual');
  INSERT INTO account_domain (tenant_id, account_id, domain) VALUES
    (test.id('tenant_a'), test.id('acct_a1'), 'alpha.test'),
    (test.id('tenant_a'), test.id('acct_a2'), 'beta.test'),
    (test.id('tenant_a'), test.id('acct_a2'), 'gmail.com');             -- Freemailer: darf nie zählen
  INSERT INTO integration (id, owner_tenant_id, instance_id, kind, name) VALUES
    (test.id('int_a_call'), test.id('tenant_a'), test.id('inst_ab'), 'aircall', 'Hotline A');

  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');

  -- E-Mail: Kontakt, Verifizierung, Domain
  PERFORM test.intake_is('6.1 Mail eines bekannten Kontakts (verifiziert) wird automatisch dem Konto zugeordnet',
    'confirmed', 'acct_a1', 'int_a_mail', 'm-001', 'Intake 6.1', 'anna@alpha.test', NULL, true, NULL);
  PERFORM test.count_is('6.2 Zuordnungsmethode wird am Ticket festgehalten', 1,
    format('SELECT 1 FROM ticket WHERE subject = ''Intake 6.1'' AND account_id = %L AND account_method = ''contact_email''',
           test.id('acct_a1')));
  PERFORM test.count_is('6.3 Automatische Entscheidung ist als akzeptierter Vorschlag nachvollziehbar', 1,
    'SELECT 1 FROM ticket_account_suggestion s JOIN ticket t ON t.id = s.ticket_id WHERE t.subject = ''Intake 6.1'' AND s.status = ''accepted'' AND s.method = ''contact_email''');

  PERFORM test.intake_is('6.4 Gleicher Absender, aber nicht verifiziert (Fälschung möglich): nur Vorschlag',
    'suggested', NULL, 'int_a_mail', 'm-004', 'Intake 6.4 unverifiziert', 'anna@alpha.test', NULL, false, NULL);
  PERFORM test.count_is('6.5 ... der Vorschlag liegt offen in der Review-Queue', 1,
    'SELECT 1 FROM ticket_account_suggestion s JOIN ticket t ON t.id = s.ticket_id WHERE t.subject = ''Intake 6.4 unverifiziert'' AND s.status = ''open''');

  PERFORM test.intake_is('6.6 Nur Domain-Treffer wird nie automatisch zugeordnet',
    'suggested', NULL, 'int_a_mail', 'm-006', 'Intake 6.6 nur Domain', 'newperson@alpha.test', NULL, true, NULL);

  PERFORM test.intake_is('6.7 Freemail-Domain (gmail.com) liefert keinen Treffer',
    'unassigned', NULL, 'int_a_mail', 'm-007', 'Intake 6.7 Freemail', 'privat@gmail.com', NULL, true, NULL);
  PERFORM test.count_is('6.8 ... und auch keinen Vorschlag', 0,
    'SELECT 1 FROM ticket_account_suggestion s JOIN ticket t ON t.id = s.ticket_id WHERE t.subject = ''Intake 6.7 Freemail''');

  PERFORM test.intake_is('6.9 Mehrdeutiger Kontakt (gehört zu zwei Konten): keine Auto-Zuordnung',
    'suggested', NULL, 'int_a_mail', 'm-009', 'Intake 6.9 mehrdeutig', 'shared@multi.test', NULL, true, NULL);
  PERFORM test.count_is('6.10 ... beide Konten stehen als Vorschlag zur Auswahl', 2,
    'SELECT 1 FROM ticket_account_suggestion s JOIN ticket t ON t.id = s.ticket_id WHERE t.subject = ''Intake 6.9 mehrdeutig''');

  -- Telefon (Aircall)
  PERFORM test.intake_is('6.11 Anruf: bestätigte Rufnummer wird automatisch zugeordnet',
    'confirmed', 'acct_a1', 'int_a_call', 'c-011', 'Intake 6.11 Anruf', NULL, '+4921112345', true, NULL);
  PERFORM test.count_is('6.12 ... mit Methode contact_phone', 1,
    format('SELECT 1 FROM ticket WHERE subject = ''Intake 6.11 Anruf'' AND source = ''aircall'' AND account_method = ''contact_phone'' AND account_id = %L',
           test.id('acct_a1')));
  PERFORM test.intake_is('6.13 Anruf mit unbestätigter Rufnummer (Caller-ID-Spoofing): nur Vorschlag',
    'suggested', NULL, 'int_a_call', 'c-013', 'Intake 6.13 Anruf unbestätigt', NULL, '+4921112345', false, NULL);

  -- CRM-Lookup des Workers
  PERFORM test.intake_is('6.14 CRM-Treffer (verifiziert) ordnet automatisch zu',
    'confirmed', 'acct_a2', 'int_a_mail', 'm-014', 'Intake 6.14 CRM', 'unknown@neu.test', NULL, true, 'SF-002');
  PERFORM test.intake_is('6.15 Widerspruch zwischen Kontakt (Alpha) und CRM (Beta): keine Auto-Zuordnung',
    'suggested', NULL, 'int_a_mail', 'm-015', 'Intake 6.15 Widerspruch', 'anna@alpha.test', NULL, true, 'SF-002');
  PERFORM test.count_is('6.16 ... beide Konten stehen als Vorschlag zur Auswahl', 2,
    'SELECT 1 FROM ticket_account_suggestion s JOIN ticket t ON t.id = s.ticket_id WHERE t.subject = ''Intake 6.15 Widerspruch''');
  PERFORM test.intake_is('6.17 Unbekannter Absender und unbekannte CRM-ID: bleibt ohne Konto',
    'unassigned', NULL, 'int_a_mail', 'm-017', 'Intake 6.17 unbekannt', 'who@neu.test', NULL, true, 'SF-999');

  -- Öffentliches Webform ist nie verifiziert
  PERFORM test.intake_is('6.18 Öffentliches Webform ordnet nie automatisch zu, auch bei bekannter Adresse',
    'suggested', NULL, 'int_a_form', 'w-018', 'Intake 6.18 Webform', 'anna@alpha.test', NULL, false, NULL);

  -- Idempotenz
  PERFORM test.count_is('6.19 Wiederholung mit gleicher Message-ID liefert das bestehende Ticket', 1,
    format('SELECT 1 FROM (%s) r WHERE r.is_duplicate AND r.account_state = ''confirmed'' AND r.account_id = %L',
           test.intake_sql('int_a_mail', 'm-001', 'Intake 6.1 Wiederholung', 'anna@alpha.test', NULL, true, NULL),
           test.id('acct_a1')));
  PERFORM test.count_is('6.20 ... es existiert weiterhin genau ein Ticket dazu', 1,
    'SELECT 1 FROM ticket WHERE external_id = ''m-001''');

  -- Wirkung auf externe Nutzer
  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('6.21 Externer (Konto Alpha) sieht das automatisch zugeordnete Ticket', 1,
    'SELECT 1 FROM ticket WHERE subject = ''Intake 6.1''');
  PERFORM test.count_is('6.22 ... aber nicht das Ticket mit bloßem Vorschlag (kein Leck über Vorschläge)', 0,
    'SELECT 1 FROM ticket WHERE subject = ''Intake 6.4 unverifiziert''');
  PERFORM test.count_is('6.23 ... und nicht das Ticket des anderen Kontos (CRM-Zuordnung Beta)', 0,
    'SELECT 1 FROM ticket WHERE subject = ''Intake 6.14 CRM''');
  PERFORM test.count_is('6.24 Externer sieht weder Vorschläge noch Kontaktdaten', 0,
    'SELECT 1 FROM ticket_account_suggestion UNION ALL SELECT 1 FROM account_contact UNION ALL SELECT 1 FROM account_domain');
  PERFORM test.throws('6.25 Externer Nutzer kann den Ticket-Eingang nicht aufrufen',
    test.intake_sql('int_a_mail', 'm-025', 'Intake 6.25', 'anna@alpha.test', NULL, true, NULL), '42501');

  -- Mandantengrenzen
  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.throws('6.26 Anbieter kann keinen Eingang in der Integration seines Kunden auslösen',
    test.intake_sql('int_a_mail', 'm-026', 'Intake 6.26', 'anna@alpha.test', NULL, true, NULL), '42501');
  PERFORM test.count_is('6.27 Anbieter sieht keine Kontakte, Domains oder Vorschläge des Kunden', 0,
    'SELECT 1 FROM account_contact UNION ALL SELECT 1 FROM account_domain UNION ALL SELECT 1 FROM ticket_account_suggestion');

  PERFORM test.as_user('u_c_int', 'tenant_c', 'internal');
  PERFORM test.intake_is('6.28 Kontakte anderer Mandanten werden nie zum Abgleich genutzt',
    'unassigned', NULL, 'int_c_form', 'w-028', 'Intake 6.28 Fremdmandant', 'anna@alpha.test', NULL, true, NULL);

  -- Bestätigen, Lernen, Ablehnen
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  SELECT t.id INTO v_t          FROM ticket t WHERE t.subject = 'Intake 6.6 nur Domain';
  SELECT t.id INTO v_unassigned FROM ticket t WHERE t.subject = 'Intake 6.17 unbekannt';
  SELECT t.id INTO v_amb        FROM ticket t WHERE t.subject = 'Intake 6.9 mehrdeutig';

  PERFORM test.throws('6.29 Konto eines anderen Mandanten kann nicht bestätigt werden',
    format('SELECT ticket_confirm_account(%L, %L)', v_unassigned, test.id('acct_c1')), '42501');

  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.throws('6.30 Externer Nutzer kann kein Konto zuordnen',
    format('SELECT ticket_confirm_account(%L, %L)', v_t, test.id('acct_a1')), '42501');

  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.runs('6.31 Interner Nutzer bestätigt den Vorschlag und lässt den Kontakt lernen',
    format('SELECT ticket_confirm_account(%L, %L, true)', v_t, test.id('acct_a1')));
  PERFORM test.count_is('6.32 Ticket ist dem Konto zugeordnet (Methode manual)', 1,
    format('SELECT 1 FROM ticket WHERE id = %L AND account_id = %L AND account_method = ''manual''', v_t, test.id('acct_a1')));
  PERFORM test.count_is('6.33 Der Vorschlag ist als akzeptiert markiert', 1,
    format('SELECT 1 FROM ticket_account_suggestion WHERE ticket_id = %L AND status = ''accepted''', v_t));
  PERFORM test.count_is('6.34 Die Absenderadresse wurde als gelernter Kontakt gespeichert', 1,
    format('SELECT 1 FROM account_contact WHERE value = ''newperson@alpha.test'' AND source = ''learned'' AND account_id = %L',
           test.id('acct_a1')));
  PERFORM test.intake_is('6.35 Beim nächsten Eingang wird der gelernte Kontakt automatisch zugeordnet',
    'confirmed', 'acct_a1', 'int_a_mail', 'm-035', 'Intake 6.35 gelernt', 'newperson@alpha.test', NULL, true, NULL);

  PERFORM test.runs('6.36 Bei mehrdeutigem Ticket wählt der Nutzer Konto Beta',
    format('SELECT ticket_confirm_account(%L, %L)', v_amb, test.id('acct_a2')));
  PERFORM test.count_is('6.37 Der nicht gewählte Vorschlag (Alpha) wird abgelehnt', 1,
    format('SELECT 1 FROM ticket_account_suggestion WHERE ticket_id = %L AND account_id = %L AND status = ''rejected''',
           v_amb, test.id('acct_a1')));

  -- Nach Bestätigung ist das Ticket für das richtige Konto sichtbar
  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.count_is('6.38 Konto Alpha sieht das bestätigte Ticket', 1, 'SELECT 1 FROM ticket WHERE subject = ''Intake 6.6 nur Domain''');
  PERFORM test.count_is('6.39 Konto Alpha sieht das Beta zugeordnete Ticket nicht', 0, 'SELECT 1 FROM ticket WHERE subject = ''Intake 6.9 mehrdeutig''');
  PERFORM test.as_user('u_a_ext2', 'tenant_a', 'external');
  PERFORM test.count_is('6.40 Konto Beta sieht das ihm zugeordnete Ticket', 1, 'SELECT 1 FROM ticket WHERE subject = ''Intake 6.9 mehrdeutig''');
  PERFORM test.count_is('6.41 Konto Beta sieht das Alpha-Ticket nicht', 0, 'SELECT 1 FROM ticket WHERE subject = ''Intake 6.6 nur Domain''');

  -- Policy: Schwelle ist einstellbar, aber nach unten begrenzt
  PERFORM test.as_super();
  INSERT INTO policy (tenant_id, key, value)
  VALUES (test.id('tenant_a'), 'account_matching', '{"auto_confirm_min": 0.3}'::jsonb)
  ON CONFLICT (tenant_id, key) DO UPDATE SET value = EXCLUDED.value;
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.intake_is('6.42 Policy-Schwelle 0.3 wird auf 0.8 angehoben: Domain-Treffer bleibt manuell',
    'suggested', NULL, 'int_a_mail', 'm-042', 'Intake 6.42 Policy niedrig', 'another@alpha.test', NULL, true, NULL);

  PERFORM test.as_super();
  UPDATE policy SET value = '{"auto_confirm_min": 0.95}'::jsonb
   WHERE tenant_id = test.id('tenant_a') AND key = 'account_matching';
  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.intake_is('6.43 Strenge Policy (0.95) blockiert auch den CRM-Treffer (0.92)',
    'suggested', NULL, 'int_a_mail', 'm-043', 'Intake 6.43 Policy hoch', 'unknown2@neu.test', NULL, true, 'SF-002');

  PERFORM test.as_super();
  DELETE FROM policy WHERE tenant_id = test.id('tenant_a') AND key = 'account_matching';
END $$;

-- =====================================================================
-- Abschnitt 7: Freigabe widerrufen – Daten bleiben beim Eigentümer
-- =====================================================================
DO $$
BEGIN
  RAISE NOTICE '--- 7. Widerruf der Freigabe ---';

  PERFORM test.as_super();
  UPDATE app_grant SET status = 'revoked' WHERE id = test.id('grant_ba');

  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.count_is('7.1 A behält Lesezugriff auf seine Tickets (Datenhoheit, Export)', 1,
                        'SELECT 1 FROM ticket WHERE subject = ''A Ticket''');
  PERFORM test.throws('7.2 A kann nach Widerruf keine neuen Tickets mehr anlegen',
    format('INSERT INTO ticket (instance_id, integration_id, source, subject) VALUES (%L, %L, ''email'', ''nach Widerruf'')',
           test.id('inst_ab'), test.id('int_a_mail')), '42501');
  PERFORM test.affects('7.3 A kann bestehende Tickets nach Widerruf nicht mehr ändern', 0,
                       'UPDATE ticket SET subject = ''geändert'' WHERE subject = ''A Ticket''');
  PERFORM test.throws('7.4 Wissenssuche über die widerrufene Instanz ist gesperrt', test.search_sql('inst_ab', 1), '42501');

  PERFORM test.as_user('u_b_int', 'tenant_b', 'internal');
  PERFORM test.count_is('7.5 B behält seine eigenen Tickets aus der eigenen Integration', 1,
                        'SELECT 1 FROM ticket WHERE subject = ''B-hosted ticket''');
  PERFORM test.throws('7.6 B kann in der widerrufenen Instanz keine Integration mehr anlegen',
    format('INSERT INTO integration (owner_tenant_id, instance_id, kind, name) VALUES (%L, %L, ''mail'', ''neu@b.test'')',
           test.id('tenant_b'), test.id('inst_ab')), '42501');

  PERFORM test.as_user('u_a_ext', 'tenant_a', 'external');
  PERFORM test.throws('7.7 Kundenportal: nach Widerruf kann kein Ticket mehr angelegt werden',
    format('SELECT portal_create_ticket(%L, %L)', test.id('int_a_form'), 'nach Widerruf'), '42501');
  PERFORM test.count_is('7.8 Externer behält Lesezugriff auf die Tickets seines Kontos', 2,
                        'SELECT 1 FROM ticket WHERE subject IN (''A Ticket'', ''Mein Problem'')');

  PERFORM test.as_user('u_a_int', 'tenant_a', 'internal');
  PERFORM test.throws('7.9 Ticket-Eingang ist nach Widerruf gesperrt',
    test.intake_sql('int_a_mail', 'm-099', 'nach Widerruf', 'anna@alpha.test', NULL, true, NULL), '42501');
END $$;

-- =====================================================================
-- Ergebnis
-- =====================================================================
SELECT test.as_super();

DO $$
DECLARE total int; failed int; r record;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE NOT ok) INTO total, failed FROM test.result;
  RAISE NOTICE '================ % Tests, % fehlgeschlagen ================', total, failed;
  FOR r IN SELECT name, detail FROM test.result WHERE NOT ok LOOP
    RAISE NOTICE 'FEHLGESCHLAGEN: % (%)', r.name, r.detail;
  END LOOP;
  IF failed > 0 THEN
    RAISE EXCEPTION '% von % Tests fehlgeschlagen', failed, total;
  END IF;
END $$;

ROLLBACK;
