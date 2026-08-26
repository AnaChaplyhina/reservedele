-- ============================================================
--  Reservedele · Power Ejby
--  Kør hele filen i Supabase -> SQL Editor. Én gang.
-- ============================================================

-- ---------- 1. Katalog ----------
create table if not exists materialer (
  id          bigint generated always as identity primary key,
  type_da     text,                       -- kanonisk type. Tom = venter på kuratering
  type_pl     text,                       -- teknikerens eget ord
  model       text,                       -- specifikationen: mål, farve, variant
  producent   text,
  elnr        text,                       -- EL-nummer. Bestilles efter dette
  ean         text,                       -- stregkode
  modelnr     text,                       -- producentens eget varenummer
  leverandorer text[] default '{}',       -- flere mulige: {Solar,LEMU,"RS PRO"}
  kategori    text,                       -- kode fra kategoritræet, fx 'E3.4'
  placering   text,                       -- hyldeplads, fx 'H1.A1'
  enhed       text default 'stk',
  pris        numeric(10,2),
  minimum     numeric(10,2) default 0,    -- 0 = advar kun ved udsolgt
  aliaser     text[] default '{}',         -- søgeord på hvilket som helst sprog
  oprettet_af text,                        -- initialer på den der oprettede varen
  status      text default 'ukurateret' check (status in ('ukurateret','kurateret')),
  created_at  timestamptz default now()
);
create index if not exists mat_elnr_idx on materialer (elnr);
create index if not exists mat_ean_idx  on materialer (ean);
create index if not exists mat_kat_idx  on materialer (kategori);

-- ---------- 2. Udstyr (det der repareres) ----------
create table if not exists udstyr (
  id         bigint generated always as identity primary key,
  navn       text not null,               -- pr. ENHED: "Generator 45", ikke "generatorer"
  type       text,                        -- tavle / generator / lystårn / køletrailer / andet
  serienr    text,
  afdeling   text default 'Ejby',
  aktiv      boolean default true,
  created_at timestamptz default now()
);

-- ---------- 3. Bevægelser ----------
-- Beholdningen er ikke et felt man retter. Den er summen af denne tabel.
-- Tre slags: forbrug (negativ), modtagelse (positiv), optaelling (korrektion, begge veje).
-- BEMÆRK: bestilling giver INGEN bevægelse. Lageret stiger først ved modtagelse.
create table if not exists bevaegelser (
  id           bigint generated always as identity primary key,
  materiale_id bigint not null references materialer(id),
  antal        numeric(10,2) not null,
  art          text not null check (art in ('forbrug','modtagelse','optaelling')),
  udstyr_id    bigint references udstyr(id),
  dato         date not null default current_date,
  initialer    text,
  note         text,
  pris         numeric(10,2),             -- prisen på handlingstidspunktet, fryses
  afdeling     text not null default 'Ejby',
  created_at   timestamptz default now(),
  constraint forbrug_kraever_udstyr check (art <> 'forbrug' or udstyr_id is not null),
  constraint forbrug_er_negativt   check (art <> 'forbrug' or antal < 0),
  constraint modtagelse_er_positiv check (art <> 'modtagelse' or antal > 0)
);
create index if not exists bev_mat_idx  on bevaegelser (materiale_id);
create index if not exists bev_dato_idx on bevaegelser (dato);
create index if not exists bev_afd_idx  on bevaegelser (afdeling);

-- ---------- 4. Bestillinger ----------
-- Adskilt fra bevægelser, netop fordi en bestilling ikke er en varebevægelse.
-- Delleverance: antal skrues ned, status bliver 'bestilt' indtil resten kommer.
create table if not exists bestillinger (
  id            bigint generated always as identity primary key,
  materiale_id  bigint not null references materialer(id),
  antal         numeric(10,2) not null check (antal > 0),
  leverandor    text,
  dato          date not null default current_date,
  forventet     date,
  status        text not null default 'bestilt'
                check (status in ('bestilt','modtaget','annulleret')),
  dato_modtaget date,
  initialer     text,
  afdeling      text not null default 'Ejby',
  created_at    timestamptz default now()
);
create index if not exists ord_status_idx on bestillinger (status);
create index if not exists ord_mat_idx    on bestillinger (materiale_id);

-- ---------- 5. Beholdning ----------
create or replace view v_beholdning as
select m.id as materiale_id, coalesce(b.afdeling,'Ejby') as afdeling,
       coalesce(sum(b.antal), 0)                          as beholdning,
       m.minimum,
       count(b.id) = 0                                    as aldrig_optalt,
       count(b.id) > 0 and coalesce(sum(b.antal),0) <= 0   as udsolgt,
       m.minimum > 0 and coalesce(sum(b.antal),0) <= m.minimum as under_minimum
from materialer m
left join bevaegelser b on b.materiale_id = m.id
group by m.id, coalesce(b.afdeling,'Ejby'), m.minimum;

-- ---------- 6. Hvad skal bestilles (ikke allerede bestilt) ----------
create or replace view v_bestillingsliste as
select m.id, m.type_da, m.model, m.elnr, m.ean, m.modelnr, m.kategori, m.placering, m.enhed,
       m.leverandorer[1] as primaer_leverandor, m.leverandorer,
       v.beholdning, m.minimum,
       greatest(1, m.minimum - v.beholdning) as foreslaaet_antal
from v_beholdning v
join materialer m on m.id = v.materiale_id
where (v.udsolgt or v.under_minimum)
  and not exists (select 1 from bestillinger o
                  where o.materiale_id = m.id and o.status = 'bestilt')
order by m.leverandorer[1] nulls last, (v.beholdning - m.minimum);

-- ---------- 7. Statistik: udstyr ----------
create or replace view v_udstyr_forbrug as
select u.id, u.navn, u.type, u.afdeling,
       coalesce(sum(abs(b.antal) * coalesce(b.pris, m.pris, 0)), 0) as samlet_kr,
       count(distinct b.dato)                                       as indgreb,
       max(b.dato)                                                  as seneste
from udstyr u
left join bevaegelser b on b.udstyr_id = u.id and b.art = 'forbrug'
left join materialer  m on m.id = b.materiale_id
group by u.id
order by samlet_kr desc;

-- ---------- 8. Statistik: varer og kategorier ----------
create or replace view v_vare_forbrug as
select m.id, m.type_da, m.model, m.elnr, m.kategori, m.enhed,
       sum(abs(b.antal))                                           as total_antal,
       coalesce(sum(abs(b.antal) * coalesce(b.pris, m.pris, 0)), 0) as samlet_kr,
       count(distinct b.udstyr_id)                                  as antal_udstyr
from materialer m
join bevaegelser b on b.materiale_id = m.id and b.art = 'forbrug'
group by m.id
order by samlet_kr desc;

create or replace view v_kategori_forbrug as
select split_part(m.kategori, '.', 1)                               as gruppe,
       m.kategori,
       sum(abs(b.antal))                                            as total_antal,
       coalesce(sum(abs(b.antal) * coalesce(b.pris, m.pris, 0)), 0)  as samlet_kr
from materialer m
join bevaegelser b on b.materiale_id = m.id and b.art = 'forbrug'
group by 1, 2
order by samlet_kr desc;

-- ============================================================
--  9. Startkatalog: 257 varer fra 'Reservedele - POWER', ark 'Full Item'.
--     Kategorikoderne i regnearket passer 1:1 med kategoritræet i appen.
--     Priser og minimum står tomme — de sættes ved kuratering og optælling.
--     Beholdningen er bevidst 0: den kommer fra første optælling,
--     ikke fra regnearkets aQ-kolonne.
-- ============================================================
insert into materialer
  (type_da, type_pl, model, producent, elnr, ean, modelnr, leverandorer,
   kategori, placering, enhed, status, minimum)
select v.type_da, v.type_pl, v.model, v.producent, v.elnr, v.ean, v.modelnr, v.leverandorer,
       v.kategori, v.placering, v.enhed, 'kurateret', 0
from (values
  ('Spademuffe', 'Nasuwka płaska', 'Gul 6,3x0,8 Isolerede', 'SOLAR PLUS', '0821101450', '5705151065452', 'SPN 4607 FLF PLD', array['Solar'], 'E3.4', 'H1.A1', 'stk'),
  ('Spademuffe', 'Nasuwka płaska', 'Gul 6,3x0,8 Halvisolerede', 'SOLAR PLUS', '0821101421', '5705151065421', 'SPN 4607 FL PLD', array['Solar'], 'E3.4', 'H1.B1', 'stk'),
  ('Spadestik', 'Wtyk płaski', 'Gul 6,3x0,8 Halvisolerede', 'SOLAR PLUS', '0821101379', '5705151065377', 'SPN 4607 H PLD', array['Solar'], 'E3.4', 'H1.C1', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Gul M6 L30,5mm', 'SOLAR PLUS', '0821101104', '5705151065100', 'SPN 4665 R PL', array['Solar'], 'E3.4', 'H1.D1.1', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Gul M8 L35,5mm', 'SOLAR PLUS', '0821101117', '5705151065117', 'SPN 4685 R PL', array['Solar'], 'E3.4', 'H1.D1.2', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Gul M10 L35,5mm', 'SOLAR PLUS', '0821102776', '5705151100771', 'SPN 4610 R PL', array['Solar'], 'E3.4', 'H1.E1.1', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Gul M12 L40mm', 'ELPRESS', '2921106340', '7393487004115', 'A4613R', array['Solar','LEMU'], 'E3.4', 'H1.E1.2', 'stk'),
  ('Samlemuffe', 'Tulejka łączeniowa', 'Gul 2,5mm-6,5mm', 'SOLAR PLUS', '0821102815', '5705151100818', 'NS 4652 SK', array['Solar'], 'E3.4', 'H1.F1.1', 'stk'),
  ('Samlemuffe', 'Tulejka łączeniowa', 'Gul 2,5mm-6,5mm L27,5mm', 'SOLAR PLUS', '0821101285', '5705151065285', 'SPN 4652 SK PL', array['Solar'], 'E3.4', 'H1.F1.2', 'stk'),
  ('Spademuffe', 'Nasuwka płaska', 'Blå 6,3x0,8 Isolerede', 'SOLAR PLUS', '0821101447', '5705151065445', 'SPN 2507 FLF PLD', array['Solar'], 'E3.4', 'H1.A2', 'stk'),
  ('Afgrening Spademuffe', 'Nasuwka płaska rozgałęźna', 'Blå 6,3x0,8 Halvisolerede', 'SOLAR PLUS', '0821101395', '5705151065391', 'SPN 2507 FLH PLD', array['Solar'], 'E3.4', 'H1.B2.1', 'stk'),
  ('Spademuffe', 'Nasuwka płaska', 'Blå 6,3x0,8 Halvisolerede', 'SOLAR PLUS', '0821101418', '5705151065414', 'SPN 2507 FL PLD', array['Solar'], 'E3.4', 'H1.B2.2', 'stk'),
  ('Spadestik', 'Wtyk płaski', 'Blå 6,3x0,8 Halvisolerede', 'SOLAR PLUS', '0821101366', '5705151065360', 'SPN 2507 H PLD', array['Solar'], 'E3.4', 'H1.C2', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Blå M6 L28mm', 'SOLAR PLUS', '0821101078', '5705151065070', 'SPN 2565 R PL', array['Solar'], 'E3.4', 'H1.D2.1', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Blå M8 L27mm', 'SOLAR PLUS', '0821102763', '5705151100764', 'SPN 2585 R PL', array['Solar'], 'E3.4', 'H1.D2.2', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Blå M10 L30,5mm', 'ELPRESS', '2921106269', '7393487004160', 'A2510R', array['Solar','LEMU'], 'E3.4', 'H1.E2.1', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Blå M12', 'ELPRESS', '2921106272', '7393487013858', 'A2513R', array['Solar','LEMU'], 'E3.4', 'H1.E2.2', 'stk'),
  ('Samlemuffe', 'Tulejka łączeniowa', 'Blå 1mm-2,5mm', 'SOLAR PLUS', '0821102802', '5705151100801', 'NS 2527 SK', array['Solar'], 'E3.4', 'H1.F2.1', 'stk'),
  ('Samlemuffe', 'Tulejka łączeniowa', 'Blå 1,5mm-2,5mm L25,5mm', 'SOLAR PLUS', '0821101272', '5705151065278', 'SPN 2527 SK PL', array['Solar'], 'E3.4', 'H1.F2.2', 'stk'),
  ('Spademuffe', 'Nasuwka płaska', 'Rød 6,3x0,8 Isolerede', 'SOLAR PLUS', '0821101434', '5705151065438', 'SPN 1507 FLF', array['Solar'], 'E3.4', 'H1.A3', 'stk'),
  ('Afgrening Spademuffe', 'Nasuwka płaska rozgałęźna', 'Rød 6,3x0,8 Halvisolerede', 'SOLAR PLUS', '0821101382', '5705151065384', 'SPN 1507 FLH PLD', array['Solar'], 'E3.4', 'H1.B3.1', 'stk'),
  ('Spademuffe', 'Nasuwka płaska', 'Rød 6,3x0,8 Halvisolerede', 'SOLAR PLUS', '0821101405', '5705151065407', 'SPN 1507 FL PLD', array['Solar'], 'E3.4', 'H1.B3.2', 'stk'),
  ('Spadestik', 'Wtyk płaski', 'Rød 6,3x0,8 Halvisolerede', 'SOLAR PLUS', '0821101353', '5705151065353', 'SPN 1507 H PLD', array['Solar'], 'E3.4', 'H1.C3', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Rød M6 L27,5mm', 'SOLAR PLUS', '0821101036', '5705151065032', 'SPN 1565 R PL', array['Solar'], 'E3.4', 'H1.D3.1', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Rød M8 L25,7mm', 'SOLAR PLUS', '0821102750', '5705151100757', 'SPN 1585 R PL', array['Solar'], 'E3.4', 'H1.D3.2', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Rød M4 L20,4mm', 'SOLAR PLUS', '0821101010', '5705151065018', 'SPN 1543 R PL', array['Solar'], 'E3.4', 'H1.D3.2', 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', 'Rød M10 L30,5mm', 'ELPRESS', '2921106175', '7393487004153', 'A1510R', array['Solar','LEMU'], 'E3.4', 'H1.E3.1', 'stk'),
  ('Gaffelkabelsko', 'Końcówka widełkowa', 'Rød M5 L23mm', 'SOLAR PLUS', '0821101146', '5705151065148', 'SPN 1553 G PL', array['Solar'], 'E3.4', 'H1.E3.2', 'stk'),
  ('Samlemuffe', 'Tulejka łączeniowa', 'Rød 0,75mm-1,5mm', 'SOLAR PLUS', '0821102792', '5705151100795', 'NS 1525 SK', array['Solar'], 'E3.4', 'H1.F3.1', 'stk'),
  ('Samlemuffe', 'Tulejka łączeniowa', 'Rød 0,75mm-1,5mm L25,5mm', 'SOLAR PLUS', '0821101269', '5705151065261', 'SPN 1525 SK PL', array['Solar'], 'E3.4', 'H1-F3.2', 'stk'),
  ('Tylle', 'Przepustka', 'Gul 6,0mm L12', 'SOLAR PLUS', '0821101528', '5705151065520', 'SPCED 060012-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Hvid 0,5mm L8', 'SOLAR PLUS', '0821101463', '5705151065469', 'SPCED 005008-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Rød 1mm L8', 'SOLAR PLUS', '0821101489', '5705151065483', 'SPCED 010008-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Rød 10mm L12', 'SOLAR PLUS', '0821101531', '5705151065537', 'SPCED 100012-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Hvid 0,5mm L8', 'SOLAR PLUS', '0821101463', '5705151065469', 'SPCED 005008-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Grå 0,75mm L8', 'SOLAR PLUS', '0821101476', '5705151065476', 'SPCED 007508-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Blå 2,5mm L8', 'SOLAR PLUS', '0821101502', '5705151065506', 'SPCED 025008-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Blå 2,5mm L18', 'ELPRESS', '2921111720', '7393487013148', 'A2,5-18ET', array['Solar','LEMU'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Blå 16mm L12', 'SOLAR PLUS', '0821101544', '5705151065544', 'SPCED 160012-100', array['Solar','LEMU'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Grå 4,0mm L10', 'SOLAR PLUS', '0821101515', '5705151065513', 'SPCED 040010-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Sort 1,5mm L8', 'SOLAR PLUS', '0821101492', '5705151065490', 'SPCED 015008-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', null, null, null, null, null, '{}'::text[], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Gul 6,0mm L18', 'SOLAR PLUS', '5401009101', '7331176167239', 'CED 060018-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Gul 6,0mm L12', 'SOLAR PLUS', '0821101528', '5705151065520', 'SPCED 060012-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Blå 16mm L12', 'SOLAR PLUS', '0821101544', '5705151065544', 'SPCED 160012-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', 'Rød 35mm L25', 'RS PRO', null, null, '311-7870', array['RS PRO'], 'E3.3', null, 'stk'),
  ('Tylle 2x', 'Przepustka podwójna', 'Blå 2,5mm L10', 'SOLAR PLUS', '0821101683', '5705151065681', 'SPCTD 225010-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle 2x', 'Przepustka podwójna', 'Hvid 0,5mm L8', 'SOLAR PLUS', '0821101641', '5705151065643', 'SPCTD 205008-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle 2x', 'Przepustka podwójna', 'Grå 4mm L12', 'NELCO', '0921099844', '7331176156769', 'CTW 240012-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle 2x', 'Przepustka podwójna', 'Grå 4mm L18', 'ELPRESS', '2921105396', '7393487046399', 'A4-18ETW2', array['Solar','LEMU'], 'E3.3', null, 'stk'),
  ('Tylle 2x', 'Przepustka podwójna', 'Sort 1,5mm L8', 'SOLAR PLUS', '0821101670', '5705151065674', 'SPCTD 215008-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle 2x', 'Przepustka podwójna', 'Sort 1,5mm L12', 'ELPRESS', '2921105150', '7393487046030', 'A1,5-12ETT2', array['Solar','LEMU'], 'E3.3', null, 'stk'),
  ('Tylle 2x', 'Przepustka podwójna', 'Sort 6mm L14', 'NELCO', '0921099860', '5705150730269', 'CTW 260014-100', array['Bels'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', '16mm L12 Uisoleret', 'SOLAR PLUS', '0821101829', '5705151065827', 'SPCN 160012-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', '10mm L15 Uisoleret', 'SOLAR PLUS', '0821102035', '5705151100030', 'SPCN 100015-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', '10mm L18 Uisoleret', 'SOLAR PLUS', '0821102048', '5705151100047', 'SPCN 100018-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', '10mm L12 Uisoleret', 'SOLAR PLUS', '0821102048', '5705151100047', 'SPCN 100018-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', '2,5mm L12 Uisoleret', 'SOLAR PLUS', '0821101780', '5705151065780', 'SPCN 025012-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', '0,75mm L6 Uisoleret', 'SOLAR PLUS', '0821101751', '5705151065759', 'SPCN 007506-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', '6mm L12 Uisoleret', 'SOLAR PLUS', '0821101803', '5705151065803', 'SPCN 060012-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', '1,5mm L10 Uisoleret', 'SOLAR PLUS', '0821101777', '5705151065773', 'SPCN 015010-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', '1mm L10 Uisoleret', 'SOLAR PLUS', '0821101764', '5705151065766', 'SPCN 010010-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Tylle', 'Przepustka', '0,5mm L6 Uisoleret', 'SOLAR PLUS', '0821101748', '5705151065742', 'SPCN 005006-100', array['Solar'], 'E3.3', null, 'stk'),
  ('Ringkabelsko', 'Końcówka oczkowa', '1,5-2,5mm M10 Uisoleret', 'ELPRESS', '2921108568', '7393487003774', 'B2510R', array['Solar','LEMU'], 'E3.4', null, 'stk'),
  ('Kontaktben', 'Bolec stykowy', 'M5 6,3x0,8 Uisoleret', 'ELPRESS', null, null, null, '{}'::text[], 'E3.4', null, 'stk'),
  ('Elmåler', 'Licznik energii', '3-faset 65A DIN Montage', 'CARLO GARVAZZI', '9698000235', '8030956070156', 'EM340DINAV23XO1X', array['Solar','LEMU','RS PRO'], 'E1.3', null, 'stk'),
  ('Timer', 'Timer', 'On Delay SPDT 8A 24-240VAC/DC', 'SCHNEIDER ELECTRIC', '7523006571', '3606480552670', 'RE17RAMU', '{}'::text[], 'E2.3', null, 'stk'),
  ('Drejegreb (Separat)', 'Rękojeść obrotowa (osobna)', 'm/ Nøgle 3 faste pos. Ud Alle', 'SCHNEIDER ELECTRIC', '7517904388', '3389110905762', 'ZB5AG0', array['Solar','LEMU'], 'E2.3', null, 'stk'),
  ('Timetæller', 'Licznik godzin', '48x48mm 12-48VDC', 'PALADIN', '5423501152', '4022709000613', '312110', array['Solar'], 'E4.1', null, 'stk'),
  ('Hængsellåg', 'Pokrywa na zawiasach', '248x218x26mm', 'FIBOX', '8212008096', '6418074035899', 'L24II', array['Solar','LEMU'], 'M3', null, 'stk'),
  ('Termorelæ', 'Przekaźnik termiczny', 'Tesys D 2,5-4A', 'SCHNEIDER ELECTRIC', '7522421717', '3389110346787', 'LRD08', array['Solar','LEMU','RS PRO'], 'E2.1', null, 'stk'),
  ('Endestop', 'Ogranicznik końcowy', 'Stempel SPDT 15A', 'OMRON', '5424596768', '4548583364875', 'Z-15GQ-B', array['Solar'], 'E3.2', null, 'm'),
  ('Kontaktor', 'Stycznik', 'Tesys D 4P 25A 230VAC', 'SCHNEIDER ELECTRIC', '7522457820', '3389110244571', 'LC1DT25P7', array['Solar','LEMU'], 'E2.1', null, 'stk'),
  ('Sikring', 'Bezpiecznik', 'Kniv Gg 160A 500V', 'ETI', '0825101456', '3838895354697', '4185216', array['Solar'], 'E1.1', null, 'stk'),
  ('Måletransformer', 'Przekładnik prądowy', '300/5A Klasse 0,5', 'EATON', '3698000286', '5703498700142', 'HF3B-300/5A', array['Solar','LEMU'], 'E1.3', null, 'stk'),
  ('Kombiafbryder (RCBO)', 'Wyłącznik różnicowoprądowy z bezpiecznikiem (RCBO)', '16A 1P+N C 30mA A', 'EATON', '5422564129', '4015082362171', 'PKNM-16/1N/C/003-A-MW', array['Solar','LEMU','RS PRO'], 'E1.2', null, 'stk'),
  ('Kombiafbryder (RCBO)', 'Wyłącznik różnicowoprądowy z bezpiecznikiem (RCBO)', '16A 3P+N C 30mA A', 'EATON', '5422564873', '4015081184903', 'mRB6-16/3N/C/003-A', array['Solar','LEMU'], 'E1.2', null, 'stk'),
  ('Automatsikring (MCB)', 'Wyłącznik nadprądowy (MCB)', '32A 3P+N C 6kA', 'EATON', '5422562930', '4015082430214', 'PLS6-C32/3N-NW', array['Solar','LEMU'], 'E1.1', null, 'stk'),
  ('Kombiafbryder (RCBO)', 'Wyłącznik różnicowoprądowy z bezpiecznikiem (RCBO)', '32A 3P+N C 30mA A', 'EATON', '5422563829', '4015081640096', 'mRB4-32/3N/C/003-A', array['Solar','LEMU'], 'E1.2', null, 'stk'),
  ('Fejlstrømsafbryder (RCD)', 'Wyłącznik różnicowoprądowy (RCD)', '63A 4P 30mA A', 'SCHNEIDER ELECTRIC', '3322069771', '3606480443251', 'A9Z21463', array['Solar','LEMU','RS PRO'], 'E1.2', null, 'stk'),
  ('Måletransformer', 'Przekładnik prądowy', '300/5A Klasse 0,2S', 'EATON', '3698000561', '5703498701446', 'HF4B-300/5A-CLASS-0.2S', array['Solar','LEMU'], 'E1.3', null, 'stk'),
  ('Fejlstrømsmonitor', 'Monitor prądu różnicowego', '0,03-5A A 230VAC', 'SIEMENS', '5401042997', '4001869397610', '5SV8000-6KK', array['Solar','LEMU','RS PRO'], 'E1.3', null, 'stk'),
  ('Underspændingsrelæ', 'Przekaźnik podnapięciowy', '208-240VAC NSX100-630A', 'SCHNEIDER ELECTRIC', '3322701987', '3606480018961', 'LV429407', array['Solar','LEMU','RS PRO'], 'E1.4', null, 'stk'),
  ('Klemmeafdeler', 'Przegroda zacisków', '4P NSX400-630A', 'SCHNEIDER ELECTRIC', '3322704706', '3606480019968', 'LV432594', array['Solar','LEMU','RS PRO'], 'E1.4', null, 'stk'),
  ('Kontaktor Spærring', 'Blokada styczników', 'Mek./Ele. Spærring LC1D09-D38', 'SCHNEIDER ELECTRIC', '7522405173', '3389110392869', 'LAD9R1V', array['Solar','LEMU','RS PRO'], 'E2.1', null, 'stk'),
  ('Reversings Kontaktor', 'Stycznik nawrotny', 'Tesys K 3P 9A 24VDC', 'SCHNEIDER ELECTRIC', '7522025346', '3389110428537', 'LP2K0901BD', array['Solar','LEMU','RS PRO'], 'E2.1', null, 'stk'),
  ('Automatsikring (MCB)', 'Wyłącznik nadprądowy (MCB)', '16A 3P+N C 6kA', 'EATON', '5422562383', '4015082430184', 'PLS6-C16/3N-NW', array['Solar','LEMU'], 'E1.1', null, 'stk'),
  ('Operatørvindue', 'Okienko operatora', '257,5x93,5mm IP44', 'BALS ELEKTROTECHNIK', null, '4024941586078', '58607', array['Bals Elektrotechnik'], 'M3', null, 'stk'),
  ('Operatørvindue', 'Okienko operatora', '234x93,5mm IP44', 'BALS ELEKTROTECHNIK', null, '4024941586023', '58602', array['Bals Elektrotechnik'], 'M3', null, 'stk'),
  ('Operatørvindue', 'Okienko operatora', '162x93,5mm IP44', 'BALS ELEKTROTECHNIK', null, '4024941585026', '58502', array['Bals Elektrotechnik'], 'M3', null, 'stk'),
  ('Operatørvindue', 'Okienko operatora', '127x93,5mm IP44', 'BALS ELEKTROTECHNIK', null, '4024941585033', '58503', array['Bals Elektrotechnik'], 'M3', null, 'stk'),
  ('Operatørvindue', 'Okienko operatora', '188x250mm IP65', 'EATON', null, '4015080724766', 'D125-CI23/T', '{}'::text[], 'M3', null, 'stk'),
  ('Monteringsledning', 'Przewód montażowy', '2,5mm Hvid PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5432730765', '7330000121393', '11183441-002-02', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '2,5mm Rød PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5432730781', '7330000121409', '11183441-003-02', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '2,5mm Gr/Gul PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5432730833', '7330000121454', '11183441-022-02', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '2,5mm Lyseblå PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5432730862', '7330000121485', '11183441-152-02', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '2,5mm Brun PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5432730804', '7330000121423', '11183441-008-02', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '2,5mm Sort PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5432730778', '7330000121386', '11183441-001-02', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '2,5mm Grå PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5432730817', '7330000121461', '11183441-070-02', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '6mm Gr/Gul PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5432732158', '7330000120020', '11183641-022-02', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '6mm Lyseblå PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5432730914', '7330000120037', '11183641-152-02', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '6mm Brun PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5433901483', '5708953563249', '11183641-008-02', array['Solar'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '6mm Sort PVC H07V2-K', 'NEXANS (SOLAR PLUS)', '5432730901', '7330000119987', '11183641-001-02', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Monteringsledning', 'Przewód montażowy', '6mm Grå PVC H07V2-K (Ring)', 'NKT', '3032630144', '5702950177621', '160011014C0100', array['Solar','LEMU'], 'E3.1', null, 'm'),
  ('Maksimalafbryder', 'Wyłącznik maksymalnoprądowy', 'NSXM Compact 400A 50kA  4P', 'SCHNEIDER ELECTRIC', '3322743819', '3606482003163', 'C40N4', array['Solar','LEMU','RS PRO'], 'E1.1', null, 'stk'),
  ('Motordrev', 'Napęd silnikowy', '220-240VAC NSX400-630A', 'SCHNEIDER ELECTRIC', '3322704874', '3606480020179', 'LV432641', array['Solar','LEMU','RS PRO'], 'E1.4', null, 'stk'),
  ('Klemme', 'Zacisk', '4mm Beige', 'WEIDMULLER', '7921181250', '4008190150617', 'WDU 4', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Jordklemme', 'Zacisk uziemiający', '2,5mm Gr/Gul', 'WEIDMULLER', '7921182178', '4008190143640', 'WPE 2.5', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Jordklemme', 'Zacisk uziemiający', '4mm Gr/Gul', 'WEIDMULLER', '7921182181', '4008190039820', 'WPE 4', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Klemme', 'Zacisk', '2,5mm Blå', 'WEIDMULLER', '7921181014', '4008190163235', 'WDU 2.5 BL', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Klemme', 'Zacisk', '2,5/1,5mm Beige', 'WEIDMULLER', '7921180073', '4008190008833', 'WDU 2.5/1.5/ZR', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Laske', 'Mostek łączący', '4mm 10 polet', 'WEIDMULLER', '7921181328', '4008190054687', 'WQV 4/10', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Endevinkel', 'Kątownik końcowy', '35mm DIN Beige', 'WEIDMULLER', '7921138177', '4008190030230', 'WEW 35/2', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Klemme', 'Zacisk', '6mm Beige', 'WEIDMULLER', '7921181438', '4008190163440', 'WDU 6', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Klemme', 'Zacisk', '4mm Grå', 'ENTRELEC', null, '3472595050109', '1SNK505010R0000', array['RS PRO'], 'E2.7', null, 'stk'),
  ('Klemme', 'Zacisk', '4mm Grå m/Sikring 6.3A', 'ENTRELEC', null, '3472595084128', '1SNK508412R0000', array['RS PRO'], 'E2.7', null, 'stk'),
  ('Klemme', 'Zacisk', '4mm Beige m/Tension', 'WEIDMULLER', null, '4032248511150', 'PDU 2.5/4', array['LEMU'], 'E2.7', null, 'stk'),
  ('Endeplade', 'Płytka końcowa', '2,5-10mm Beige', 'WEIDMULLER', '7921181043', '4008190103149', 'WAP 2.5-10', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Klemme', 'Zacisk', '6mm Blå', 'WEIDMULLER', '7921181441', '4008190100032', 'WDU 6 BL', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Kontaktelement', 'Element stykowy', '1NO+1NC 10A', 'IDEC', '5401016401', '5705151114686', 'YW-EW11', array['Solar'], 'E2.3', null, 'stk'),
  ('Kontaktelement', 'Element stykowy', '1NC 10A', 'IDEC', '0817101451', '5705151114655', 'YW-EW01', array['Solar'], 'E2.3', null, 'stk'),
  ('Kontaktelement', 'Element stykowy', '2NC 10A', 'IDEC', '0817101477', '5705151114679', 'YW-EW02', array['Solar'], 'E2.3', null, 'stk'),
  ('Kontaktelement', 'Element stykowy', '1NO 10A', 'IDEC', '0817101464', '5705151114662', 'YW-EW10', array['Solar'], 'E2.3', null, 'stk'),
  ('Kontaktelement', 'Element stykowy', '2NO 10A', 'IDEC', '0817101493', '5705151114693', 'YW-EW20', array['Solar'], 'E2.3', null, 'stk'),
  ('Signallampe', 'Lampka sygnalizacyjna', 'BA9 Grøn 230VAC', 'IDEC', '8050400199', '5703436682196', 'LSED-M3GN', array['Solar'], 'E2.3', null, 'stk'),
  ('Bilrelæ', 'Przekaźnik samochodowy', '12V 30/40A SPDT', 'RAZE', null, '5705755405432', '40695', array['Thansen'], 'E4.1', null, 'stk'),
  ('Nødstop', 'Wyłącznik awaryjny', '1NC 10A 22mm Drej til udløse', 'IDEC', '0817101309', '5705151115676', 'YW1B-V4E01R', array['Solar'], 'E2.3', null, 'stk'),
  ('Omskifter', 'Przełącznik', '1NO 10A 22mm 2 Fast Pos.', 'IDEC', '0817101406', '5705151114600', 'YW1S-2E10', array['Solar'], 'E2.3', null, 'stk'),
  ('Omskifter', 'Przełącznik', '2NO 10A 2mm 3 Fast Pos.', 'IDEC', '0817101422', '5705151114624', 'YW1S-3E20', array['Solar'], 'E2.3', null, 'stk'),
  ('Signaltryknap', 'Przycisk sygnalizacyjny', 'XB5 Rød Plan', 'SCHNEIDER ELECTRIC', '7517901527', '3389110909968', 'ZB5AW343', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Signaltryknap', 'Przycisk sygnalizacyjny', 'XB5 Hvid Plan', 'SCHNEIDER ELECTRIC', '7517901501', '3389110909920', 'ZB5AW313', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Signallampe', 'Lampka sygnalizacyjna', 'Planforsænket 24V Grøn', 'ARCOLECTRIC', null, null, 'C027500FAL', array['RS PRO'], 'E2.3', null, 'stk'),
  ('Signallampe', 'Lampka sygnalizacyjna', 'Planforsænket 220V Grøn', 'ARCOLECTRIC', null, null, 'C027500NBC', array['RS PRO'], 'E2.3', null, 'stk'),
  ('Signallampe', 'Lampka sygnalizacyjna', 'Fremspringende 220V Rød', 'ARCOLECTRIC', null, null, 'C027700NAO', array['RS PRO'], 'E2.3', null, 'stk'),
  ('Måletransformer', 'Przekładnik prądowy', '400/5A Klasse 1.0', 'RS PRO', null, null, '171-8799', array['RS PRO'], 'E1.3', null, 'stk'),
  ('Elmåler', 'Licznik energii', 'A10 3-faset DIN Montage', 'SOCOMEC', null, '3596033014796', '48250400', array['Socomec'], 'E1.3', null, 'stk'),
  ('Udløserrelæ', 'Przekaźnik wyzwalający', '230VAC', 'SOCOMEC', null, '3596031193561', '39901220', array['Socomec'], 'E1.4', null, 'stk'),
  ('Operatørboks', 'Obudowa sterownicza', '1NO Omskifter', 'SCHNEIDER ELECTRIC', '7517900463', '3389110113952', 'XALD134', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Termorelæ', 'Przekaźnik termiczny', 'B18K 2,5-4,1A', 'AEG', null, '8017018396072', null, '{}'::text[], 'E2.1', null, 'stk'),
  ('Termorelæ', 'Przekaźnik termiczny', 'B05 4-6,3A', 'AEG', null, '4022903100928', null, '{}'::text[], 'E2.1', null, 'stk'),
  ('Kontaktor', 'Stycznik', 'LS4K.10 4P 25A 230VAC', 'AEG', null, '8017018430110', null, '{}'::text[], 'E2.1', null, 'stk'),
  ('Ventilstik', 'Wtyk zaworu', '4 polet DIN 43650A', null, null, null, 'C18209N21', '{}'::text[], 'E4.3', null, 'stk'),
  ('Kontaktor', 'Stycznik', 'CN40.10 4P 40A 230VAC', 'LOVATO', null, '8013975143810', 'CN4010220', '{}'::text[], 'E2.1', null, 'stk'),
  ('Sikring', 'Bezpiecznik', 'Auto 50A 58VDC', 'LITTELFUSE', null, null, '155.0892.5501', '{}'::text[], 'E1.1', null, 'stk'),
  ('Sikringsholder', 'Oprawka bezpiecznika', 'Batteriterminal', 'LITTELFUSE', null, null, '255.0808.0001', '{}'::text[], 'E1.1', null, 'stk'),
  ('Klemme', 'Zacisk', 'Jordterminal 100A', 'STROMSTOSS', null, null, '1049100', array['Stromstoss'], 'E1.5', null, 'stk'),
  ('LED Driver', 'Zasilacz LED', 'Justerbar 230V 5A', null, null, null, 'HLC734-Z-SC-BS-PM-1C-IA-R-WP-OTA-3.0', '{}'::text[], 'E4.2', null, 'stk'),
  ('Tidsrelæ', 'Przekaźnik czasowy', 'Lampe relæ 12VDC', 'NGK SPARK PLUG CO.', null, null, 'S81NL', '{}'::text[], 'E4.1', null, 'stk'),
  ('Stik', 'Wtyk', '6 polet stikben hun', null, null, null, null, '{}'::text[], 'E4.3', null, 'stk'),
  ('Drejegreb', 'Rękojeść obrotowa', 'Lille, til isolator', 'ABB', '2119815715', '6417019124117', 'OHB65J6', array['Solar','LEMU','RS PRO'], 'E1.4', null, 'stk'),
  ('Drejegreb', 'Rękojeść obrotowa', 'Mellem, til isolator', 'ABB', '2118751715', '6417019124230', 'OHB95J12', array['Solar','LEMU','RS PRO'], 'E1.4', null, 'stk'),
  ('Fingeråbner', 'Narzędzie do otwierania zacisków', 'til tavle', 'HENSEL', '8812204478', '4012591650140', 'MiSN4', array['Solar','LEMU'], 'M3', null, 'stk'),
  ('Lågskrue', 'Śruba pokrywy', 'til tavle', 'HENSEL', '8812204436', '4012591658191', 'MiDV01', array['Solar','LEMU'], 'M3', null, 'stk'),
  ('Strømforsyning', 'Zasilacz', '24VDC 2,5A 60W', 'MEANWELL', '0863101201', '8720207875127', 'HDR-60-24', array['Solar'], 'E2.6', null, 'stk'),
  ('Strømforsyning', 'Zasilacz', '12VDC 7,5A 90W', 'MEANWELL', null, null, 'HDR-100-12N', array['RS PRO'], 'E2.6', null, 'stk'),
  ('Strømforsyning', 'Zasilacz', '12VDC 4,5A 60W', 'MEANWELL', null, '4021087017473', 'DR-60-12', '{}'::text[], 'E2.6', null, 'stk'),
  ('Transformer', 'Transformator', '230V/24V/12V 24VA', 'MALMBERGS', null, null, '2013024', '{}'::text[], 'E2.6', null, 'stk'),
  ('Operatørvindue', 'Okienko operatora', '85mm x 94mm', null, null, null, null, '{}'::text[], 'M3', null, 'stk'),
  ('Operatørvindue', 'Okienko operatora', '122mm x 94mm', null, null, null, null, '{}'::text[], 'M3', null, 'stk'),
  ('Operatørvindue', 'Okienko operatora', '160cm x 94mm', null, null, null, null, '{}'::text[], 'M3', null, 'stk'),
  ('Stikhus', 'Obudowa wtyku', 'HAN 3 A M20', 'HARTING', '5428330357', '5713140124585', '19200031440', array['Solar','LEMU'], 'E3.7', null, 'stk'),
  ('Chassishus', 'Obudowa podstawy', 'HAN 3 A Bøjle Vinklet', 'HARTING', '5428331990', '5713140038677', '09200030801', array['Solar','LEMU'], 'E3.7', null, 'stk'),
  ('Drejegreb', 'Rękojeść obrotowa', 'Stor rød, til isolator', 'SOCOMEC', null, null, '14323511', array['RS PRO'], 'E1.4', null, 'stk'),
  ('Samledåse', 'Puszka łączeniowa', 'M20 IP66 85x85mm', 'WISKA', '5421026972', '4007685018296', '10060400', array['Solar'], 'M3', null, 'stk'),
  ('Stikindsats', 'Wkład wtyku', 'HAN 3 A 3P+PE Han', 'HARTING', '5428332591', '5713140038820', '09200032611', array['Solar','LEMU'], 'E3.7', null, 'stk'),
  ('Stikindsats', 'Wkład wtyku', 'HAN 3A 3P+PE Hun', 'HARTING', '5428332601', '5713140038851', '09200032711', array['Solar','LEMU'], 'E3.7', null, 'stk'),
  ('Chassishus', 'Obudowa podstawy', 'HAN 10 A Bøjle & Låg', 'HARTING', '5428335365', '5713140039247', '09200100321', array['Solar','LEMU'], 'E3.7', null, 'stk'),
  ('Relæsokkel', 'Podstawka przekaźnika', 'RXG med 2CO, 5A 250V', 'SCHNEIDER ELECTRIC', '7522602549', '3606480689444', 'RGZE1S48M', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæsokkel', 'Podstawka przekaźnika', 'Stikbens med 2CO, 10A 250V', 'SCHNEIDER ELECTRIC', '7522600732', '3389110260083', 'RSZE1S48M', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæsokkel', 'Podstawka przekaźnika', 'RXM med 4CO, 10A 250V', 'SCHNEIDER ELECTRIC', '7522506687', '3389119404259', 'RXZE2M114M', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæsokkel', 'Podstawka przekaźnika', '2CO, 10A 250V', 'FINDER', '0822000880', '8012823115450', '95.05', array['Solar','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæsokkel', 'Podstawka przekaźnika', '2CO, 10A 250V', 'RELPOL', '5422500235', '5900005092183', 'GZM80', array['Solar'], 'E2.2', null, 'stk'),
  ('Relæsokkel', 'Podstawka przekaźnika', 'RXM med 2CO, 12A 250V', 'SCHNEIDER ELECTRIC', '7522506690', '3389119404266', 'RXZE2S108M', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæsokkel', 'Podstawka przekaźnika', 'RXM', 'SCHNEIDER ELECTRIC', null, null, null, '{}'::text[], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXG med 2CO, 5A 250V, 24VDC', 'SCHNEIDER ELECTRIC', '7522603124', '3606480689178', 'RXG22BD', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXG med 2CO, 5A 250V, 24VDC', 'SCHNEIDER ELECTRIC', '7522603234', '3606480689284', 'RXG23BD', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXG med 2CO, 5A 250V, 230VAC', 'SCHNEIDER ELECTRIC', '7522603205', '3606480689147', 'RXG22P7', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'Med 2CO, 5A 250V, 230VAC', 'OMRON', '5401049391', '4547648074698', 'G2R-2-SNI-AP3 (S)', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXM med 2CO, 12A 250V, 24VDC', 'SCHNEIDER ELECTRIC', '7522505675', '3389119403474', 'RXM2AB2BD', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXM med 4CO, 6A 250V, 230VAC', 'SCHNEIDER ELECTRIC', '7522506357', '3389119403887', 'RXM4AB2P7', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXM med 4CO, 6A 250V, 24VDC', 'SCHNEIDER ELECTRIC', '7522506014', '3389119403719', 'RXM4AB1BD', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXM med 4CO, 6A 250V, 12VDC', 'SCHNEIDER ELECTRIC', '7522506153', '3389119403764', 'RXM4AB1JD', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXM med 2CO, 12A 250V, 12VDC', 'SCHNEIDER ELECTRIC', '7522505727', '3389119403528', 'RXM2AB2JD', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Kontaktelement', 'Element stykowy', 'XB4/5 1 NO', 'SCHNEIDER ELECTRIC', '7517807825', '3389110089479', 'ZBE101', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Kontaktelement', 'Element stykowy', 'XB4/5 1 NC', 'SCHNEIDER ELECTRIC', '7517807838', '3389110089486', 'ZBE102', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Kontaktelement', 'Element stykowy', 'XALD 1 NO', 'SCHNEIDER ELECTRIC', '7517900489', '3389110115079', 'ZENL1111', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Lyselement', 'Element świetlny', 'XB4/5 230VAC', 'SCHNEIDER ELECTRIC', '7517807980', '3389110090031', 'ZBVM1', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Blindprop', 'Zaślepka', 'ZB5 Ø22mm', 'SCHNEIDER ELECTRIC', '7517902351', '3389110099522', 'ZB5SZ3', array['Solar','LEMU','RS PRO'], 'M7', null, 'stk'),
  ('Kropsdel', 'Korpus', 'XB4', 'SCHNEIDER ELECTRIC', '7517807812', '3389110102024', 'ZB4BZ009', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Kropsdel', 'Korpus', 'XB5', 'SCHNEIDER ELECTRIC', '7517906577', '3389110102215', 'ZB5AZ009', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Skilt', 'Tabliczka', 'XB4/5 Nødstop', 'SCHNEIDER ELECTRIC', '7517815972', '3606480561276', 'ZBY9320', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Skilt', 'Tabliczka', 'XB4/5 Holder', 'SCHNEIDER ELECTRIC', '7517809205', '3389110092592', 'ZBZ32', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Skilt', 'Tabliczka', 'XB4/5 Holder m/Skilt', 'SCHNEIDER ELECTRIC', '7517809357', '3389110095876', 'ZBY6102', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Hjælpekontakt', 'Styk pomocniczy', '1CO NSX 80-630A', 'SCHNEIDER ELECTRIC', '3322294504', '3303430294504', '29450', array['Solar','LEMU','RS PRO'], 'E1.4', null, 'stk'),
  ('Sikringsholder', 'Oprawka bezpiecznika', '32A 10x38mm aM/gG', 'SCHNEIDER ELECTRIC', '7518500040', '3389119407205', 'DF101', array['LEMU','RS PRO'], 'E1.1', null, 'stk'),
  ('Timer', 'Timer', 'Multifunk. SPDT 5A 24-240VAC/DC', 'CARLO GARVAZZI', '9623017031', '8030956002188', 'DMB51CW24', array['Solar','LEMU'], 'E2.3', null, 'stk'),
  ('Stik', 'Wtyk', '2P Han IP67 10A', 'RS PRO', null, null, '207-2303', array['RS PRO'], 'E3.7', null, 'stk'),
  ('Omskifter', 'Przełącznik', '4NO 12A 22mm 4 Fast Pos.', 'SCHNEIDER ELECTRIC', '7517675853', '3389110978858', 'K1D004NCH', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Vinkelgevind', 'Kątowe złącze gwintowane', 'M40 90* Messing', 'JACOB', '7613026348', '4024092141706', '21.640M', array['Solar'], 'M7', null, 'stk'),
  ('Sikringsskuffe', 'Szuflada bezpiecznikowa', 'Tytan I 1P 16A', 'NIKO', '3419700668', '5703102006073', '61-011', array['Solar','LEMU'], 'E1.1', null, 'stk'),
  ('Sikringsskuffe', 'Szuflada bezpiecznikowa', 'Tytan I 2-16A', 'NIKO', '3419700710', '5703102006127', '61-921', array['Solar','LEMU'], 'E1.1', null, 'stk'),
  ('Sikring', 'Bezpiecznik', 'NEOZED D01 Gg 6A 400V', 'SIEMENS', '2625207024', '4001869005942', '5SE2306', array['Solar','LEMU','RS PRO'], 'E1.1', null, 'stk'),
  ('Gruppeafbryder', 'Wyłącznik grupowy', 'Tytan I 1P+N 16A', 'NIKO', '3419700697', '5703102006080', '61-012', array['Solar','LEMU'], 'E1.1', null, 'stk'),
  ('Kontaktor', 'Stycznik', 'Tesys K 4P 6A 24VDC', 'SCHNEIDER ELECTRIC', '7522024295', '3389110363227', 'LP1K0610BD', array['Solar','LEMU','RS PRO'], 'E2.1', null, 'stk'),
  ('Kontaktor', 'Stycznik', 'Tesys K 2NO+2NC 20A 24VDC', 'SCHNEIDER ELECTRIC', '7522025838', '3389110495836', 'LP1K09008BD', array['Solar','LEMU','RS PRO'], 'E2.1', null, 'stk'),
  ('Termorelæ', 'Przekaźnik termiczny', 'Tesys K 1,8-2,6A', 'SCHNEIDER ELECTRIC', '7522028356', '3389110230444', 'LR2K0308', array['Solar','LEMU','RS PRO'], 'E2.1', null, 'stk'),
  ('Montageplade', 'Płyta montażowa', '275x325mm Stål', 'SCHNEIDER ELECTRIC', '7512400036', '3606480166112', 'NSYAMPM3429TB', array['Solar','LEMU','RS PRO'], 'M3', null, 'stk'),
  ('Montageboks', 'Puszka montażowa', '341x291x128mm Polycarbonat', 'SCHNEIDER ELECTRIC', '7512401679', '3606480165924', 'NSYTBP342912T', array['Solar','LEMU','RS PRO'], 'M3', null, 'stk'),
  ('Omskifter', 'Przełącznik', '1NO 10A 22mm 2 Fast Pos.', 'SCHNEIDER ELECTRIC', '7517803641', '3389110888935', 'XB4BD2', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Signallampe', 'Lampka sygnalizacyjna', 'XB4 Blå', 'SCHNEIDER ELECTRIC', '7517805429', '3389110895018', 'ZB4BV063', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('PLC', 'Sterownik PLC', 'LOGO! 12/24VDC 8/4IO Relay', 'SIEMENS', '5401027927', '4034106034474', '6ED1052-1MD08-0BA2', array['Solar','LEMU','RS PRO'], 'E2.4', null, 'stk'),
  ('Sikringsklemme', 'Zacisk z bezpiecznikiem', '4mm Sort Lyssignal 10-36V', 'WEIDMULLER', '7921073546', '4032248492077', 'WSI 4/LD 10-36V AC/DC', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('LED Floodlight', 'Naświetlacz LED', '320W', 'AOK', null, null, '94054090', '{}'::text[], 'E4.2', null, 'stk'),
  ('CEE Indtag', 'Gniazdo wejściowe CEE', 'Vinklet Vægindtag 230V 16A 3P', 'BALS ELEKTROTECHNIK', '5418520274', '4024941002455', '245', array['Solar'], 'E3.5', null, 'stk'),
  ('CEE Indtag', 'Gniazdo wejściowe CEE', 'Flange 230V 16A 3P', 'BALS ELEKTROTECHNIK', '5418521273', '4024941136860', '13686', array['Solar'], 'E3.5', null, 'stk'),
  ('Stik Udtag', 'Gniazdo wtykowe', 'Type F (Schuko) Hun 230V 16A', 'BALS ELEKTROTECHNIK', '5428522233', '4024941962148', '71099', array['Solar'], 'E3.5', null, 'stk'),
  ('Montageboks', 'Puszka montażowa', '125x175x100m ABS', 'BELS', '0812104958', '6418677155468', 'SABP131810G', array['Solar'], 'M3', null, 'stk'),
  ('Automatsikring (MCB)', 'Wyłącznik nadprądowy (MCB)', '16A 1P+N C 6kA', 'EATON', '5422563065', '4015082428112', 'PLZ6-C16/1N-MW', array['Solar','LEMU'], 'E1.1', null, 'stk'),
  ('LED Driver', 'Zasilacz LED', '320W CC 6.7A', 'INVENTRONICS', null, null, 'EUD-320S670DV', '{}'::text[], 'E4.2', null, 'stk'),
  ('Sikring', 'Bezpiecznik', 'Auto 200A 58VDC', 'LITTELFUSE', null, null, '155.0892.6201', array['RS PRO'], 'E1.1', null, 'stk'),
  ('Udtag', 'Gniazdo', '2P Hun IP67 10A', 'RS PRO', null, null, '207-2374', array['RS PRO'], 'E3.7', null, 'stk'),
  ('Termorelæ', 'Przekaźnik termiczny', 'Tesys K 3,7-5,5A', 'SCHNEIDER ELECTRIC', '7522028372', '3389110230567', 'LR2K0312', array['Solar','LEMU','RS PRO'], 'E2.1', null, 'stk'),
  ('Kontaktor', 'Stycznik', 'Tesys K 3P+1NC 6A 24VDC', 'SCHNEIDER ELECTRIC', '7522024871', '3389110428551', 'LP4K0601BW3', array['Solar','LEMU','RS PRO'], 'E2.1', null, 'stk'),
  ('Hjælpekontakt', 'Styk pomocniczy', '20A til Vario lastadskiller', 'SCHNEIDER ELECTRIC', '7518300224', '3389110448900', 'VZ01', array['Solar','LEMU','RS PRO'], 'E1.6', null, 'stk'),
  ('Sikkerhedsafbryder', 'Wyłącznik bezpieczeństwa', '20A 3P Rød/gul', 'SCHNEIDER ELECTRIC', '7518301236', '3389110724868', 'VCD01', array['LEMU','RS PRO'], 'E1.6', null, 'stk'),
  ('Nødstop', 'Wyłącznik awaryjny', 'Ø40 Rød', 'SCHNEIDER ELECTRIC', '7517804967', '3389110888867', 'ZB4BS844', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Omskifter', 'Przełącznik', '22mm 3 Pos, Fjeder til midt', 'SCHNEIDER ELECTRIC', '7517803722', '3389110888973', 'ZB4BD5', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Signallampe', 'Lampka sygnalizacyjna', 'XB4 Rød', 'SCHNEIDER ELECTRIC', '7517805380', '3389110894998', 'ZB4BV043', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Signallampe', 'Lampka sygnalizacyjna', 'XB4 Grøn', 'SCHNEIDER ELECTRIC', '7517805364', '3389110895001', 'ZB4BV033', array['Solar','LEMU','RS PRO'], 'E2.3', null, 'stk'),
  ('Relæsokkel', 'Podstawka przekaźnika', 'RXM med 4CO, 10A 250V', 'SCHNEIDER ELECTRIC', '7522506742', '3389119404280', 'RXZE2S114M', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXM med 4CO, 6A 250V, 24VDC', 'SCHNEIDER ELECTRIC', '7522506276', '3389119403818', 'RXM4AB2BD', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Sikring', 'Bezpiecznik', 'Cylinder 10x38mm 2A gG 500V', 'SIEMENS', '2625002711', '4001869061474', '3NW6002-1', array['Solar','LEMU','RS PRO'], 'E1.1', null, 'stk'),
  ('Sikring', 'Bezpiecznik', 'Cylinder 10x38mm 6A gG 500V', 'SIEMENS', '2625002708', '4001869061467', '3NW6001-1', array['Solar','LEMU','RS PRO'], 'E1.1', null, 'stk'),
  ('Ventilator', 'Wentylator', '230VAC 38M3/T 92x92mm', 'SCHNEIDER ELECTRIC', '7512404003', '3606480151163', 'NSYCVF38M230PF', array['Solar','LEMU','RS PRO'], 'E2.9', null, 'stk'),
  ('Ventilator Gitter', 'Kratka wentylatora', '92x92mm', 'SCHNEIDER ELECTRIC', '7512404362', '3606480151521', 'NSYCAG92LPF', array['Solar','LEMU','RS PRO'], 'E2.9', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXG med 1CO, 10A 250V, 24VDC', 'SCHNEIDER ELECTRIC', '7522602688', '3606480688737', 'RXG12BD', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæsokkel', 'Podstawka przekaźnika', 'RXG med 1CO, 10A 250V', 'SCHNEIDER ELECTRIC', '7522602536', '3606480689437', 'RGZE1S35M', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Batteri', 'Bateria', '12V/230Ah AGM', 'VICTRON ENERGY', null, '8719076039570', 'BAT412123081', '{}'::text[], 'E4.4', null, 'stk'),
  ('Inverter', 'Falownik', '48V 5kVA 32A 70A', 'VICTRON ENERGY', null, '8719076047599', 'PMP482505012', '{}'::text[], 'E2.4', null, 'stk'),
  ('Overvåger', 'Układ nadzoru', 'Til batteri', 'VICTRON ENERGY', null, null, 'BAM010700000', '{}'::text[], 'E2.5', null, 'stk'),
  ('Pumpe', 'Pompa', '230VAC 5L m/12VDC ventil', 'VINCKE', null, null, 'MHYSE002993', '{}'::text[], 'E4.2', null, 'stk'),
  ('Klemme', 'Zacisk', '70mm Beige Bolt', 'WEIDMULLER', '5401035120', '4008190149208', 'WFF 70/AH', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Klemmefordeler', 'Rozdzielacz zacisków', '6mm-1,5mm Rød Blå', 'WEIDMULLER', '5401026103', '4050118520873', '2506090000', array['Solar','LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Kabelsko', 'Końcówka kablowa', 'Alu. M12 150mm', 'KLAUKE', '7921778155', '4012078537728', '210R12', array['Solar','LEMU'], 'E3.4', null, 'stk'),
  ('Kabelsko', 'Końcówka kablowa', 'Alu. M12 120mm', null, null, null, null, '{}'::text[], 'E3.4', null, 'stk'),
  ('Kabelsko', 'Końcówka kablowa', 'Kob. M12 50mm', null, null, null, null, '{}'::text[], 'E3.4', null, 'stk'),
  ('Kabelsko', 'Końcówka kablowa', 'Kob. M12 16mm', 'SOLAR PLUS', '0821104033', '5705151214034', '16-12', array['Solar'], 'E3.4', null, 'stk'),
  ('Kabelsko', 'Końcówka kablowa', 'Kob. M10 35mm', 'RACO', null, null, '090013', '{}'::text[], 'E3.4', null, 'stk'),
  ('Kabelsko', 'Końcówka kablowa', 'Kob. M10 16mm', 'NEMIQ', null, '7331176119689', '16-10', '{}'::text[], 'E3.4', null, 'stk'),
  ('Kabelsko', 'Końcówka kablowa', 'Kob. M8 16mm', null, null, null, null, '{}'::text[], 'E3.4', null, 'stk'),
  ('Kabelsko', 'Końcówka kablowa', 'Kob. M8 6mm', null, null, '5703666211036', null, '{}'::text[], 'E3.4', null, 'stk'),
  ('Kabelsko', 'Końcówka kablowa', 'Kob. M6 6mm', 'SOLAR PLUS', '0821103034', '5705151213037', '6-6', array['Solar'], null, null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXM med 2CO, 5A 250V, 12VDC', 'SCHNEIDER ELECTRIC', '7522603111', '3606480689109', 'RXG22B7', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Relæ', 'Przekaźnik', 'RXM med 2CO, 12A 250V, 230VAC', 'SCHNEIDER ELECTRIC', '7522505730', '3389119403535', 'RXM2AB2P7', array['Solar','LEMU','RS PRO'], 'E2.2', null, 'stk'),
  ('Klemme', 'Zacisk', 'm/ diode 1A', 'PHOENIX CONTACT', '7821212957', '4017918960988', '3046210', array['LEMU','RS PRO'], 'E2.7', null, 'stk'),
  ('Kondensator', 'Kondensator', '47mF 25VDC', 'KEMET', null, null, 'ALS40A473DF025', array['RS PRO'], 'E5.2', null, 'stk'),
  ('Sikringsholder', 'Oprawka bezpiecznika', '10A 5x20mm', 'SCHURTER', null, null, '3101.0310', array['RS PRO'], null, null, 'stk')
) as v(type_da, type_pl, model, producent, elnr, ean, modelnr, leverandorer,
       kategori, placering, enhed)
where not exists (
  select 1 from materialer m
  where (m.elnr is not null and m.elnr <> '' and m.elnr = v.elnr)
     or (m.type_da = v.type_da and coalesce(m.model,'') = coalesce(v.model,''))
);

-- To rækker i regnearket har en ugyldig kategorikode (kyrillisk 'А' og en tom).
-- De ligger nu uden kategori — find dem i appen med filteret "Uden kategori".

-- ---------- 10. Historik pr. vare, med løbende saldo ----------
-- Svarer til det appen viser når man klikker på en vare i lageret.
create or replace view v_historik as
select b.materiale_id, b.dato, b.art, b.antal, b.initialer, b.note, b.afdeling,
       u.navn as udstyr,
       sum(b.antal) over (partition by b.materiale_id, b.afdeling
                          order by b.dato, b.id) as saldo
from bevaegelser b
left join udstyr u on u.id = b.udstyr_id
order by b.materiale_id, b.dato, b.id;
