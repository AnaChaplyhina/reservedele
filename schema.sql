-- ============================================================
--  Reservedele · Power Ejby
--  Supabase-skema. Kør hele filen i SQL Editor én gang.
-- ============================================================

-- ---------- 1. Katalog ----------
create table if not exists materialer (
  id          bigint generated always as identity primary key,
  navn_da     text,                        -- kanonisk navn. Tomt = venter på kuratering
  navn_pl     text,                        -- teknikerens eget ord
  aliaser     text[] default '{}',         -- flere søgeord, ethvert sprog. Erstatter maskinoversættelse
  varenr      text,                        -- nummeret I bestiller efter
  leverandor  text,                        -- hvor I bestiller
  enhed       text default 'stk',
  pris        numeric(10,2),               -- pris pr. enhed, sidst kendte
  minimum     numeric(10,2) default 0,     -- 0 = kun advarsel ved udsolgt
  kategori    text,
  status      text default 'ukurateret' check (status in ('ukurateret','kurateret')),
  created_at  timestamptz default now()
);

-- ---------- 2. Udstyr (det der repareres) ----------
create table if not exists udstyr (
  id         bigint generated always as identity primary key,
  navn       text not null,                -- pr. ENHED: "Generator 45", ikke "generatorer"
  type       text,                         -- tavle / generator / lystårn / køletrailer / andet
  serienr    text,
  afdeling   text default 'Ejby',
  aktiv      boolean default true,
  created_at timestamptz default now()
);

-- ---------- 3. Bevægelser: ét sted for forbrug OG indkøb ----------
-- Beholdningen er ikke et felt man retter — den er summen af denne tabel.
-- Derfor kan man altid se hvor tallet kommer fra, og en rettelse ødelægger ikke lageret.
create table if not exists bevaegelser (
  id           bigint generated always as identity primary key,
  materiale_id bigint not null references materialer(id),
  antal        numeric(10,2) not null,     -- negativ = forbrug, positiv = indkøb
  art          text not null check (art in ('forbrug','indkoeb','korrektion')),
  udstyr_id    bigint references udstyr(id),   -- kun ved forbrug
  dato         date not null default current_date,
  initialer    text,
  note         text,
  pris         numeric(10,2),              -- prisen på handlingstidspunktet (fryses)
  afdeling     text not null default 'Ejby',   -- Hedehusene tilføjes her senere
  created_at   timestamptz default now(),
  constraint forbrug_kraever_udstyr check (art <> 'forbrug' or udstyr_id is not null),
  constraint fortegn check ((art = 'forbrug' and antal < 0) or (art <> 'forbrug'))
);

create index if not exists bev_mat_idx  on bevaegelser (materiale_id);
create index if not exists bev_afd_idx  on bevaegelser (afdeling);
create index if not exists bev_dato_idx on bevaegelser (dato);

-- ---------- 4. Beholdning pr. vare pr. afdeling ----------
create or replace view v_beholdning as
select m.id as materiale_id, b.afdeling,
       coalesce(sum(b.antal), 0) as beholdning,
       m.minimum,
       coalesce(sum(b.antal), 0) <= 0                          as udsolgt,
       m.minimum > 0 and coalesce(sum(b.antal), 0) <= m.minimum as skal_bestilles
from materialer m
left join bevaegelser b on b.materiale_id = m.id
group by m.id, b.afdeling, m.minimum;

-- ---------- 5. Bestillingsliste ----------
create or replace view v_bestilling as
select m.navn_da, m.varenr, m.leverandor, m.enhed,
       v.afdeling, v.beholdning,
       greatest(1, m.minimum - v.beholdning) as bestil_antal
from v_beholdning v
join materialer m on m.id = v.materiale_id
where v.udsolgt or v.skal_bestilles
order by m.leverandor nulls last, v.beholdning;

-- ---------- 6. Statistik: udstyr, dyrest først ----------
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

-- ---------- 7. Statistik: reservedele ----------
create or replace view v_vare_forbrug as
select m.id, m.navn_da, m.varenr, m.leverandor, m.enhed,
       sum(abs(b.antal))                                            as total_antal,
       coalesce(sum(abs(b.antal) * coalesce(b.pris, m.pris, 0)), 0)  as samlet_kr,
       count(distinct b.udstyr_id)                                   as antal_udstyr
from materialer m
join bevaegelser b on b.materiale_id = m.id and b.art = 'forbrug'
group by m.id
order by samlet_kr desc;

-- ============================================================
--  8. Startkatalog: 86 varetyper fra værkstedets eget sprogbrug.
--     Dansk navn + polsk navn. Det ukrainske ord ligger i aliaser,
--     så søgningen også finder det — det er ikke et sprog i UI'et.
--     Priser og varenumre står tomme: dem udfylder du ved kuratering.
-- ============================================================
insert into materialer (navn_da, navn_pl, aliaser, status, enhed, minimum)
select v.da, v.pl, v.al, 'kurateret', 'stk', 0
from (values
  ('Afgrening Spademuffe', 'Nasuwka płaska rozgałęźna', array['Плоска клема-розгалужувач']),
  ('Automatsikring (MCB)', 'Wyłącznik nadprądowy (MCB)', array['Автоматичний вимикач (MCB)']),
  ('Batteri', 'Bateria', array['Батарея']),
  ('Bilrelæ', 'Przekaźnik samochodowy', array['Автомобільне реле']),
  ('Blindprop', 'Zaślepka', array['Заглушка']),
  ('CEE Indtag', 'Gniazdo wejściowe CEE', array['Вхідний роз''єм CEE']),
  ('Chassishus', 'Obudowa podstawy', array['Корпус шасі']),
  ('Drejegreb', 'Rękojeść obrotowa', array['Поворотна ручка']),
  ('Drejegreb (Separat)', 'Rękojeść obrotowa (osobna)', array['Поворотна ручка (окремо)']),
  ('Elmåler', 'Licznik energii', array['Електролічильник']),
  ('Endeplade', 'Płytka końcowa', array['Кінцева пластина']),
  ('Endestop', 'Ogranicznik końcowy', array['Кінцевий фіксатор']),
  ('Endevinkel', 'Kątownik końcowy', array['Кінцевий кутник']),
  ('Fejlstrømsafbryder (RCD)', 'Wyłącznik różnicowoprądowy (RCD)', array['Пристрій захисного відключення (ПЗВ)']),
  ('Fejlstrømsmonitor', 'Monitor prądu różnicowego', array['Монітор диференційного струму']),
  ('Fingeråbner', 'Narzędzie do otwierania zacisków', array['Інструмент для відкривання клем']),
  ('Gaffelkabelsko', 'Końcówka widełkowa', array['Вилковий наконечник']),
  ('Gruppeafbryder', 'Wyłącznik grupowy', array['Груповий вимикач']),
  ('Hjælpekontakt', 'Styk pomocniczy', array['Допоміжний контакт']),
  ('Hængsellåg', 'Pokrywa na zawiasach', array['Кришка на шарнірах']),
  ('Inverter', 'Falownik', array['Інвертор']),
  ('Jordklemme', 'Zacisk uziemiający', array['Клема заземлення']),
  ('Kabelsko', 'Końcówka kablowa', array['Кабельний наконечник']),
  ('Klemme', 'Zacisk', array['Клема']),
  ('Klemmeafdeler', 'Przegroda zacisków', array['Розділювач клем']),
  ('Klemmefordeler', 'Rozdzielacz zacisków', array['Розподільник клем']),
  ('Kombiafbryder (RCBO)', 'Wyłącznik różnicowoprądowy z bezpiecznikiem (RCBO)', array['Дифавтомат (RCBO)']),
  ('Kondensator', 'Kondensator', array['Конденсатор']),
  ('Kontaktben', 'Bolec stykowy', array['Контактний штир']),
  ('Kontaktelement', 'Element stykowy', array['Контактний елемент']),
  ('Kontaktor', 'Stycznik', array['Контактор']),
  ('Kontaktor Spærring', 'Blokada styczników', array['Блокування контакторів']),
  ('Kropsdel', 'Korpus', array['Корпусна частина']),
  ('LED Driver', 'Zasilacz LED', array['Драйвер LED']),
  ('LED Floodlight', 'Naświetlacz LED', array['Світлодіодний прожектор']),
  ('Laske', 'Mostek łączący', array['З''єднувальна планка']),
  ('Lyselement', 'Element świetlny', array['Світловий елемент']),
  ('Lågskrue', 'Śruba pokrywy', array['Гвинт кришки']),
  ('Maksimalafbryder', 'Wyłącznik maksymalnoprądowy', array['Максимальний вимикач']),
  ('Montageboks', 'Puszka montażowa', array['Монтажна коробка']),
  ('Montageplade', 'Płyta montażowa', array['Монтажна панель']),
  ('Monteringsledning', 'Przewód montażowy', array['Монтажний провід']),
  ('Motordrev', 'Napęd silnikowy', array['Моторний привід']),
  ('Måletransformer', 'Przekładnik prądowy', array['Вимірювальний трансформатор']),
  ('Nødstop', 'Wyłącznik awaryjny', array['Аварійний стоп']),
  ('Omskifter', 'Przełącznik', array['Перемикач']),
  ('Operatørboks', 'Obudowa sterownicza', array['Пост керування']),
  ('Operatørvindue', 'Okienko operatora', array['Вікно оператора']),
  ('Overvåger', 'Układ nadzoru', array['Пристрій контролю']),
  ('PLC', 'Sterownik PLC', array['Контролер PLC']),
  ('Pumpe', 'Pompa', array['Насос']),
  ('Relæ', 'Przekaźnik', array['Реле']),
  ('Relæsokkel', 'Podstawka przekaźnika', array['Колодка реле']),
  ('Reversings Kontaktor', 'Stycznik nawrotny', array['Реверсивний контактор']),
  ('Ringkabelsko', 'Końcówka oczkowa', array['Кільцевий наконечник']),
  ('Samledåse', 'Puszka łączeniowa', array['З''єднувальна коробка']),
  ('Samlemuffe', 'Tulejka łączeniowa', array['З''єднувальна гільза']),
  ('Signallampe', 'Lampka sygnalizacyjna', array['Сигнальна лампа']),
  ('Signaltryknap', 'Przycisk sygnalizacyjny', array['Сигнальна кнопка']),
  ('Sikkerhedsafbryder', 'Wyłącznik bezpieczeństwa', array['Вимикач безпеки']),
  ('Sikring', 'Bezpiecznik', array['Запобіжник']),
  ('Sikringsholder', 'Oprawka bezpiecznika', array['Тримач запобіжника']),
  ('Sikringsklemme', 'Zacisk z bezpiecznikiem', array['Клема із запобіжником']),
  ('Sikringsskuffe', 'Szuflada bezpiecznikowa', array['Висувний тримач запобіжника']),
  ('Skilt', 'Tabliczka', array['Табличка']),
  ('Spademuffe', 'Nasuwka płaska', array['Плоска клема (гніздо)']),
  ('Spadestik', 'Wtyk płaski', array['Плоский штекер']),
  ('Stik', 'Wtyk', array['Штекер']),
  ('Stik Udtag', 'Gniazdo wtykowe', array['Розетка']),
  ('Stikhus', 'Obudowa wtyku', array['Корпус штекера']),
  ('Stikindsats', 'Wkład wtyku', array['Вставка штекера']),
  ('Strømforsyning', 'Zasilacz', array['Блок живлення']),
  ('Termorelæ', 'Przekaźnik termiczny', array['Теплове реле']),
  ('Tidsrelæ', 'Przekaźnik czasowy', array['Реле часу']),
  ('Timer', 'Timer', array['Таймер']),
  ('Timetæller', 'Licznik godzin', array['Лічильник годин']),
  ('Transformer', 'Transformator', array['Трансформатор']),
  ('Tylle', 'Przepustka', array['Втулка прохідна']),
  ('Tylle 2x', 'Przepustka podwójna', array['Втулка прохідна подвійна']),
  ('Udløserrelæ', 'Przekaźnik wyzwalający', array['Реле розчіплювача']),
  ('Udtag', 'Gniazdo', array['Розетка']),
  ('Underspændingsrelæ', 'Przekaźnik podnapięciowy', array['Реле мінімальної напруги']),
  ('Ventilator', 'Wentylator', array['Вентилятор']),
  ('Ventilator Gitter', 'Kratka wentylatora', array['Решітка вентилятора']),
  ('Ventilstik', 'Wtyk zaworu', array['Штекер клапана']),
  ('Vinkelgevind', 'Kątowe złącze gwintowane', array['Кутове різьбове з''єднання'])
) as v(da, pl, al)
where not exists (select 1 from materialer m where m.navn_da = v.da);
