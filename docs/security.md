# Bezpečnost

## Co chráníme

- Osobní údaje členů SJV: jméno, e-mail, přiřazení k bytu, historie spotřeby.
- Integrita odečtů a auditní stopy.
- AES klíče měřidel.
- Přístupové údaje zařízení.
- Zálohy a obnovovací údaje.

## Hrozby a opatření

| Hrozba | Hlavní opatření |
| --- | --- |
| Útok na web a přihlášení | Traefik, CrowdSec, rate limit, argon2id, povinné MFA administrátora, blokace účtu |
| Člen vidí cizí data | Kontrola na backendu podle členství a instalace, testy přístupu u každého endpointu |
| Kompromitované zařízení | Účet a ACL pro každé zařízení, okamžité odvolání, klíče AES jen na serveru, kontroly věrohodnosti |
| Cizí nebo sdílený účet koncentrátoru | Každý koncentrátor má vlastní `devices.id`. Účet platformy není identita koncentrátorů, které API vypisuje |
| Podvržené odečty | Šifrovaná měřidla, monotónnost, maximální průtok, korelace více přijímačů, detekce replay |
| Replay zpráv a telegramů | prokázaný `(ingest_source_id, msg_key_namespace, msg_key, item_index)`, hash sám neslučuje, deduplikace jen v důvěryhodném okně, `suspect_replay`, `probable_duplicate`, `needs_review`, `uncertain`, limit stáří, TLS a autentizace. Fragment bez prokázaného `message_ref` má vlastní sadu `isolated`. Shoda `group_key`, `source_message_ref`, `fragment_index`, `content_hash`, času ani identifikátoru jednoho transportního přenosu doručení nespojí. `repeat` a `conflict` jen u `collecting` s prokázaným `message_ref`. Sada `isolated` se neskládá a dekodér ji nedostane. Sada `isolated` je konečný stav a nikdy nepřejde do `collecting`, `complete`, `conflict` ani `timed_out`. `INGEST_FRAGMENT_TIMEOUT` se vztahuje pouze na skládané sady s prokázaným `message_ref` a na `isolated` se nevztahuje. Rozsah `message_ref` musí být prokázán a zapsán v modelu před skládáním a příslušným unikátním omezením ([data-ingestion.md](data-ingestion.md#replay)) |
| Zaplnění disku velkým payloadem | `max_payload_bytes` na koncovém bodu, odmítnutí bez uložení těla |
| Příjem dat použitý ke změně konfigurace zařízení | Oddělené účty a topic. Adaptér příjmu konfiguraci nezapisuje |
| Chybné nebo podvržené časy zařízení | Čas zachycení počítá server z epochy bootu, hodiny zařízení jsou jen záložní zdroj, limity pro budoucnost a stáří |
| Zdvojená spotřeba při změně zdroje | Jediný přiřazený stream, kontrolovaný a auditovaný přechod |
| Únik databáze | DB jen na interní síti, AES a TOTP šifrované hlavním klíčem mimo DB |
| Kompromitace VPS | Vzdálená restic kopie je na append-only `rest-server`. Mazání a prune dělá jen domácí server. Obnovovací sada je mimo VPS. Další záložní kopie domácího serveru není součástí tohoto projektu |
| Neoprávněná změna dat | Oprava odečtu vloží nový řádek se `source_kind = correction`, s povinným důvodem a auditem (R8). Hodnota, čas a měřidlo původního řádku se nemění. Při opravě se na něm smí změnit jen `receipt_count`, `capture_device_ids` a `superseded_at`. `superseded_at` označí původní odečet jako nahrazený. Jiné sloupce původního odečtu se nemění. Opravy `meter_replacement_events` a `meter_verifications` jsou auditovaný `UPDATE` s povinným důvodem a hodnotami `before` a `after`. `UPDATE` a odpovídající `INSERT` do `audit_logs` jsou jedna transakce. `created_by` a `created_at` výměn a metrologických záznamů se nemění. `DELETE` výměn a metrologických záznamů není. Žádná aplikační role nemá v `audit_logs` `UPDATE` ani `DELETE`. Výslovný INSERT do auditu mají v tabulce rolí `sjv_api` a `sjv_maintenance`. Oprava odečtu tím nepovoluje změnu jiných sloupců původního řádku |
| Člen změní instalaci, výměnu nebo metrologickou historii | Tyto zápisy mají jen oprávnění administrátora. Role `member` k nim endpoint nemá |

## Uživatelé

- **Hesla:** argon2id (`argon2-cffi`), minimálně 12 znaků, kontrola proti seznamu běžných hesel. Hesla se nikdy nelogují.
- **MFA:** TOTP povinné pro `admin`, pro `member` volitelné. Jednorázové obnovovací kódy (ukládají se jako hash). Tajemství TOTP je šifrované hlavním klíčem. WebAuthn je možné rozšíření.
- **Sezení:**
  - náhodný identifikátor v cookie `HttpOnly; Secure; SameSite=Strict; Path=/`, v DB jen jako hash,
  - neaktivita 30 minut pro admin, 8 hodin pro member, absolutní limit,
  - rozsah rušení sezení po změně hesla nebo MFA je otevřená otázka a vyžaduje samostatné rozhodnutí. [architecture.md](architecture.md) u `POST /auth/password/change` uvádí zrušení ostatních sezení a u správy MFA rozsah neuvádí. Ani jedna varianta není schválené pravidlo a do rozhodnutí se za něj nepovažuje.
- **CSRF:** double-submit token pro všechny měnící požadavky. API přijímá jen `application/json`.
- **Omezení pokusů:**
  - po 5 neúspěších na účet exponenciální zpoždění a po 10 dočasná blokace (hodnoty k potvrzení),
  - limit podle IP v aplikaci, `rateLimit` v Traefiku a scénáře CrowdSec pro brute-force na `/api/v1/auth/*`,
  - odpověď neprozrazuje, zda účet existuje.
- **Založení účtu:** pozvánka s jednorázovým tokenem (hash, expirace 72 h). Bez SMTP ukáže administrátor odkaz jednorázově v UI.
- **První administrátor:** `scripts/create-admin.sh` v kontejneru. Heslo se zadává interaktivně a nevypisuje se. MFA se nastaví při prvním přihlášení.
- **Ukončení a výmaz účtu:** uživatel se nemaže, protože na něj odkazují členství a audit. Nejdřív se vypne (`disabled`). Na žádost o výmaz se anonymizuje (`anonymized`): e-mail a jméno se nahradí, smaže se heslo, MFA a sezení. Historie členství zůstane bez osobních údajů. Audit si ponechá jen id a anonymizace se do něj zapíše.

## Role a oprávnění

| Role | Stav | Oprávnění |
| --- | --- | --- |
| `admin` | aktivní | správa uživatelů, budov, bytů, členství, měřidel, instalací, výměn, metrologické historie, zařízení, opravy, audit, exporty všech dat |
| `member` | aktivní | jen vlastní byty, jen za období členství, vlastní exporty. Instalace, výměny a metrologickou historii nemění |
| `board` | v datech, nepřiřaditelná | připraveno: čtení všech dat bez úprav |
| `technician` | v datech, nepřiřaditelná | připraveno: měřidla a zařízení bez osobních údajů. R31 tuto roli nezpřístupňuje |

- **Databázové role** nejsou autorizace uživatelů `admin` a `member`. Ostatní oprávnění jsou v [database-design.md](database-design.md#databázové-role). `sjv_api` má `INSERT` a auditovaný `UPDATE` u `meter_installations`, `meter_replacement_events` a `meter_verifications` a u těchto tří tabulek nemá `DELETE`. Do auditu a notifikací má `INSERT`. `secret_enc` nečte. Tam, kde tabulka rolí uvádí jen obecný zápis, se z toho neodvozuje zároveň `INSERT` i `UPDATE`. `sjv_collector` zapisuje do ingest tabulek uvedených v té tabulce, včetně payloadů, fragmentů, kandidátů deduplikace a odmítnutí, a dále do `ingest_sources` pro nově ověřené zařízení, `device_boots`, `unknown_meter_sightings`, `device_events` a do pozorovaných schopností a firmwaru z heartbeatu. Aktualizuje `devices.last_seen_at`. Zařízení nezakládá a `secret_enc` nečte. Migrace `0001_ingest_schema` tato práva zakládá jako konkrétní `SELECT`, `INSERT` a sloupcové `UPDATE`, ne jako `ALL PRIVILEGES`. `decode_queue` dostává `INSERT` role `sjv_collector` a `sjv_api`. Řádek vkládá přijímající proces ve stejné transakci jako nový telegram a jen při výsledku `pending`. `sjv_worker` frontu nevkládá. Má na ni `SELECT`, sloupcový `UPDATE` u `attempts`, `next_attempt_at`, `locked_by`, `locked_at` a `last_error` a `DELETE`. To stačí na `FOR UPDATE SKIP LOCKED`, zápis zámku a počtu pokusů a na smazání úlohy po vyčerpání pokusů. Collector dál nemá dekódování ani zápis odečtů. `INSERT` do `meter_readings` a zvýšení `receipt_count` u existujícího odečtu nebo telegramu migrace collectorovi nedává, protože tabulka rolí `INSERT` odečtu svěřuje workerovi a sloupcový `UPDATE` collectorovi neříká. `sjv_worker` frontu dekódování čte, zamyká a po vyčerpání pokusů maže, zpracovává timeout fragmentů, provádí `INSERT` do `meter_readings`, pracuje s `notifications` a provádí agregace. Klíč AES dešifruje jen v paměti. `secret_enc` nečte: sloupec patří DTLS PSK a listener, který by ho použil, není této roli přiřazený. Zápis `meter_readings` tabulka rolí workerovi dává, tato migrace ho ještě neuděluje. `UPDATE` ani `DELETE` odečtů tabulka rolí nestanovuje. `sjv_maintenance` spravuje partitions, provádí retenci a přepočty a má `INSERT` do auditu. `UPDATE` ani `DELETE` auditních záznamů nemá. Výslovný INSERT do auditu mají v tabulce rolí `sjv_api` a `sjv_maintenance`. Žádná aplikační role nemá v `audit_logs` `UPDATE` ani `DELETE`.
- Autorizace jde přes oprávnění (`permissions`), ne přes jména rolí v kódu. Nová role je jen nová sada oprávnění.
- Každý endpoint deklaruje potřebné oprávnění. Testy ověří, že neexistuje endpoint bez deklarace.
- **Data členů** filtruje repozitářová vrstva, ne UI: měřidlo instalované v bytě v čase odečtu a čas uvnitř členství. Id bytu nebo měřidla z URL se vždy ověří proti těmto pravidlům. Neexistující a cizí objekt vrací stejnou odpověď `404`. Celé pravidlo je v [database-design.md](database-design.md#historie-bytu-přístup-oddělený-od-spotřeby).
- **Přístup je oddělený od spotřeby.** Data spotřeby patří bytu a měřidlu, členství jen určuje viditelné období. Změna vlastníka nemění data spotřeby, takže nový vlastník nevidí historii předchozího a předchozí vlastník po skončení členství nevidí nová data.
- **Aktuální stav měřidla (R15, schváleno):** člen vidí aktuální kumulativní stav počítadla, stejný jako na fyzickém displeji. Rozhraní ho označuje jako celkový stav měřidla, ne jako osobní spotřebu, protože zahrnuje i spotřebu před členstvím. Historické odečty a vypočítanou spotřebu vidí jen za období svého členství. Administrátor má kompletní historii ([decisions.md](decisions.md)).
- **Historie pro administrátora:** `GET /admin/apartments/{id}/history` vrací instalace a výměny měřidel, členství a přiřazení zdrojů v čase. Metrologická historie je na měřidle, ne na bytové ose. Přístup do ní se audituje.
- **Výměny a ověření** zapisuje jen `admin`. `member` tyto endpointy nemá a R15 tím nemění, co smí vidět.
- Testy přístupu: pro každý endpoint člena se ověří cizí byt, období před členstvím a po jeho skončení, dvě oddělená období jednoho člena a měřidlo po výměně.

## Zařízení

- **Založení:** administrátor zařízení založí v UI. Backend vygeneruje údaje a založí účet v Mosquitto Dynamic Security (jméno = client ID = kód zařízení) nebo API token pro HTTPS. Údaje se zobrazí jednou a v DB zůstane jen hash.
- **ACL:** zařízení smí jen do vlastních topiců (viz [data-ingestion.md](data-ingestion.md)). Výchozí politika je zakázat.
- **Odvolání:** `POST /admin/devices/{id}/revoke`
  1. vypne klienta v dynsec, broker ho odpojí,
  2. nastaví `revoked_at` na údajích a stav `revoked`,
  3. zapíše audit.

  Zprávy, které po odvolání ještě dorazí přes HTTPS, se odmítnou.
- **Rotace:** nové údaje se založí dřív, než se staré zruší. Obě sady platí po krátkou přechodnou dobu.
- **TLS:** MQTT jen na 8883 s TLS ≥ 1.2. Listener 1883 je jen v interní síti. U vlastního ESP je autentizace jméno a heslo. Další metody řeší část [Koncentrátory a příjem](#koncentrátory-a-příjem).
- **Kompromitace zařízení** (postup v provozní dokumentaci):
  1. odvolat,
  2. zkontrolovat odečty, které zařízení samo doručilo v podezřelém období,
  3. zařízení nastavit znovu s novými údaji, nebo ho vyřadit.

  Klíče AES zařízení nemá, takže je neprozradí.
- **Věrohodnost odečtů:** pokles kumulativní hodnoty, překročení maximálního průtoku, odečet potvrzený jen jedním zařízením, ačkoli jiná zařízení stejné měřidlo pravidelně přijímají. Všechno se označí pro administrátora. Odečet s `quality = suspect` se do spotřeby automaticky nepočítá. R8 povoluje `UPDATE` původního odečtu jen u `receipt_count`, `capture_device_ids` a `superseded_at`. `UPDATE` `accepted_at` a `accepted_by` je zakázaný. Tyto sloupce v definici tabulky existují jako nullable. Databázový návrh jejich vyplnění při `INSERT` výslovně nezakazuje a tato cesta není rozhodnutá. Jak se pozdější přijetí odečtu `suspect` zachytí, aniž by se rozsah R8 rozšířil, je otevřená otázka v [database-design.md](database-design.md#odečty). Tento dokument ji nerozhoduje a nový sloupec, tabulku ani stav nezavádí.
- **Čas a replay:** zařízení nemůže posunout čas odečtu libovolně. Čas zachycení počítá server z vlastních časů příjmu heartbeatů. Hodiny zařízení se ignorují, když jsou v budoucnosti, a rozpor se hlásí. Opakovaný obsah mimo okno deduplikace se neuloží jako odečet (`suspect_replay`). Opakovaný obsah, `group_key` ani čas samy o sobě fragment bez prokázaného `message_ref` nespojí. Takové doručení zůstane ve vlastní sadě `isolated` a dekodér ho nedostane. Sada `isolated` je konečný stav a nikdy nepřejde do `collecting`, `complete`, `conflict` ani `timed_out`. `INGEST_FRAGMENT_TIMEOUT` se vztahuje pouze na skládané sady s prokázaným `message_ref` a na `isolated` se nevztahuje. Kompromitované zařízení s platnými údaji může poslat smyšlený rámec nešifrovaného měřidla. Proti tomu pomáhá jen šifrování měřidel a korelace s jinými přijímači.
- **Doručení po `timed_out` (R32):** Když nové doručení nese prokázaný `message_ref` a odpovídající původní sada je `timed_out`, původní sada zůstane beze změny. Doručení se k ní nepřipojí. Nevznikne `isolated`, protože `message_ref` je prokázaný, a nevznikne nová `collecting` se stejným `message_ref`. Původní payload doručení zůstane. Doručení se neskládá ani nedekóduje a eviduje se jako nepřiřazené, které vyžaduje samostatné vyhodnocení. Pravidlo platí jen pro `timed_out`, dokud samostatný PoC neprokáže bezpečné zacházení a nebude přijato nové rozhodnutí. Schválený databázový návrh nemá jednoznačný mechanismus evidence nepřiřazeného doručení po `timed_out` s vazbou na `payload_id` ([database-design.md](database-design.md) u `ingest_fragment_sets`). Tento bod zůstává otevřeným implementačním předpokladem a před implementací vyžaduje samostatné rozhodnutí. Nová tabulka, sloupec, stav, constraint, index ani jiný mechanismus evidence se kvůli tomu nezavádí. U `complete` a `conflict` se fragment k ukončené sadě nepřipojí. Další zacházení je otevřená otázka, R32 se na tyto stavy nevztahuje a automaticky nevznikne `isolated` ani `collecting`. Doručení bez prokázaného `message_ref` dál vytvoří vlastní `isolated`.
- **Přechod zdroje odečtů** smí provést jen `admin`, s povinným důvodem a auditem hraničních hodnot. Neúspěšné kontroly vyžadují výslovné potvrzení.

## Koncentrátory a příjem

Platí pro ACRIOS a pro každý další koncentrátor. Metoda autentizace se vybere podle modelu, který ověří PoC. Do té doby jsou připravené možnosti a žádná není prohlášená za jedinou. Vlastní ESP dál používá jméno a heslo MQTT. To není volba pro ACRIOS.

- **Vlastní identita.** Každý koncentrátor je řádek `devices` s vlastními údaji. Idempotence příjmu začíná řádkem `ingest_sources`: fyzické zařízení má `kind = device`, platforma a import mají vlastní řádek s `device_id` NULL. Prokázaný identifikátor zprávy se navíc dělí podle `msg_key_namespace`. Výchozí rozsah je transport, takže MQTT a HTTPS se podle textu `msg_key` nesloučí. Sdílený účet platformy je `endpoint_credentials` a není `device_id` koncentrátorů, které platforma vypisuje. Koncentrátor se k řádku přiřadí jen přes známé `device_external_ids`. IMSI a IMEI nejsou primární klíč. Výměna SIM historii zařízení nepřetrhne.
- **TLS.** MQTT a HTTPS jen TLS 1.2 nebo novější. UDP jen se šifrováním (DTLS), a jen když PoC ukáže, že ho vybraný model má. Otevřený UDP se nezapíná. Port pro UDP se nezakládá v této dokumentační změně.
- **Klientské certifikáty a další metody.** Připravené druhy jsou heslo MQTT, token HTTPS, klientský certifikát a PSK pro DTLS (`device_credentials`) a údaj koncového bodu (`endpoint_credentials`). Zapne se ta, kterou daný kus hardwaru umí. Různá zařízení mohou používat různé metody současně.
- **MQTT ACL.** Účet smí publikovat jen do svých datových topiců a odebírat jen to, co potřebuje. Výchozí politika je zakázat. Topics ACRIOS se doplní po PoC. Do té doby se jeho účet nezakládá a nepoužije topics vlastního ESP.
- **Velikost.** Každý `ingest_endpoints` má `max_payload_bytes` a limit počtu položek. Překročení je `ingest_rejections.reason = payload_too_large` a tělo se neukládá.
- **Replay.** Stejná aplikační pravidla jako u ostatních zdrojů: `PRIMARY KEY (ingest_source_id, msg_key_namespace, msg_key, item_index)` jen pro prokázaný identifikátor. Hash těla ani stejný text `msg_key` na jiném transportu zprávu nesloučí. Potvrzená deduplikace rámce jen uvnitř `dedup_window`, mimo okno `suspect_replay`, bez důvěryhodné kotvy `probable_duplicate` nebo `needs_review`. Ani jeden z nich nezaloží odečet. Platí `INGEST_MAX_MESSAGE_AGE`. Antireplay na úrovni DTLS, pokud ho model má, kontrolu klíče zprávy nenahrazuje. Fragment bez prokázaného `message_ref` se k jinému doručení nepřipojí. Každé takové doručení vytvoří vlastní sadu `isolated`. Shoda `group_key`, `source_message_ref`, `fragment_index`, `content_hash`, času ani identifikátoru jednoho transportního přenosu doručení nespojí. `repeat` a `conflict` platí jen u sady `collecting` s prokázaným `message_ref`. Sada `isolated` se neskládá a dekodér ji nedostane. Sada `isolated` je konečný stav a nikdy nepřejde do `collecting`, `complete`, `conflict` ani `timed_out`. `INGEST_FRAGMENT_TIMEOUT` se vztahuje pouze na skládané sady s prokázaným `message_ref` a na `isolated` se nevztahuje. Rozsah `message_ref` musí být prokázán a reprezentován přímo v databázovém modelu před implementací skládání a příslušného unikátního omezení. Do té doby `message_ref` sadu nespojí. Konkrétní sloupec se kvůli tomu teď nepřidává. Když nové doručení nese prokázaný `message_ref` a odpovídající původní sada je `timed_out` (R32), původní sada zůstane beze změny, doručení se k ní nepřipojí, nevznikne `isolated` ani nová `collecting` se stejným `message_ref`, původní payload zůstane, doručení se neskládá ani nedekóduje a eviduje se jako nepřiřazené, které vyžaduje samostatné vyhodnocení. R32 platí jen pro `timed_out`. Schválený databázový návrh nemá jednoznačný mechanismus evidence nepřiřazeného doručení po `timed_out` s vazbou na `payload_id` ([database-design.md](database-design.md) u `ingest_fragment_sets`). Tento bod zůstává otevřeným implementačním předpokladem a před implementací vyžaduje samostatné rozhodnutí. Nová tabulka, sloupec, stav, constraint, index ani jiný mechanismus evidence se kvůli tomu nezavádí. U `complete` a `conflict` se fragment k ukončené sadě nepřipojí, další zacházení je otevřená otázka, R32 se na ně nevztahuje a automaticky nevznikne `isolated` ani `collecting`.
- **Stáří.** `INGEST_MAX_MESSAGE_AGE` (návrh 30 dní) platí pro všechny transporty. Starší zpráva je `too_old` a odečet z ní nevznikne.
- **Audit odmítnutí.** Obálka, ze které nevznikla položka, je v `ingest_rejections`. Odmítnutá položka je příjem s chybovým stavem. Hesla, tokeny a klíče se do důvodu nezapisují.
- **Příjem a vzdálená konfigurace.** Údaj pro příjem dat neopravňuje měnit whitelist, firmware ani nastavení na platformě. U vlastního ESP zařízení topic `config` jen odebírá a publikuje ho server. Adaptér platformy čte měření. Zápis konfigurace do zařízení je samostatná akce `admin` s auditem a v cestě příjmu není. Když PoC ukáže jeden token, který umí obojí, adaptér stejně použije jen čtení.
- **Ukládání údajů.** Příchozí tajemství je hash nebo otisk certifikátu. `bearer` a `basic` plní `secret_hash`, `client_cert` plní `cert_fingerprint`, obojí se `storage = hash`. Opakovaně použitelný DTLS PSK je šifrovaný AES-256-GCM hlavním klíčem aplikace, ve sloupci `endpoint_credentials.secret_enc` se `storage = kek_enc`. Není v `ingest_endpoints.config`, v payloadu, v logu ani v Gitu. Rozšifruje se jen v paměti procesu, který PSK oprávněně potřebuje. Tento proces migrace neurčuje a `sjv_collector`, `sjv_api` ani `sjv_worker` `SELECT` na `secret_enc` nedostávají. Přístup budoucího UDP/DTLS listeneru zůstává otevřený. `sjv_readonly` nemá tabulkové `SELECT` na `endpoint_credentials` a `secret_enc` nečte. Odchozí token platformy se do `endpoint_credentials` neukládá. Jeho uložení je mimo Etapu 1 a vyžaduje samostatné rozhodnutí. Rotace založí nový řádek dřív, než se starý odvolá.

## AES klíče měřidel

- **Obálkové šifrování:** klíč měřidla se šifruje AES-256-GCM hlavním klíčem aplikace (KEK). KEK je v souboru `/docker-data/infrastructure-sjv/secrets/app-kek` s právy `600`, mimo DB i Git. Kontejner ho dostane jako Docker secret jen do backendu a workeru.
- **Zápis:** `PUT /admin/meters/{id}/key`. Hodnota se už nikdy nezobrazí, UI ukazuje jen otisk. Zápis i změna jdou do auditu bez hodnoty klíče.
- **Použití:** klíč se dešifruje jen ve workeru v okamžiku dekódování. Nikdy se nedostane do argumentu procesu, do logu ani do zařízení.
- **Rotace KEK:** skript přešifruje všechny záznamy v jedné transakci a starý KEK ponechá do ověření zálohy.
- **Záloha KEK:** bez KEK jsou zálohované klíče AES a tajemství TOTP nepoužitelné. KEK je proto v zálohách restic i samostatně v obnovovací sadě.

## Secrets a konfigurace

- Konvence z reference: runtime `.env` je jen v `/docker-data/stacks/infrastructure-sjv/.env` s právy `600`. Šablona `.env.example` nemá skutečné domény ani hesla. Dokumentační jména `example.com` a `mqtt.example.com` i placeholdery `set_*` `check-env.sh` odmítne. `SJV_DOMAIN` a `MQTT_HOSTNAME` jsou uživatelské, takže synchronizace existující jména nepřepíše. Generovaná hesla se nikdy nevypisují.
- `test.sh --static` ověří, že `.env`, klíče, `acme.json`, `htpasswd` ani soubory dynsec nejsou v checkoutu a že je ignoruje `.gitignore`.
- Hesla jdou do psql přes `\getenv` a do Mosquitta přes soubor, nikdy jako argument procesu.

## Síť

- Veřejné služby publikují porty `sjv-traefik` (80, 443) a `sjv-mosquitto` (8883). Samostatný administrační port Traefiku (8443) je publikován pouze na privátní adrese `10.10.10.20` a přístupný přes WireGuard `wg1`.
- PostgreSQL je jen na `sjv-internal` (`internal: true`), bez portu.
- Traefik nemá `docker.sock`.
- PROXY protocol jen od adresy HAProxy jako `/32`. V šabloně je očekávaná adresa `10.10.10.1/32`. Před spolehnutím se na ni se potvrdí skutečným provozem. `insecure` je zakázané a forwarded hlavičky se nedůvěřují. Převzato z reference včetně testů.

- **Administrace Traefiku:**
  - Dashboard je dostupný pouze přes samostatný HTTPS entrypoint `admin` na portu `8443`.
  - Docker publikuje port výhradně na adrese kontejneru Incus `10.10.10.20:8443`, nikoli na všech rozhraních.
  - VPS přijímá administrační provoz přes WireGuard `wg1` ze zdrojové sítě `10.100.101.0/24` a přesměrovává jej na `10.10.10.20:8443`.
  - Firewall VPS nepovoluje přístup k administračnímu portu z veřejného rozhraní.
  - Traefik používá `ipAllowList` s rozsahem `10.100.101.0/24`.
  - Další ochranu tvoří BasicAuth s bcrypt hashovaným heslem v souboru mimo Git (`dashboard.htpasswd`, práva `600`) a middleware CrowdSec.
  - Dashboard používá vlastní router a entrypoint, nikoli veřejný webový router.
  - Přístupová adresa z WireGuardu je `https://10.100.101.1:8443/dashboard/`.


## CrowdSec

- Čte access log Traefiku, kolekce `crowdsecurity/linux` a `crowdsecurity/traefik`. Správa bouncer klíče je převzatá z reference beze změny logiky.
- Na ingest endpointech platí opatrnost kvůli CGNAT (viz [data-ingestion.md](data-ingestion.md)).
- MQTT CrowdSec nechrání. Mosquitto chrání autentizace, ACL a limity spojení. Zda existuje vhodný parser logu Mosquitta, ověřím. Bez něj se nepočítá s blokací na úrovni MQTT.

## Logování a audit

- **Logy aplikace** jsou strukturované (JSON) s `request_id`. Bez hesel, tokenů, klíčů a obsahu telegramů. E-mail jen tam, kde je nutný.
- **Audit** zaznamenává:
  - přihlášení a odhlášení, selhání, změny MFA,
  - všechny administrátorské změny s hodnotou před a po. Oprava odečtu vloží nový řádek se `source_kind = correction`, s povinným důvodem a auditem (R8). Hodnota odečtu, čas a měřidlo původního řádku se nemění. Na původním řádku se při opravě smí změnit pouze `receipt_count`, `capture_device_ids` a `superseded_at`. `superseded_at` označí původní odečet jako nahrazený. Žádné jiné sloupce původního odečtu se při opravě nemění,
  - výměnu měřidla: kdo ji zapsal, kdo ji provedl, kdy proběhla, která instalace a které měřidlo skončilo a které začalo. Počáteční a konečná hodnota a číslo plomby jsou v auditu instalací téže transakce, se stejným `request_id`,
  - metrologickou událost: fyzické měřidlo, typ úkonu (`verification`, `calibration`, `inspection`) a kdo záznam vytvořil. Oprava existujícího záznamu je jen auditovaný `UPDATE` podle R31, ve stejné transakci jako `INSERT` do `audit_logs`. Nese `before`, `after` a povinný důvod a změnu evidovaných údajů, zejména `result`, `performed_at`, poskytovatele a časové pokrytí (`valid_from`, `valid_until`). `created_by` a `created_at` se nemění. `DELETE` není,
  - opravu výměny jen jako auditovaný `UPDATE` podle R31, ve stejné transakci jako `INSERT` do `audit_logs`, s `before`, `after` a povinným důvodem. `created_by` a `created_at` se nemění. `DELETE` není,
  - opravy s důvodem,
  - změny zařízení a klíčů (bez hodnot), exporty,
  - retenční mazání,
  - odmítnuté obálky v `ingest_rejections` a chybové stavy příjmů. Jednotlivé neúspěchy autentizace se do `audit_logs` neřadí po jednom, aby hash řetězec nezahltil proud pokusů. Dohledatelný záznam je řádek odmítnutí.
- **Integrita auditu:** hash řetězec. Výslovný INSERT do `audit_logs` mají v tabulce rolí `sjv_api` a `sjv_maintenance`. Žádná aplikační role nemá `UPDATE` ani `DELETE`. `meter_replacement_events` a `meter_verifications` smějí být aktualizovány jen podle R31. Každý takový `UPDATE` má `before`, `after` a povinný důvod a odpovídající `INSERT` do `audit_logs` v jedné transakci. Oprava odečtu tím nepřechází na přepis hodnoty, času ani měřidla. Na původním řádku se při ní smí změnit pouze `receipt_count`, `capture_device_ids` a `superseded_at` (R8). Ověřuje se při `backup-verify.sh` a `restore-test.sh`.

## Ochrana osobních údajů

Správcem je SJV. Projekt dodává technická opatření, ale ne právní dokumenty.

- **Minimalizace:** ukládá se jen nutné. Rámce cizích měřidel se neukládají (whitelist v zařízení, na serveru jen počet zachycení v `unknown_meter_sightings`). Fotografie měřidel a servisní ani předávací protokoly se neukládají, včetně odkazů a metadat. Uchovává je předseda SJV mimo systém.
- **Retence** podle [decisions.md](decisions.md). Zálohy prodlužují uložení až o 3 roky (roční snapshoty). Musí to být v záznamech o zpracování.
- **Odečty se uchovávají trvale** a patří bytu, ne osobě. Osobní údaj vzniká jen spojením s členstvím. Po anonymizaci uživatele zůstanou odečty bez vazby na osobu.
- **Práva subjektu:** export vlastních dat (CSV a PDF) pro člena, export za člena pro administrátora, anonymizace účtu.
- **Změna vlastníka bytu:** nový člen nevidí historii předchozího, předchozí člen po ukončení členství nevidí nová data.

## Reakce na incident

| Událost | První kroky |
| --- | --- |
| Kompromitace zařízení | odvolat, revize odečtů, nové údaje. Výměna SIM sama o sobě odvolání není: mění se externí identifikátor, `device_id` zůstává |
| Kompromitace účtu admin | zablokovat, zrušit sezení, revize auditu, reset MFA |
| Kompromitace VPS | odpojit, na domácím serveru odebrat klíč restic `vps` a heslo uživatele `infrastructure-sjv` v `rest-server`, úplná obnova podle [backup-strategy.md](backup-strategy.md#úplná-obnova-na-novém-vps) s obnovovací sadou, rotace všech secrets a údajů zařízení |
| Únik databáze | posoudit dopad, rotace KEK a hesel, oznámení podle povinností správce |
