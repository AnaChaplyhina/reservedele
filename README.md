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
| `data.js` | Startkatalog, 257 varer. Kun til demo |
| `schema.sql` | Tabeller, views og seed |
| `.github/workflows/deploy.yml` | FTP-deploy |

---

## Ikke lavet endnu

* Hedehusene som andet lager (`afdeling` findes, men der er ingen vælger i UI'et)
* Stregkodescanning med telefonens kamera (`ean` ligger klar til det)
* Automatisk prishentning fra Solar
* Sammenlægning af dubletter i kataloget
* PDF-eksport (kun CSV pt.)
* Forventet leveringsdato på bestillinger (`forventet` findes i tabellen, men bruges ikke)
