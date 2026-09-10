# Reservedele · Power Ejby

Registrering af reservedele og materialer brugt til reparation af tavler, generatorer,
lystårne, køletrailere og andet udstyr. Én HTML-fil + Supabase, samme stak som diesel-appen.
Selvstændig app — diesel-appen røres ikke.

Lageret er indtil videre **kun Ejby**. Hedehusene tilføjes senere uden ændring af datamodellen:
`afdeling` findes allerede på hver bevægelse og bestilling.

---

## Hvad hver rolle ser

| | Tekniker | Administration |
|---|---|---|
| Registrere forbrug | ✅ | ✅ |
| Søge i lageret | ✅ navn, numre, hylde, antal tilbage | ✅ + leverandør og pris |
| Oprette en vare der ikke findes | ✅ havner i kø | ✅ |
| Priser | ❌ ser dem aldrig | ✅ |
| Bestilling | ❌ | ✅ |
| Modtagelse | ❌ | ✅ |
| Statistik | ❌ | ✅ |
| Kuratere nye varer | ❌ | ✅ |

Administrationen åbnes med knappen øverst til højre. Teknikervisningen er standard —
ingen kode nødvendig for at registrere eller slå lageret op.

---

## Bestilt er ikke det samme som modtaget

Det vigtigste princip i denne version. En vare går gennem tre tilstande:

```
Skal bestilles  →  Bestilt (afventer)  →  Modtaget
   beholdning        beholdning            beholdning
   uændret           UÆNDRET               stiger
```

**Bestilling** opretter en række i `bestillinger`. Den giver ingen varebevægelse —
lageret rører sig ikke, for varen står ikke på hylden endnu. Til gengæld forsvinder
varen fra "skal bestilles", så den ikke bliver bestilt to gange, og den får mærket
*bestilt* på lagerlisten.

**Modtagelse** opretter bevægelsen. Først her stiger beholdningen. Kom der færre end
bestilt, skriver du det faktiske antal: resten bliver stående som åben bestilling.

Er noget købt direkte uden at have været på listen, bruges **Modtaget uden bestilling**
nederst på samme fane.

## Beholdning = summen af bevægelser

Beholdningen er ikke et felt, nogen retter i hånden:

```
beholdning = sum(antal) i bevaegelser
```

Tre slags bevægelser: `forbrug` (negativ), `modtagelse` (positiv) og `optaelling`
(korrektion, begge veje). Derfor kan man altid se hvor tallet kommer fra, og en rettet
fejl retter lageret med.

**Første optælling.** Startkataloget kommer ind med beholdning 0 og en grå prik — det
betyder *aldrig optalt*, ikke *udsolgt*. Regnearkets `aQ`-kolonne er bevidst ikke brugt,
da tallene der ikke er til at stole på. Optælling gøres pr. vare med knappen **Optæl**:
du skriver hvad du faktisk har talt, og forskellen bogføres som korrektion.

**Prisen fryses** på hver bevægelse. En senere prisstigning ændrer derfor ikke, hvad en
reparation kostede sidste år. Modtagelse med pris opdaterer varens pris fremadrettet.

**Indgreb** tælles som antal forskellige datoer pr. udstyr. To dele skiftet samme dag på
samme generator er ét indgreb. Det er tællingen, der viser forskellen mellem "én dyr
reparation" og "billigt, men konstant".

---

## Numre og bestilling

Hver vare har tre numre, fordi de bruges til forskellige ting:

| Felt | Hvad det er | Bruges til |
|---|---|---|
| `elnr` | EL-nummer | bestilling hos el-grossist (Solar, LEMU) |
| `ean` | stregkode | scanning, entydigt opslag |
| `modelnr` | producentens varenummer | bestilling direkte hos producent |

`leverandorer` er en **liste** — regnearket viser at samme vare ofte kan købes flere
steder (`Solar, LEMU, RS PRO`). Bestillingslisten grupperer efter den første i listen;
vil du flytte en vare til en anden leverandør, ændrer du rækkefølgen under Ret.

Søgefeltet rammer alle tre numre, hyldeplads, producent, begge sprog og egne søgeord.
Flere ord søges hver for sig: `ringkabelsko m8` finder *Ringkabelsko Gul M8 L35,5mm*.

---

## Kategorier

Kategoritræet ligger i `index.html` som `GRUPPER` og `UNDER` — to niveauer,
kode + navn på dansk og polsk. Koden gemmes på varen (`kategori`), fx `E3.4`.

Kategorikoderne i regnearket passer 1:1 med træet, så de 257 startvarer er
kategoriseret fra dag ét. Fordelingen: Stik og kabler 96, Styringer 95,
Tavlemateriel 36, Tavle & samledåse 15, EL-mekanik 10, Forskruninger 2, Elektronik 1.
To varer mangler kategori (en har kyrillisk `А` i stedet for `E`) — find dem med
filteret **Uden kategori**.

Skal træet ændres, rettes de to objekter i toppen af scriptet. `E2.8` er med vilje
ikke oprettet — pladsen står tom i den oprindelige liste.

---

## Oversættelse uden oversættelses-API

Ingen maskinoversættelse. Hver vare har `aliaser` — søgeord på hvilket som helst sprog,
der peger på samme vare. Skriver teknikeren et ord der ikke findes, oprettes varen med
hans ord i `type_pl` og status `ukurateret`; den kan bruges med det samme, men mangler
dansk navn og ligger under **Nye varer** til du giver den et. Hans ord kan gemmes som
alias, så han finder varen selv næste gang.

Fordelen frem for maskinoversættelse: der opstår aldrig en dublet, fordi en oversætter
valgte `pakning` hvor værkstedet siger `tætning`. Kataloget lærer værkstedets sprog.

---

## Stregkodescanning

Knappen **Scan** står ved søgefeltet på Registrer, Lager og Modtagelse. Kameraet
læser stregkoden, og varen bliver valgt med det samme — 223 af de 257 startvarer har EAN.

Appen prøver to veje i rækkefølge:

1. **Browserens indbyggede `BarcodeDetector`.** Findes i Chrome på Android og macOS.
   Findes **ikke** på Windows, fordi styresystemet ikke har et stregkode-API — så
   denne vej fejler på en almindelig kontor-pc, uanset browser.
2. **ZXing fra CDN.** Hentes først når man trykker Scan, så siden ikke bliver tungere
   for dem der aldrig scanner. Virker i alle moderne browsere, inkl. Safari på iPhone.

Scanning kræver **HTTPS**: det virker på GitHub Pages og godik.nu, men ikke hvis filen
åbnes direkte fra skrivebordet. Appen siger det ligeud i stedet for at fejle i stilhed.

Bemærk at et webcam på en pc har svært ved små 1D-stregkoder — scanning er tænkt til
telefonen, hvor kameraet kan komme tæt på.

Scanner man en ukendt kode, bliver tallet skrevet i søgefeltet — så kan man oprette
varen med koden i hånden.

## Historik pr. vare

Klik på varens navn i Lager. Så åbnes alle bevægelser: dato, art, antal, hvilket udstyr,
initialer — og en **løbende saldo**, så man kan se præcis hvor det nuværende tal kommer fra.
Teknikeren ser også historikken; der er ingen priser i den.

Uden dette bliver den første uoverensstemmelse mellem systemet og hylden umulig at forklare,
og så mister tallene deres troværdighed.

## Print

To knapper i Lager (kun administration). Begge printer **præcis den liste der står på
skærmen** — filtrene bestemmer, om det er én hylde, én kategori eller hele lageret.

**Hyldeetiketter** — 3 pr. række, sorteret efter hyldeplads. Hver etiket viser plads,
navn, EL-nummer og en rigtig EAN-13-stregkode tegnet som SVG (ingen bibliotek, ren
beregning af de 95 moduler med korrekt tjekciffer). Klistret på hylden erstatter
stregkoden al søgning. De 34 varer uden EAN får kun tekst.

**Optællingsliste** — sorteret efter hyldeplads, med systemets tal og en tom kolonne
til blyant. Print, gå rundt med papir, skriv tal, indtast bagefter under Optæl.
Det er hurtigere end at gå rundt med telefonen, og optællingen af de 257 varer er
den tærskel der afgør om systemet kommer i drift.

## Hvem oprettede varen

Nye varer fra teknikerne får `oprettet_af` med initialer — taget fra Initialer-feltet,
ellers spørger appen. Vises under **Nye varer**, så du ved hvem du skal spørge, hvis
ordet er uforståeligt.

---

## Udstyrsregistret

2.563 rækker, og de kommer to steder fra.

**Anlægsaktiver fra BC** — én række pr. fysisk enhed, navnet er anlægsnummeret:

| Type | Antal | Ressourcenr. |
|---|---|---|
| Tavle (PDU) | 1.943 | 57102–57141, 57211–57216, 57221 |
| Lystårn | 217 | 50119, 50120, 50125, 50127 |
| Køletrailer | 169 | 06500, 06540 (Combi), 06550 (Mini) |
| Generator | 79 | 56060, 56100, 56150, 56151, 56202, 56250, 56302, 56552 |
| Køle-fryse modul | 60 | 06560 |
| Batteri | 22 | 56600, 56601, 56602, 56605 |
| Tilbehør | 5 | 57508 (trådbur, ramme f/eltavle) |
| Omformer | 3 | 57228, 57229 |
| Trailer | 2 | 51060 (gardintrailer) |

**Prislisten** — kabler, powerlock og adaptere. De har **intet anlægsnummer**:

| Type | Antal | Varenr. |
|---|---|---|
| Kabel | 30 | 57000–57094 |
| Powerlock | 16 | 57058–57076 |
| Adapter / fordeler | 16 | 57300–57353 |
| Måler | 1 | 57105 |

Her er navnet varenummeret, og **forbruget opgøres pr. varetype, ikke pr. stk.**
Statistikken kan altså sige "vi bruger 4.200 kr om året på 3x32A-kabler", men ikke
"netop dette kabel er dyrt". Skal det kunne lade sig gøre, må kablerne først mærkes
fysisk med hvert sit nummer.

Felterne:

* **navn** = anlægsnummer (`EL1614`, `BAT16`, `AB2983`) eller varenummer (`57024`).
* **model** = beskrivelsen. For lystårne indeholder den også G-/B-nummeret,
  som teknikerne kender tårnet på — derfor kan der søges på `G23`.
* **ressourcenr** = BC's Ressourcenr. Søg på `57122` og få alle 450 PDU 63A.
* **serienr** = Stelnr. fra BC; for køletrailere bruges registreringsnummeret,
  hvis der ikke er noget stelnr.

**Solgte enheder er udeladt** (`Ja - Solgt` i BC): 6 lystårne, 35 tavler og 13
køletrailere. Enheder spærret med `Ja - Reparation`, `Ja - Savnet`, `Ja - oprydning`
eller `Ja - Andet` er **med** — de første er jo netop under reparation.

Stavemåden er ensrettet pr. ressourcenr. BC skriver samme nummer på flere måder
(`Køle/Frysetrailer`, `køle/frysetrailer`, `Køle/Frysetrailer HF`; `PDU 63A NR 57122`
mod `PDU 63A`), og uden ensretning ville statistikken dele dem op. Varenummeret er
samtidig fjernet fra modelteksten, da det står i ressourcenr.

**Køle-fryse modul (06560, 60 stk.)** er ført som sin egen type, ikke som køletrailer.
Er modulet i praksis en del af en trailer, bør de to slås sammen — ellers fordeler
reparationsudgiften sig på to rækker.

### Sådan opdateres registret

Eksportér Anlægsaktiver fra BC til Excel og send filen. Der er kun brug for tre kolonner:
`Nummer`, `Beskrivelse` og `Ressourcenr.` — resten af BC's 49 kolonner bruges ikke.
Insert i `schema.sql` er idempotent, så en genkørsel tilføjer kun det nye.

---

## Opsætning

**1. Database.** Kør hele `schema.sql` i Supabase → SQL Editor. Opretter fire tabeller,
seks views og indsætter startkataloget. Insert er idempotent — kør den igen uden at få dubletter.

**2. Nøgler.** Øverst i scriptet i `index.html`:

```js
const SUPABASE_URL = "https://xxxx.supabase.co";
const SUPABASE_ANON_KEY = "eyJ...";
const AFDELING = "Ejby";
```

Tomme felter = **DEMO**: kataloget hentes fra `data.js`, alt gemmes i hukommelsen og
nulstilles ved genindlæsning. Adminkode i demo: `godik`.

**3. Adgangskode.** Kode i en HTML-fil er ikke sikkerhed — alle kan læse den. Brug samme
`check-access` Edge Function som diesel-appen; appen kalder
`sb.functions.invoke("check-access", { body: { kode, app: "reservedele" } })`
og forventer `{ ok: true }`.

**4. RLS.** Med anon-nøglen i en offentlig fil **skal** Row Level Security være slået til
på alle fire tabeller. Uden RLS kan enhver med URL'en også slette. Dette er ikke valgfrit.

---

## Deploy

`.github/workflows/deploy.yml` uploader via FTP ved push til `main`. Kræver secrets
`FTP_SERVER`, `FTP_USERNAME`, `FTP_PASSWORD` under Settings → Secrets and variables → Actions.
Uden dem fejler jobbet — slå workflowet fra indtil de er sat.

Til prototype uden FTP: GitHub Pages fra `main` / root. Appen kører i demo,
og der er ingen nøgler i filerne.

---

## Filer

| Fil | Indhold |
|---|---|
| `index.html` | Hele appen: UI, kategoritræ, logik, Supabase-kald |
| `data.js` | Startkatalog (257 varer) og udstyrsregister (2.563 rækker). Kun til demo |
| `schema.sql` | Tabeller, views og seed |
| `.github/workflows/deploy.yml` | FTP-deploy |

---

## Bevidst ikke lavet

Ikke fordi det er svært, men fordi det ville skade mere end det gavner nu:

* **Automatisk prishentning fra Solar.** Kræver API-adgang på Godiks konto. Og priserne
  skal ikke være præcise — de skal bære konklusionen "den generator koster mere at
  vedligeholde end at udskifte", hvor 5 % afvigelse er uden betydning.
* **Email ved lav beholdning.** Alle holder op med at læse dem efter en uge. Tallet på
  Bestilling-fanen gør det samme og kan ikke overses.
* **Hedehusene som andet lager.** Strukturen er klar (`afdeling`), men så længe Ejby ikke
  har en eneste rigtig linje, er udvidelse bare dobbelt så meget usikkerhed.
* **Kobling til Business Central.** Afventer at Rune åbner adgangen.

## Ikke lavet endnu

* Sammenlægning af dubletter i kataloget
* PDF-eksport (kun CSV pt.)
* Forventet leveringsdato på bestillinger (`forventet` findes i tabellen, men bruges ikke)
* QR-koder på etiketterne (EAN-13 dækker de 223 varer der har et nummer)

## Før udrulning

Giv appen til to eller tre teknikere i en uge i demo-tilstand, og se hvor de går i stå.
Én times observation siger mere end enhver funktionsliste — det kan vise sig, at det der
bremser dem, er noget helt andet end det vi har bygget.
