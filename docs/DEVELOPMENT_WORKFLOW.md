# Development workflow

## Cel

`main` ma zawsze reprezentowac ostatni sprawdzony stabilny stan projektu. Zmiany rozwojowe wykonujemy na `work`.

## Standardowy przebieg

1. Punkt startowy: aktualny `main`.
2. Zmiana trafia na `work` jako osobny, opisany commit.
3. GitHub Actions uruchamia `tools/verify_repo.py`.
4. Weryfikacja musi zakonczyc sie `PASS`.
5. Dopiero wtedy zmiana moze zostac scalona do `main`.
6. Po uznaniu nowej wersji za stabilna tworzymy kolejny baseline (`V69`, `V70`, ...), aktualizujemy `CURRENT.json`, `runtime/current.json`, `CURRENT_VERSION.md` i manifest SHA256.

## Co sprawdza verifier

- zgodnosc WoW 1.12.1 / build 5875 / x86,
- zgodnosc wskazanego baseline z runtime manifestem,
- identyczna kolejnosc i zawartosc `dlls.txt` oraz `runtime/current.json`,
- obecność wszystkich aktywnych DLL w manifeście SHA256,
- zgodnosc hashy zapisanych w runtime z manifestem,
- zgodnosc EXE z manifestem,
- obecnosc dokumentacji canonical source MovementCore,
- odtworzenie canonical source MovementCore z XZ/Base64 i weryfikacje jego rozmiaru/SHA256,
- brak sledzonych plikow `.log`, `.dmp`, `.mdmp`.

## MovementCore source

Canonical V68 source jest obecnie zachowany w `artifacts/V68/source/` jako cztery czesci Base64 zawierajace archiwum XZ.

Odtworzenie i weryfikacja bez zapisu:

```bash
python tools/restore_movementcore_source.py --verify-only
```

Odtworzenie do domyslnego katalogu `generated/`:

```bash
python tools/restore_movementcore_source.py
```

Skrypt akceptuje source tylko wtedy, gdy zgadzaja sie jednoczesnie:

- XZ size: 23480 B,
- XZ SHA256: `ca4acf000c84b42172e124fdf10876170a96773ad54fab9d6b88799113e47f48`,
- source size: 107833 B,
- source SHA256: `764a216233ae4269cdc1c75ec4aec6cb7e2abe041a622923147f2e06192f7888`.

`source/V20_SOURCE_PARTS/` jest niepelne i pozostaje tylko materialem historycznym. Nie budujemy z niego DLL.

## Zasada zmian binarnych

Przy zmianie DLL/EXE zachowujemy:

- poprzedni stabilny baseline,
- nowy hash SHA256,
- opis funkcjonalnej zmiany,
- source/diff albo jednoznaczna sciezke rekonstrukcji,
- sposob rollbacku.

## Docelowy kierunek

Kolejny etap migracji to zapisanie pelnego, zweryfikowanego MovementCore jako normalnego pliku `.c` w `src/MovementCore/`, tak aby GitHub mogl wykonywac normalne diffy i code search. Do czasu tej migracji skompresowany artefakt pozostaje canonicalnym zrodlem V68.
