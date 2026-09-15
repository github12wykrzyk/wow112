# Version retention

Repozytorium przechowuje maksymalnie 10 ostatnich wersji roboczych projektu WoW 1.12.1 build 5875.

## Regula

- Aktualna wersja: V68.
- Aktualne okno retencji: V59-V68.
- Po dodaniu nowej wersji usuwamy najstarsza wersje poza oknem 10 wersji.
- Przy V69 usuwamy V59, przy V70 usuwamy V60 itd.
- `CURRENT_VERSION.md` zawsze wskazuje aktywny baseline.
- Poprzednia wersja ma pozostac latwo dostepna jako bezposredni rollback.
- Dla kazdej wersji priorytet maja: runtime, dostepne source, SHA256, README/changelog i skrypty verify/cleanup.
- Nie archiwizujemy dodatkowo starych eksperymentalnych paczek, jezeli ich funkcjonalnosc jest juz pokryta przez jedna z 10 zachowanych wersji.

## V68

V68 jest aktualnym baseline. V67 pozostaje bezposrednim rollbackiem. Starsze materialy nie sa obecnie priorytetem do synchronizacji, dopoki mieszcza sie poza aktywnym workflow V59-V68.
